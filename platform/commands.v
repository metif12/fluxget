// commands.v — the handlers behind platform/app_manifest().
//
// Every handler receives raw JSON params and returns raw JSON, because a
// bridge command runs on the webview main thread (vails ADR-0010): the work
// here must be pure and fast. Anything slow (the aria2 RPC call, the process
// supervisor) is reached through core/, engine/ and aria2ctl/, never inlined
// into a handler.
//
// Phase 0 shipped three probe commands with no state. Phase 1 adds the two that
// need it, and that is why this file now has a `default_backend(app)` instead
// of a `default_backend()`: see the note on the closures below.
module platform

import json2
import os
import time

// BuildInfo is what the app knows about itself at runtime. Kept separate from
// the handler so a test can assert the JSON shape without booting a window.
//
// WIRE FORMAT RULE (applies to every struct in Fluxget that crosses the
// bridge): V encodes struct field names verbatim, so the field name *is* the
// JSON key, and it has to be written the same way in
// app_manifest().ts_types. Two alternatives are unavailable:
//
//   - uppercase is rejected outright ("field name cannot contain uppercase
//     letters, use snake_case instead"), so camelCase is not an option;
//   - a `[json: 'exePath']` attribute is miscompiled by V 0.5.2: the codegen
//     emits a phantom `platform__json` embedded struct and the C build dies
//     with "unknown type name 'platform__json'".
//
// So: snake_case in V, snake_case on the wire, snake_case in the generated
// vails.d.ts. That is also what the vails repo's own os_info service does, so
// it is the framework convention rather than a workaround. The test
// test_dts_text_agrees_with_the_wire_format fails the build if a field and its
// interface ever drift apart.
pub struct BuildInfo {
pub mut:
	app      string = app_name
	version  string = app_version
	os_name  string = os_name()
	arch     string = arch_name()
	exe_path string
	root     string
	dev      bool
	frontend string
	vails    string = 'unknown'
}

// Health is the wire shape of the health command.
//
// Phase 0 shipped five fields and the boot page still reads them, so they are
// unchanged. aria2_path and aria2_source were added for the Setup page: it
// cannot name a binary it was never told about, and "aria2c" on its own leaves
// a user guessing which copy of it their downloads go through.
pub struct Health {
pub mut:
	ok        bool
	mode      string
	aria2     string
	connected bool
	detail    string
	// aria2_path is the executable in use, empty when none was found.
	aria2_path string
	// aria2_source is which search rule found it: beside-exe, runtime, path or
	// settings. See aria2ctl/locate.v for the order.
	aria2_source string
}

// os_name returns a lowercase 'windows' / 'linux' / 'macos' / '<other>',
// matching the vocabulary vails itself uses in its capability `platforms`.
pub fn os_name() string {
	$if windows {
		return 'windows'
	} $else $if linux {
		return 'linux'
	} $else $if macos {
		return 'macos'
	} $else {
		return 'other'
	}
}

// arch_name is the target architecture, resolved at compile time (V exposes
// the arch as a compile-time constant, not a runtime function).
pub fn arch_name() string {
	$if amd64 {
		return 'x86_64'
	} $else $if arm64 {
		return 'aarch64'
	} $else $if i386 {
		return 'x86'
	} $else {
		return 'unknown'
	}
}

// info_from builds the Info payload from an explicit root, so the production
// handler and a test can both use it without duplicating the field list.
pub fn info_from(root string, dev_mode bool, frontend string) BuildInfo {
	return BuildInfo{
		exe_path: os.executable()
		root:     root
		dev:      dev_mode
		frontend: frontend
	}
}

// build_info is info_from under the name main.v and the handlers use.
pub fn build_info(root string, dev_mode bool, frontend string) BuildInfo {
	return info_from(root, dev_mode, frontend)
}

// handle_ping answers the round-trip probe. No params, fixed reply: if the
// frontend can render this string, the whole bridge path works.
pub fn handle_ping(_ string) !string {
	return 'pong'
}

// handle_info reports build and host facts as JSON.
pub fn handle_info(_ string) !string {
	return json2.encode(build_info(os.getwd(), dev_mode_from_env(), 'unknown'))
}

