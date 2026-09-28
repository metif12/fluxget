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
import core
import json2
import rpc
import services
import strconv

// app_for_test builds an App for the handler tests.
//
// A fake root, and a probe url of '' so nothing is armed. It starts nothing:
// App's constructor builds state and stops there, and window_ready is what starts
// the engine. That separation is what makes these tests possible at all - if
// building an App spawned a process, the whole suite would be a process launcher.
//
// Named app_for_test, NOT test_app: V treats every `fn test_*` in a _test.v file
// as a test to RUN, and rejects one whose signature is not () void / ? / !. A
// helper called test_app fails with "invalid test signature", which is a
// confusing way to learn the rule.
fn app_for_test() &App {
	return new_app('C:\\fluxget', false, '')
}

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
	services.install(mut r, app_manifest(), default_backend(app_for_test())) or {
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
	services.install(mut r, svc, default_backend(app_for_test())) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	clean := r.call_validated('1', app_name + '.ping', '')
	assert clean.err == '', 'no payload must be accepted: ${clean.err}'
	assert clean.result == 'pong'

	dirty := r.call_validated('2', app_name + '.ping', '{"surprise":1}')
	assert dirty.err.starts_with('bad params:'), 'got: ${dirty.err}'
}

fn test_the_tick_command_accepts_no_payload_either() {
	// tick is a poll, not a request. A payload on it would be a channel for
	// something a poll has no business being told.
	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend(app_for_test())) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	res := r.call_validated('1', app_name + '.tick', '{"since":42}')
	assert res.err.starts_with('bad params:'), 'got: ${res.err}'
}

fn test_the_add_command_does_accept_a_payload() {
	// The other half of the pair: add declares AddParams, so the framework wires
	// validate_any and the handler is the one that must check the fields. If this
	// ever starts rejecting payloads, `add` is a poll that cannot add anything.
	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend(app_for_test())) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	for c in app_manifest().commands {
		if c.name == app_name + '.add' {
			assert c.params != services.no_params, 'add must declare its params type'
			return
		}
	}
	assert false, 'fluxget.add is not in the manifest'
}

