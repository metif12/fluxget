// settings_cmd.v - fluxget's settings commands, and the one place the user's
// preferences are pushed into the engine.
//
// The rule this file exists to enforce: **"saved" and "in force" are different
// claims, and only one of them is true at any moment.**
//
// A settings write that only touched the JSON file would be the easiest version
// to build and the least honest. The engine is a separate process with its own
// state, so a document can be perfect and the running engine can disagree with
// every line of it. So a write does three things in order - clamp, push, report -
// and only the middle one is allowed to be silent.
module platform

import json2
import strconv
import core
import rpc
import store

// settings_payload_bytes bounds a settings write. The document is small; this
// only exists so a runaway UI cannot turn a number field into a memory problem.
pub const settings_payload_bytes = 16384

// settings_json is fluxget.get_settings.
//
// The answer is the document plus the notes, because a UI that renders only the
// values is hiding a correction the user needs to know about: if their file said
// max_concurrent = 0 and the app shows 1, that difference has to be visible
// somewhere or the app is lying by omission.
pub fn (app App) settings_json(_ string) !string {
	return json2.encode(SettingsView{
		settings: app.settings
		path:     app.settings_path
		notes:    app.settings_notes
	})
}

// SettingsView is what the UI binds to.
//
// The field names ARE the JSON keys (AGENTS.md section 5), and they are nested
// under `settings` rather than flattened so that adding a top-level field later -
// `path`, or a version number - does not collide with a setting.
pub struct SettingsView {
pub mut:
	settings store.Settings
	path     string
	notes    []string
}

// set_settings_json is fluxget.set_settings: change the limits, persist them, and
// put them in force.
//
// Three steps, and the order is the design:
//
//  1. DECODE AND CLAMP. A value out of range is corrected and reported, not
//     rejected: refusing the whole document because one field was 0 would leave
//     the user with no way to fix the other ten, and the app would be stuck on
//     whatever it had before.
//
//  2. PUSH, AND MEASURE. change_global_option answers with the options aria2
//     REFUSED. If that comes back non-empty, the document on disk is rewritten
//     FROM WHAT ARIA2 ACTUALLY HOLDS, so the next start does not try again with a
//     value the engine has already refused. A settings file that keeps asking
//     for something impossible is worse than one that accepts the answer.
//
//  3. SAVE. Last, and only after the push succeeded, so a failed push does not
//     leave a document claiming limits that are not in force.
//
// A save that fails is a rejection. Settings the user cannot keep are not
// settings.
pub fn (mut app App) set_settings_json(params string) !string {
	if params.len > settings_payload_bytes {
		return error('fluxget.set_settings: the request is ${params.len} bytes; the limit is ${settings_payload_bytes}')
	}
	mut wanted := json2.decode[store.Settings](params) or {
		return error('fluxget.set_settings: bad params: ' + err.msg())
	}
	mut corrections := wanted.normalise()
	app.settings = wanted

	// ---- 2. push, and ask what was refused
	rejected := app.push_settings() or { return err }
	if rejected.len > 0 {
		// aria2 refused something. Read back what it really holds, so the
		// document matches the engine rather than the user's wish.
		corrections << app.settings.merge_report(rejected)
		if actual := app.read_back_settings() {
			app.settings = actual
		}
	}

	// ---- 3. save what is actually in force
	app.settings.save(app.settings_path) or {
		return error('fluxget.set_settings: ' + err.msg())
	}
	app.settings_notes = corrections
	return json2.encode(SettingsView{
		settings: app.settings
		path:     app.settings_path
		notes:    corrections
	})
}

// apply_settings is what window_ready calls once the engine is up.
//
// It is deliberately the same code path as a user's edit, so there is no "applied
// at startup" behaviour that a later edit does not share. Two implementations of
// "make these limits real" is two sets of bugs.
pub fn (mut app App) apply_settings() {
	rejected := app.push_settings() or { return }
	if rejected.len > 0 {
		// The lock has to be taken again to push a notice, and this is safe only
		// because push_settings released it on the way out. Anything that needs two
		// lock scopes has to take them in sequence, never nested.
		app.state.lock()
		defer {
			app.state.unlock()
		}
		app.state.notices.push(core.Notice{
			kind: core.notice_info
			text: 'aria2 would not accept: ' + rejected.str()
		})
	}
}

// push_settings sends the document to the engine, and it OWNS the lock for the
// duration.
//
// Both callers rely on that: window_ready no longer holds the lock when it calls
// apply_settings, and set_settings_json never held it. push_settings locking again
// from a caller that already had it is a deadlock on a plain mutex - and a deadlock
// on the webview's main thread looks like an unresponsive window rather than an
// error.
fn (mut app App) push_settings() !map[string]string {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	raw := app.state.eng.client.change_global_option(app.settings.to_aria2()) or {
		return error(err.msg())
	}
	return rpc.refused_options(raw)
}

// read_back_settings asks aria2 what it actually holds, and maps the answer onto
// our document.
//
// It is the second half of "saved is not in force". Without it a refused option
// would be corrected in the file and re-refused on every start, forever, with the
// user never told why. Returns nothing when the engine cannot be asked - a
// settings file is still worth having when aria2 is down.
fn (mut app App) read_back_settings() ?store.Settings {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	opts := app.state.eng.client.get_global_option() or { return none }
	mut s := app.settings
	// Only the fields aria2 echoes back are taken from it. The rest - dir, and
	// whether to save a session - are ours, and aria2's answer to a query is not
	// a reliable source for a preference.
	//
	// Every field keeps its CURRENT value when aria2 does not echo it. That is the
	// whole reason this helper takes the current value: an earlier version parsed
	// the absent key as 0, so an engine that echoed only `split` silently reset
	// every other limit to zero - and then the very next load clamped them to 1
	// and reported four corrections the user never made. A read-back must be
	// non-destructive; a partial answer is not a partial instruction.
	s.max_concurrent = int_or(s.max_concurrent, opts['max-concurrent-downloads'] or { '' })
	s.max_per_server = int_or(s.max_per_server, opts['max-connection-per-server'] or { '' })
	s.download_limit = int_or(s.download_limit, opts['max-download-limit'] or { '' })
	s.upload_limit = int_or(s.upload_limit, opts['max-upload-limit'] or { '' })
	s.split = int_or(s.split, opts['split'] or { '' })
	s.seed_ratio = opts['seed-ratio'] or { s.seed_ratio }
	s.seed_time = opts['seed-time'] or { s.seed_time }
	return s
}

// int_or takes a numeric aria2 option, keeping `current` when the value is absent
// or unparseable.
//
// strconv.atoi rather than String.int(), because String.int() panics on anything
// that is not a number and a settings read must not be able to take the app down.
fn int_or(current int, v string) int {
	if v == '' {
		return current
	}
	return strconv.atoi(v) or { current }
}
