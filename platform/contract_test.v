// contract_test.v — the behavioural half of the vails contract.
//
// contract.v proves the shapes compile. This proves they still *work*, which
// is the class of change that compiles fine and breaks an app: a capability
// registry that stopped denying, an injected CSP that stopped being
// idempotent, a service installer that stopped validating its manifest, or a
// generated .d.ts that drifted away from the wire format.
//
// No window is opened and no socket is touched, so this runs inside
// `v test .` on any machine - the same rule the vails repo follows.
module platform

import bridge
import capabilities
import json2
import services

fn test_run_contract_is_green() {
	rep := run_contract()
	assert rep.shapes_ok, 'shape helpers must still be callable'
	assert rep.router_calls == 1, 'register_validated must still dispatch'
	assert rep.registry_denies, 'an empty capability registry must deny'
	assert rep.manifest_ok, 'our manifest must install against our own backend'
	assert rep.csp_idempotent, 'inject_csp must inject once and stay idempotent'
	assert rep.install_rejects, 'services.install must refuse an undeclared command'
	assert rep.notes.len == 0, 'contract notes: ${rep.notes}'
	assert rep.ok
}

fn test_registry_grants_exactly_what_vails_json_says() {
	// The T2 gate: a granted command resolves, an ungranted one does not.
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'probe'
		windows:  ['main']
		commands: ['fluxget.ping']
	})
	assert reg.is_allowed('main', 'fluxget.ping')
	assert !reg.is_allowed('other', 'fluxget.ping')
	assert !reg.is_allowed('main', 'fluxget.health')
}

fn test_denied_command_reports_forbidden_not_unknown() {
	// The framework distinguishes the two on purpose: `unknown method:` would
	// leak the existence of a command the window is not allowed to call, which
	// the T1/T2 ADRs call out. If this regresses, the security story changes.
	mut r := bridge.new_router()
	r.register_validated('fluxget.ping', bridge.validate_empty, handle_ping) or {
		assert false, 'register must succeed'
	}
	mut reg := capabilities.new_registry()
	res := r.call_from('main', '1', 'fluxget.ping', '', reg)
	assert res.err.starts_with('forbidden:'), 'got: ${res.err}'
	assert !res.err.starts_with('unknown method:')
}

fn test_granted_command_reaches_the_handler() {
	// The happy path of the same dispatch, so the deny test above cannot pass
	// for the wrong reason (a router that refuses everything also "denies").
	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend()) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'fluxget-core'
		windows:  ['main']
		commands: app_manifest().command_names()
	})
	res := r.call_from('main', '1', app_name + '.ping', '', reg)
	assert res.err == '', 'a granted command must not be refused: ${res.err}'
	assert res.result == 'pong'
}

fn test_no_argument_command_rejects_a_payload() {
	// services.install wires validate_empty for no-argument commands; this is
	// the check that stops a frontend smuggling data past the T2 params gate.
	//
	// call_validated, not call: the framework deliberately keeps the params
	// check out of `call` (the trusted in-process path) and puts it in
	// call_validated / call_json. Testing with call would pass while proving
	// nothing.
	mut r := bridge.new_router()
	svc := app_manifest()
	services.install(mut r, svc, default_backend()) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	clean := r.call_validated('1', app_name + '.ping', '')
	assert clean.err == '', 'no payload must be accepted: ${clean.err}'
	assert clean.result == 'pong'

	dirty := r.call_validated('2', app_name + '.ping', '{"surprise":1}')
	assert dirty.err.starts_with('bad params:'), 'got: ${dirty.err}'
}

fn test_manifest_and_backend_agree() {
	// services.install already refuses a mismatch, so a green install is the
	// assertion. This test names the failure so it is obvious which side
	// drifted: a command in the manifest with no handler, or a handler for a
	// command nobody declared.
	svc := app_manifest()
	be := default_backend()
	mut declared := map[string]Handler{}
	for c in svc.commands {
		if c.name in be {
			declared[c.name] = be[c.name]
		}
	}
	assert declared.len == be.len, 'handlers and declared commands must be the same set'
	assert declared.len == svc.commands.len, 'every declared command needs a handler'

	// An extra handler for a command nobody declared must be refused.
	//
	// Built by assignment, not be.clone(): V rejects mutating a map that
	// aliases an immutable value, and clone() is not enough to convince it.
	mut extra := map[string]Handler{}
	for name in be.keys() {
		extra[name] = be[name]
	}
	extra['fluxget.ghost'] = contract_rogue_handler
	assert extra.len == be.len + 1, 'the rogue handler must be in the map'
	mut r := bridge.new_router()
	assert !install_ok(mut r, svc, extra), 'an undeclared handler must be refused'
}

fn test_every_command_stays_in_the_fluxget_namespace() {
	svc := app_manifest()
	assert svc.name == app_name
	for c in svc.commands {
		assert c.name.starts_with(app_name + '.'), c.name
		assert c.short_name() != '', c.name
		assert c.summary != '', c.name + ' needs a summary for `vails doctor`'
	}
}

fn test_health_command_reports_a_not_ready_engine_instead_of_pretending() {
	// Phase 0 has no aria2 yet. The honest answer is what lets the frontend
	// show the setup page; a fake "ok" would hide a broken engine.
	out := handle_health('') or { assert false, 'health must not fail: ${err.msg()}' }
	h := json2.decode[Health](out) or {
		assert false, 'health must return JSON: ${err.msg()}'
		return
	}
	assert !h.ok
	assert !h.connected
	assert h.detail != '', 'a disconnected engine must say why'
}

fn test_ping_is_the_fixed_round_trip_token() {
	assert handle_ping('')! == 'pong'
}

fn test_info_command_returns_json_with_the_expected_shape() {
	out := handle_info('') or { assert false, 'info must not fail: ${err.msg()}' }
	v := json2.decode[map[string]json2.Any](out) or {
		assert false, 'info must return a JSON object: ${err.msg()}'
		return
	}
	for key in ['app', 'version', 'os_name', 'arch', 'exe_path', 'root', 'dev', 'frontend', 'vails'] {
		assert key in v, 'info is missing ${key} (got: ${v.keys()})'
	}
}

fn test_dts_text_agrees_with_the_wire_format() {
	// The generated .d.ts declares Info's fields and the handler encodes the
	// same names. Nothing enforces that except this test, and a mismatch shows
	// up as a TypeScript error nobody reads at 2am.
	ts := app_manifest().ts_types.join('\n')
	raw := handle_info('') or { assert false, err.msg() }
	v := json2.decode[map[string]json2.Any](raw) or { return }
	for key in v.keys() {
		assert ts.contains(key + ':'), 'Info interface is missing ${key}, but the wire sends it'
	}
}

fn test_dts_text_covers_every_granted_fluxget_command() {
	// The generated frontend declarations come from this one manifest, so a
	// command the frontend can call but that is absent from the .d.ts would
	// only surface as a TypeScript error nobody reads.
	text := dts_text(host_test_config())
	for c in app_manifest().commands {
		assert text.contains('function ' + c.short_name() + '('), 'dts is missing ${c.short_name()}'
	}
	assert text.contains('namespace ' + app_name)
}

fn test_os_and_arch_are_the_words_the_ui_expects() {
	// The frontend picks labels and RTL handling from these, and a stray
	// capital would silently break the theme switch.
	assert os_name() in ['windows', 'linux', 'macos', 'other']
	assert arch_name() in ['x86_64', 'aarch64', 'x86', 'unknown']
}