fn test_manifest_and_backend_agree() {
	// services.install already refuses a mismatch, so a green install is the
	// assertion. This test names the failure so it is obvious which side
	// drifted: a command in the manifest with no handler, or a handler for a
	// command nobody declared.
	svc := app_manifest()
	be := default_backend(app_for_test())
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

// A row is named after the FILE, not the folder.
//
// The bug this exists for: `dir` is the directory aria2 writes into, so labelling
// a row from it renders a 100 MB file called 100Mb.dat as "downloads" - the
// name of a folder, presented as if it were the file. That is not hypothetical;
// it is what the first end-to-end run showed. The real name is files[0].path,
// which rpc.Status now decodes.
fn test_a_row_is_named_after_the_file_not_the_folder() {
	mut s := rpc.Status{
		gid:              'aa01'
		status:           'active'
		dir:              'D:\\fluxget\\downloads'
		file_path:        'D:\\fluxget\\downloads\\100Mb.dat'
		total_length:     104857600
		completed_length: 52428800
		download_speed:   1048576
	}
	row := download_from(s)
	assert row.name == '100Mb.dat', 'got ${row.name}'
	// The folder is still reported - it is what the detail panel shows - it is
	// just not what the row is labelled with.
	assert row.dir == 'D:\\fluxget\\downloads'
}

fn test_a_row_with_no_file_path_still_gets_a_name() {
	// aria2 omits `files` on some answers. A row must never be blank, so the
	// fallback chain still runs.
	mut s := rpc.Status{
		gid:    'aa01'
		status: 'active'
		dir:    '/downloads/some-folder'
	}
	row := download_from(s)
	assert row.name != '', 'a row is never nameless'
	assert row.name == 'some-folder', 'the folder is the best guess available: ${row.name}'
}

fn test_a_finished_row_shows_no_eta() {
	// "Finished 100 MiB ... unknown" reads as a problem where there is none:
	// there is nothing left to wait for.
	mut s := rpc.Status{
		gid:              'aa01'
		status:           'complete'
		file_path:        '/d/100Mb.dat'
		total_length:     104857600
		completed_length: 104857600
	}
	row := download_from(s)
	assert row.eta == '', 'a finished download has no eta, got "${row.eta}"'
	assert row.percent == 100.0, 'got ${row.percent}'
	assert row.total == '100 MiB', row.total

	// And an ACTIVE one still does.
	mut a := rpc.Status{
		gid:            'aa01'
		status:         'active'
		file_path:      '/d/100Mb.dat'
		total_length:   104857600
		download_speed: 1048576
	}
	arow := download_from(a)
	assert arow.eta == '1m 40s', arow.eta
}

fn test_two_commands_see_the_same_state() {
	// The test that justifies the whole Phase 1 wiring decision.
	//
	// `default_backend` captures the App by pointer, but V's aliasing analysis is
	// conservative enough to emit "cannot have a mutable reference to an
	// immutable object" on the capture - and if that conservatism were real, each
	// handler would hold a private COPY of the state and no two commands would
	// ever agree. A design that only works if the compiler is being generous is
	// not a design, so it is asserted instead of assumed:
	//
	//   1. push a notice onto the state the TEST holds a reference to;
	//   2. call fluxget.tick through the router, i.e. through a closure that
	//      captured the App earlier;
	//   3. the notice must come back in the tick payload.
	//
	// If the capture had copied, step 3 would find an empty queue.
	mut app := app_for_test()
	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend(app)) or {
		assert false, 'install must succeed: ${err.msg()}'
	}
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		text: 'written by the test, read by a closure'
	})
	res := r.call_validated('1', app_name + '.tick', '')
	assert res.err == '', 'tick must not fail: ${res.err}'
	v := json2.decode[map[string]json2.Any](res.result) or {
		assert false, err.msg()
		return
	}
	raw := res.result
	assert raw.contains('written by the test, read by a closure'), "the tick closure did not see the test's state: ${raw}"
	// And it is delivered exactly once, which is the other half: a notice left in
	// the queue would reappear on every tick for the life of the window.
	r2 := r.call_validated('2', app_name + '.tick', '')
	assert !r2.result.contains('written by the test'), 'a notice must not repeat: ${r2.result}'
}

fn test_repeated_ticks_advance_the_same_state() {
	// The same question asked a second way: if each closure had its own copy of
	// the state, the tick counter would restart from zero every time.
	mut app := app_for_test()
	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend(app)) or {
		assert false, err.msg()
	}
	mut seen := []int{}
	for i in 0 .. 3 {
		res := r.call_validated(i.str(), app_name + '.tick', '')
		v := json2.decode[map[string]json2.Any](res.result) or {
			assert false, err.msg()
			return
		}
		mut t := 0
		if raw := v['ticks'] {
			// String.int() panics on a non-number, and `if n := ...` is only legal
			// for an Option or a Result. strconv.atoi is the safe reader.
			t = strconv.atoi(raw.str()) or { 0 }
		}
		seen << t
	}
	// A poll with no supervisor does not count as a tick (core.poll returns
	// before the counter), so all three are 0 - which is itself the assertion:
	// the number is stable rather than resetting, and the frontend is not being
	// shown a fresh app on every frame.
	assert seen == [0, 0, 0], 'got ${seen}'
}

fn test_health_reports_a_not_ready_engine_instead_of_pretending() {
	// The Phase 0 test, rewritten rather than deleted. It used to call
	// handle_health and assert the hardcoded 'bootstrap' string; health is now a
	// closure over App, and the honest answer is a real phase. What must not
	// change is the behaviour: no engine means not connected, and a reason.
	mut app := app_for_test()
	out := app.health_json() or { assert false, 'health must not fail: ${err.msg()}' }
	h := json2.decode[Health](out) or {
		assert false, 'health must return JSON: ${err.msg()}'
		return
	}
	assert !h.ok, 'no engine was started, so ok must be false'
	assert !h.connected
	assert h.mode == 'never-started', 'got ${h.mode}'
	assert h.detail != '', 'a disconnected engine must say why'
}