// handle_health is gone, and its absence is the point.
//
// Phase 0 answered it from hardcoded strings, which was honest then and is a lie
// now: a command that reports "aria2 engine starts in Phase 1" while a real
// engine is downloading would be worse than no command at all. fluxget.health,
// .tick and .add are closures over App (see default_backend), because they need
// state and a bridge handler's signature leaves nowhere to put it.

// dev_mode_from_env lets the Info command report the transport even when the
// Spec was filled in by main.v: it is the same flag main.v checks.
pub fn dev_mode_from_env() bool {
	return os.getenv('FLUXGET_DEV') == '1'
}

// started_at is when the process booted, for the Info payload's uptime.
pub fn started_at() string {
	return time.now().format_ss_micro()
}

// default_backend is the handler set: exactly the commands declared in
// app_manifest(). services.install fails loudly if the two ever disagree, which
// is the point of going through the service model.
//
// Built by assignment, not a map literal. V 0.5.x cannot parse a map literal
// whose values are functions: the bare `{ 'k': fn }` form silently yields an
// empty map, and a typed `map[string]Handler{ 'k': fn }` literal does not
// parse at all. The vails services/install_test.v says the same thing in a
// comment and uses this exact shape, so the framework hit it first.
//
// The `mut a := app` line before each closure is load-bearing, and it is the
// same requirement rpc/fake.v documents for its recording transport: a V closure
// gets a COPY of whatever it captures unless the capture is mutable. Without the
// mutable local, each handler would mutate a private copy of the state and no two
// commands would ever see the same app.
//
// The build prints a notice for it - "`app` is immutable, cannot have a mutable
// reference to an immutable object" - and the notice is WRONG here. App is
// @[heap] and is shared by pointer, so the mutation lands on the one object. That
// is not an assumption:
// test_two_commands_see_the_same_state in contract_test.v pushes a notice onto
// the state the test holds, calls fluxget.tick through the router, and requires
// the notice to come back - which it cannot if the capture copied. If that test
// ever fails, believe the test and not the notice.
pub fn default_backend(app &App) map[string]Handler {
	mut backend := map[string]Handler{}
	backend[app_name + '.ping'] = handle_ping
	backend[app_name + '.info'] = handle_info

	mut a := app
	backend[app_name + '.health'] = fn [mut a] (_ string) !string {
		return a.health_json()
	}
	backend[app_name + '.tick'] = fn [mut a] (_ string) !string {
		return a.tick_json()
	}
	backend[app_name + '.add'] = fn [mut a] (params string) !string {
		return a.add_json(params)
	}

	// Phase 3: the row operations. Every one of these is a closure over the App
	// for the same reason the three above are - they need the engine and they
	// mutate state - and the `mut a` capture is load-bearing in each.
	//
	// They are separate commands rather than one `fluxget.act` with an action
	// field because the grant is the security boundary: a window script that can
	// pause a download need not be able to delete one, and a capability list that
	// reads "fluxget.control" cannot express that.
	backend[app_name + '.pause'] = fn [mut a] (params string) !string {
		return a.pause_json(params)
	}
	backend[app_name + '.resume'] = fn [mut a] (params string) !string {
		return a.resume_json(params)
	}
	backend[app_name + '.remove'] = fn [mut a] (params string) !string {
		return a.remove_json(params)
	}
	backend[app_name + '.retry'] = fn [mut a] (params string) !string {
		return a.retry_json(params)
	}
	backend[app_name + '.move'] = fn [mut a] (params string) !string {
		return a.move_json(params)
	}
	backend[app_name + '.pause_all'] = fn [mut a] (params string) !string {
		return a.pause_all_json(params)
	}
	backend[app_name + '.resume_all'] = fn [mut a] (params string) !string {
		return a.resume_all_json(params)
	}
	backend[app_name + '.forget_all'] = fn [mut a] (params string) !string {
		return a.forget_all_json(params)
	}
	backend[app_name + '.set_item_options'] = fn [mut a] (params string) !string {
		return a.set_item_options_json(params)
	}

	// Phase 3: settings. get_settings needs no lock and mutates nothing, so it
	// takes the App by value - a read that cannot change what it reads is worth
	// saying in the signature.
	backend[app_name + '.get_settings'] = fn [a] (_ string) !string {
		return a.settings_json('')
	}
	backend[app_name + '.set_settings'] = fn [mut a] (params string) !string {
		return a.set_settings_json(params)
	}
	return backend
}