fn test_health_names_the_binary_or_says_it_is_missing() {
	// The Setup page's data. Before Phase 1 health could not say which aria2c it
	// meant, and "aria2" on its own leaves a user guessing which copy their
	// downloads go through.
	mut app := app_for_test()
	out := app.health_json() or { assert false, err.msg() }
	h := json2.decode[Health](out) or {
		assert false, err.msg()
		return
	}
	if h.mode == 'missing' {
		assert h.aria2_path == '', 'a missing engine has no path'
		assert h.detail.contains('fetch-aria2'), 'and must name the fix: ${h.detail}'
	} else {
		assert h.aria2_path != '' || h.mode == 'never-started', 'a real phase must name the binary'
	}
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

// dts_contract checks one struct's encoded keys against the generated .d.ts.
//
// The generalised form of the Phase 0 test, which only ever looked at Info. It
// takes the ENCODED payload rather than a field list, because a field list is
// what drifts: a struct gains a field, the list is not updated, and the test
// keeps passing against a stale copy of the same mistake.
fn dts_contract(name string, encoded string) {
	ts := app_manifest().ts_types.join('\n')
	v := json2.decode[map[string]json2.Any](encoded) or {
		assert false, '${name} must return a JSON object: ${err.msg()}'
		return
	}
	for key in v.keys() {
		assert ts.contains(key + ':'), 'the .d.ts is missing ${name}.${key}, but the wire sends it'
	}
}

fn test_dts_text_agrees_with_the_wire_format() {
	dts_contract('Info', handle_info('') or { assert false, err.msg() })
}

fn test_dts_text_agrees_with_the_wire_format_for_health() {
	mut app := app_for_test()
	dts_contract('Health', app.health_json() or { assert false, err.msg() })
}

// The tick payload is the one that matters most and the one most likely to drift:
// thirty-odd fields across four nested structs, all snake_case, all mirrored by
// hand into ts_types. A tick with no engine is a perfectly good source for that
// check - it is a real payload, and it is the one a user sees when something is
// broken, which is exactly when the interface must be right.
fn test_dts_text_agrees_with_the_wire_format_for_tick() {
	mut app := app_for_test()
	dts_contract('Tick', app.tick_json() or { assert false, err.msg() })
}

// The nested shapes, checked directly. json2 encodes an empty [] as [], so a tick
// with no engine still exercises every scalar in Stat and every array field of
// Tick - and the Download interface is checked against a real row.
fn test_the_tick_payload_has_every_field_the_interface_declares() {
	mut app := app_for_test()
	raw := app.tick_json() or { assert false, err.msg() }
	v := json2.decode[map[string]json2.Any](raw) or {
		assert false, err.msg()
		return
	}
	stat := v['stat'] or {
		assert false, 'tick must carry a stat object'
		return
	}
	sm := json2.decode[map[string]json2.Any](stat.str()) or {
		assert false, 'stat must be an object: ${err.msg()}'
		return
	}
	for key in ['download_speed', 'upload_speed', 'num_active', 'num_waiting', 'num_stopped'] {
		assert key in sm, 'Stat is missing ${key} (got: ${sm.keys()})'
	}
	for key in ['ok', 'phase', 'detail', 'supervised', 'aria2_path', 'aria2_source', 'version',
		'features', 'restart_in_ms', 'uptime_ms', 'ticks', 'stat', 'downloads', 'notices', 'logs',
		'logs_dropped'] {
		assert key in v, 'Tick is missing ${key} (got: ${v.keys()})'
	}
}

fn test_a_download_row_has_every_field_the_interface_declares() {
	// Built from a real rpc.Status rather than from JSON, so this also covers
	// download_from: the row the UI renders is the struct under test, not a
	// hand-written stand-in.
	mut s := rpc.Status{
		gid:              'aa01'
		status:           'active'
		total_length:     1048576
		completed_length: 524288
		download_speed:   131072
		dir:              'C:\\fluxget\\downloads'
	}
	row := download_from(s)
	raw := json2.encode(row)
	dts_contract('Download', raw)
	v := json2.decode[map[string]json2.Any](raw) or {
		assert false, err.msg()
		return
	}
	for key in ['gid', 'name', 'status', 'percent', 'total', 'done', 'speed', 'upload', 'eta',
		'is_torrent', 'seeder', 'dir', 'error'] {
		assert key in v, 'Download is missing ${key} (got: ${v.keys()})'
	}
	// 512 KiB and 128 KiB/s carry no decimal: engine.size_text and rate_text drop
	// the fraction at 10 and above, on the grounds that "512.0 KiB" is noise.
	// The eta is a real number because this row has both a total and a rate:
	// (1048576 - 524288) / 131072 = 4.
	assert v['total']! == json2.Any('1.0 MiB'), v['total'].str()
	assert v['done']! == json2.Any('512 KiB'), v['done'].str()
	assert v['speed']! == json2.Any('128 KiB/s'), v['speed'].str()
	assert v['eta']! == json2.Any('4s'), v['eta'].str()
}

fn test_a_download_row_with_no_rate_says_the_eta_is_unknown() {
	// The other half: an item that has not started has a total and no speed, and
	// a countdown derived from a zero rate is a lie with a number on it.
	mut s := rpc.Status{
		gid:              'aa02'
		status:           'waiting'
		total_length:     1048576
		completed_length: 0
		download_speed:   0
		dir:              'C:\\fluxget\\downloads'
	}
	raw := json2.encode(download_from(s))
	assert raw.contains('"eta":"unknown"'), raw
	assert raw.contains('"percent":0'), 'no progress must read as 0, not as NaN: ${raw}'
}

fn test_a_failed_tick_is_flagged_and_still_carries_a_frame() {
	// With no engine, `ok` is false. Every other field is still meaningful, and
	// the UI must not read the zero counts as real. The honest part is that `ok`
	// and `detail` are the signal, and that the Logs tab keeps working - which is
	// exactly when it matters.
	mut app := app_for_test()
	raw := app.tick_json() or { assert false, err.msg() }
	v := json2.decode[map[string]json2.Any](raw) or {
		assert false, err.msg()
		return
	}
	assert v['ok']! == json2.Any(false), 'no engine means not ok'
	assert v['detail']! != json2.Any(''), 'and a reason: ${raw}'
	assert v['phase']! == json2.Any('never-started'), v['phase'].str()
	assert 'logs' in v, 'a disconnected engine is when the log matters most'
	assert v['supervised']! == json2.Any(false)
}

fn test_the_add_command_refuses_an_empty_uri_list_before_the_network() {
	// The handler is the only place a malformed add can be stopped, because
	// services.install gave it validate_any (the payload is JSON, nothing more).
	// An empty add must be a rejection, not a row the UI waits on forever.
	mut app := app_for_test()
	app.add_json('{"uris":[],"dir":"","out":"","paused":false}') or {
		assert err.msg().contains('no uri'), err.msg()
		return
	}
	assert false, 'an empty add must be refused'
}

fn test_the_add_command_refuses_malformed_json() {
	mut app := app_for_test()
	app.add_json('{not json') or {
		assert err.msg().contains('bad params'), err.msg()
		return
	}
	assert false, 'malformed params must be refused'
}

fn test_the_add_command_refuses_an_oversized_request() {
	// The framework will hand a handler a megabyte of JSON. A cap costs one
	// comparison and turns "the page froze" into "that request was too large".
	mut app := app_for_test()
	big := '{"uris":["https://example.com/' + 'x'.repeat(max_add_params_bytes) + '"]}'
	assert big.len > max_add_params_bytes
	app.add_json(big) or {
		assert err.msg().contains('limit is'), err.msg()
		return
	}
	assert false, 'an oversized request must be refused'
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

fn test_the_dts_declares_tick_and_add() {
	// Named individually because they are the two commands Phase 1 added, and a
	// missing declaration here is the whole failure this project is about
	// avoiding on the frontend side.
	text := dts_text(host_test_config())
	assert text.contains('function tick('), 'the .d.ts has no tick()'
	assert text.contains('function add('), 'the .d.ts has no add()'
	assert text.contains('interface Tick'), 'the .d.ts has no Tick interface'
	assert text.contains('interface AddParams'), 'the .d.ts has no AddParams interface'
}

fn test_os_and_arch_are_the_words_the_ui_expects() {
	// The frontend picks labels and RTL handling from these, and a stray
	// capital would silently break the theme switch.
	assert os_name() in ['windows', 'linux', 'macos', 'other']
	assert arch_name() in ['x86_64', 'aarch64', 'x86', 'unknown']
}
