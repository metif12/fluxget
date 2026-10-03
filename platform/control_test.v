// control_test.v - the row operations and the settings commands, end to end,
// with no aria2.
//
// Every test drives a command the way the frontend does - JSON in, JSON or a
// rejection out - through the real router, with rpc.Fake standing in for the
// engine. Two things are asserted, and the second is the one that matters:
//
//   1. what the handler ANSWERS (a gid, "ok", a rejection naming the reason);
//   2. what it SENT (the aria2 method and its arguments), and how many calls.
//
// Asserting only the answer is how the Phase 2 wire bug survived: the fake
// returned the shape the decoder expected, so "it works" proved nothing about
// what went over the wire. So `f.count()` and `f.method_of(i)` appear in almost
// every test here.
module platform

import os
import json2
import bridge
import services
import rpc
import core
import store

// Result is what a routed call gives back: the answer, or the reason.
//
// A named type rather than two loose strings, so a test cannot silently swap them
// - `assert res.err == ''` on a swapped pair would pass for the wrong reason.
struct Result {
mut:
	ok     bool
	result string
	err    string
}

// harness is an App plus the fake behind it.
struct Harness {
mut:
	app    &App
	fake   &rpc.Fake
	router bridge.Router
}

// harness_for builds an App whose engine talks to a scripted transport.
//
// The settings path is redirected BEFORE new_app runs, because new_app reads the
// settings document at construction and a test must never depend on - or damage -
// the machine's real %APPDATA%.
fn harness_for(replies []rpc.Reply) &Harness {
	mut previous := os.getenv_opt('FLUXGET_SETTINGS') or { '' }
	os.setenv('FLUXGET_SETTINGS', scratch_path(), true)
	f := rpc.new_fake(replies)
	mut app := new_app('C:\\fluxget', false, '')
	os.unsetenv('FLUXGET_SETTINGS')
	// The saved value goes back afterwards so this harness cannot leak its
	// redirection into another test. `or { '' }` at the declaration is what makes
	// `previous` a plain string rather than an Option that has to be unwrapped
	// again at each use.
	if previous != '' {
		os.setenv('FLUXGET_SETTINGS', previous, true)
	}
	// Both halves: State keeps a client for readiness and options, and Engine has
	// its own. Setting one and not the other is the bug use_client exists to
	// prevent.
	app.state.use_client(f.client('test-secret'))
	app.settings_path = scratch_path()

	mut r := bridge.new_router()
	services.install(mut r, app_manifest(), default_backend(app)) or {
		panic('install must succeed: ${err.msg()}')
	}
	return &Harness{
		app:    app
		fake:   f
		router: r
	}
}

fn scratch_path() string {
	dir := os.join_path(os.temp_dir(), 'fluxget-control-test')
	os.mkdir_all(dir) or { panic(err.msg()) }
	return os.join_path(dir, 'settings.json')
}

// call routes a command the way the bridge does, with the command name given
// without the namespace.
fn (h &Harness) call(name string, params string) Result {
	res := h.router.call_validated('1', app_name + '.' + name, params)
	return Result{
		ok:     res.err == ''
		result: res.result
		err:    res.err
	}
}

// ---- validation ---------------------------------------------------------

// An empty gid is refused HERE rather than passed to aria2, because aria2's answer
// to a bad gid names a gid that does not exist, and a user who clicked a row must
// never be shown that.
fn test_an_empty_gid_is_refused_with_a_message_that_names_the_command() {
	h := harness_for([])
	res := h.call('pause', '{"gid":""}')
	assert !res.ok, 'an empty gid must be a rejection'
	assert res.err.contains('fluxget.pause'), res.err
	assert res.err.contains('gid'), res.err
}

// Nothing reached the transport: a request that never left the process is the only
// proof that the check happens BEFORE the call and not after the reply.
fn test_a_refused_request_never_reaches_the_engine() {
	h := harness_for([])
	res := h.call('pause', '{"gid":""}')
	assert !res.ok
	assert h.fake.count() == 0, 'a rejected request still called aria2 ${h.fake.count()} time(s)'
}

// Whitespace is not a gid either. `{"gid":" "}` is what a template with an unbound
// variable sends, and it is the most likely shape of this mistake.
fn test_a_whitespace_gid_is_refused() {
	h := harness_for([])
	assert !h.call('resume', '{"gid":"   "}').ok
	assert h.fake.count() == 0
}

// Malformed JSON is a different mistake from an empty gid, and the message says
// which - the first is a broken frontend and the second is a UI that sent the
// wrong field, and a user reporting one of those is reporting a real bug either
// way.
fn test_malformed_params_are_reported_as_bad_params() {
	h := harness_for([])
	res := h.call('resume', 'not json at all')
	assert res.err.contains('bad params'), res.err
}

// The size cap exists so a runaway UI produces a rejection instead of a freeze,
// and it is checked before parsing so the cap is a real bound on memory.
fn test_an_oversized_request_is_refused_before_it_is_parsed() {
	h := harness_for([])
	res := h.call('remove', '{"gid":"' + 'x'.repeat(9000) + '"}')
	assert res.err.contains('limit is'), res.err
	assert h.fake.count() == 0
}

// pause_all and resume_all take nothing, and a payload on a command that ignores
// it is how "pause everything" ends up pausing the twelve rows a user had
// selected.
//
// The refusal comes from the FRAMEWORK, not from the handler: the manifest
// declares these no_params, so services.install wires bridge.validate_empty and
// the payload never reaches us. That is worth knowing rather than asserting as an
// implementation detail - the handler's own check is the second line, not the
// first. So this test asserts the outcome and the absence of a call, and not
// whose job it was.
fn test_the_global_switches_refuse_a_payload() {
	h := harness_for([])
	assert !h.call('pause_all', '{"gid":"x"}').ok, 'a payload must be refused'
	assert !h.call('resume_all', '{}').ok
	assert !h.call('forget_all', '{"anything":1}').ok
	assert h.fake.count() == 0, 'none of those may reach aria2: ${h.fake.count()}'
}

// And with no payload they work, which is the other half: a guard that rejects
// everything would pass the test above.
fn test_the_global_switches_work_with_no_payload() {
	h := harness_for([rpc.ok('"OK"'), rpc.ok('"OK"')])
	assert h.call('pause_all', '').ok
	assert h.call('resume_all', '').ok
	assert h.fake.method_of(0) == 'aria2.pauseAll', h.fake.method_of(0)
	assert h.fake.method_of(1) == 'aria2.unpauseAll', h.fake.method_of(1)
}

// ---- the happy paths, and what they sent --------------------------------

fn test_pause_calls_aria2_pause_with_that_gid() {
	h := harness_for([rpc.ok('"2089b05ecca3d829"')])
	res := h.call('pause', '{"gid":"2089b05ecca3d829"}')
	assert res.ok, 'pause must not fail: ${res.err}'
	assert h.fake.count() == 1, 'exactly one call, not ${h.fake.count()}'
	assert h.fake.method_of(0) == 'aria2.pause', 'the wrong method: ${h.fake.method_of(0)}'
	assert h.fake.params_of(0).contains('2089b05ecca3d829'), h.fake.params_of(0)
}

// aria2's method is `unpause` and the command is `resume`, deliberately: "resume"
// is what a user reads. Asserting the real method name is how that decision
// cannot be quietly reverted by someone tidying the naming.
fn test_resume_calls_aria2_unpause() {
	h := harness_for([rpc.ok('"2089b05ecca3d829"')])
	res := h.call('resume', '{"gid":"2089b05ecca3d829"}')
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.unpause', h.fake.method_of(0)
}

// aria2 splits removal into two calls. A remove that forgets the second leaves
// the item in the history the user is looking at, which is not removing anything.
fn test_remove_takes_it_off_the_queue_and_discards_the_record() {
	h := harness_for([rpc.ok('"gid"'), rpc.ok('"gid"')])
	res := h.call('remove', '{"gid":"2089b05ecca3d829"}')
	assert res.ok, res.err
	assert h.fake.count() == 2, 'remove and forget are two calls, got ${h.fake.count()}'
	assert h.fake.method_of(0) == 'aria2.remove', h.fake.method_of(0)
	assert h.fake.method_of(1) == 'aria2.removeDownloadResult', h.fake.method_of(1)
}

// keep_record:true is the "leave the history" case, and it must make exactly ONE call.
fn test_remove_can_keep_the_record() {
	h := harness_for([rpc.ok('"gid"')])
	res := h.call('remove', '{"gid":"2089b05ecca3d829","keep_record":true}')
	assert res.ok, res.err
	assert h.fake.count() == 1, 'got ${h.fake.count()} calls'
	assert h.fake.method_of(0) == 'aria2.remove', h.fake.method_of(0)
}

// The default matters: a Remove button that leaves the item visible in a list is
// not removing anything. So a payload that says nothing about keep_record still
// discards the record - and this is the regression test for a default that a
// decoder silently overwrote, because an ABSENT bool decodes as false whatever the
// struct was initialised with. The flag is named so that false is the wanted
// behaviour.
fn test_remove_discards_the_record_when_the_payload_omits_the_flag() {
	h := harness_for([rpc.ok('"gid"'), rpc.ok('"gid"')])
	res := h.call('remove', '{"gid":"2089b05ecca3d829"}')
	assert res.ok, res.err
	assert h.fake.count() == 2, 'the zero value of the flag must mean purge: ${h.fake.count()} calls'
	assert h.fake.method_of(1) == 'aria2.removeDownloadResult', h.fake.method_of(1)
}

fn test_pause_all_calls_aria2_pause_all() {
	h := harness_for([rpc.ok('"OK"')])
	res := h.call('pause_all', '')
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.pauseAll', h.fake.method_of(0)
}

fn test_resume_all_calls_aria2_unpause_all() {
	h := harness_for([rpc.ok('"OK"')])
	res := h.call('resume_all', '')
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.unpauseAll', h.fake.method_of(0)
}

fn test_forget_all_clears_the_stopped_results() {
	h := harness_for([rpc.ok('"OK"')])
	res := h.call('forget_all', '')
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.purgeDownloadResult', h.fake.method_of(0)
}

// ---- retry --------------------------------------------------------------

// retry reads the source, discards the record, then re-adds - in that order,
// because the source is gone once the record is discarded. A different order
// re-adds a gid aria2 still knows and fails with "GID#... is not unique".
fn test_retry_reads_the_uri_before_discarding_the_record() {
	h := harness_for([
		rpc.ok_raw('{"gid":"aaa","status":"error","dir":"D:/downloads"}'),
		rpc.ok_raw('[{"uri":"https://example.com/file.bin"}]'),
		rpc.ok('"bbb"'),
		rpc.ok('"newngid"'),
	])
	res := h.call('retry', '{"gid":"aaa"}')
	assert res.ok, res.err
	assert h.fake.count() == 4, 'four calls expected, got ${h.fake.count()}'
	assert h.fake.method_of(0) == 'aria2.tellStatus', h.fake.method_of(0)
	assert h.fake.method_of(1) == 'aria2.getUris', h.fake.method_of(1)
	assert h.fake.method_of(2) == 'aria2.removeDownloadResult', h.fake.method_of(2)
	assert h.fake.method_of(3) == 'aria2.addUri', h.fake.method_of(3)
	// The answer is the NEW gid. A frontend that kept the old one would send
	// every later command for a download the engine has already forgotten.
	assert res.result.contains('newngid'), res.result
}

// The directory has to travel with the retry, or it lands somewhere the user did
// not choose and the old copy is still on disk.
fn test_a_retry_keeps_the_directory_it_came_from() {
	h := harness_for([
		rpc.ok_raw('{"gid":"aaa","status":"error","dir":"D:/downloads"}'),
		rpc.ok_raw('[{"uri":"https://example.com/f.bin"}]'),
		rpc.ok('"bbb"'),
		rpc.ok('"newngid"'),
	])
	assert h.call('retry', '{"gid":"aaa"}').ok
	assert h.fake.params_of(3).contains('downloads'), h.fake.params_of(3)
}

// A download added from .torrent bytes has no URI and there is no honest way to
// retry it. Saying so beats an add with an empty source, and - critically - it
// says it BEFORE the record is discarded.
fn test_retry_says_why_when_there_is_no_uri() {
	h := harness_for([
		rpc.ok_raw('{"gid":"aaa","status":"error","dir":"D:/x"}'),
		rpc.ok_raw('[]'),
	])
	res := h.call('retry', '{"gid":"aaa"}')
	assert res.err.contains('nothing to retry'), res.err
	assert h.fake.count() == 2, 'nothing must be discarded: ${h.fake.count()} calls'
}

// ---- move ---------------------------------------------------------------

// The frontend sends a DELTA ("one place up") and the arithmetic that turns that
// into aria2's offset lives here, where it can be tested. Assert POS_CUR:
// POS_SET with -1 would put the row at the END of the queue.
fn test_move_sends_the_delta_as_a_relative_move() {
	h := harness_for([rpc.ok('1')])
	res := h.call('move', '{"gid":"aaa","delta":-1}')
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.changePosition', h.fake.method_of(0)
	assert h.fake.params_of(0).contains('POS_CUR'), 'a relative move must use POS_CUR: ${h.fake.params_of(0)}'
	assert h.fake.params_of(0).contains('-1'), h.fake.params_of(0)
}

fn test_move_down_sends_a_positive_delta() {
	h := harness_for([rpc.ok('2')])
	res := h.call('move', '{"gid":"aaa","delta":1}')
	assert res.ok, res.err
	assert h.fake.params_of(0).contains('1'), h.fake.params_of(0)
}

// A double-pressed arrow produces delta 0, and reordering the queue for a no-op
// costs a round trip and a visible shuffle.
fn test_a_zero_move_costs_nothing() {
	h := harness_for([])
	res := h.call('move', '{"gid":"aaa","delta":0}')
	assert res.ok, res.err
	assert h.fake.count() == 0, 'a no-op must not call the engine: ${h.fake.count()}'
}

// ---- per-item options ---------------------------------------------------

// aria2 answers changeOption with the options it REFUSED. Handing them back is the
// difference between "saved" and "in force"; a caller that drops them renders a
// field that looks applied and is not.
fn test_options_aria2_refused_are_handed_back_rather_than_dropped() {
	h := harness_for([rpc.ok('{"max-connection-per-server":"Must be less than or equal to 16"}')])
	res := h.call('set_item_options', '{"gid":"aaa","options":{"max-connection-per-server":"99"}}')
	assert res.ok, res.err
	assert res.result.contains('max-connection-per-server'), 'the refusal was swallowed: ${res.result}'
}

fn test_options_aria2_accepted_answer_ok() {
	h := harness_for([rpc.ok('{}')])
	res := h.call('set_item_options', '{"gid":"aaa","options":{"max-connection-per-server":"4"}}')
	assert res.ok, res.err
	assert res.result.contains('ok'), res.result
	assert h.fake.method_of(0) == 'aria2.changeOption', h.fake.method_of(0)
}

fn test_setting_no_options_at_all_is_refused() {
	h := harness_for([])
	res := h.call('set_item_options', '{"gid":"aaa","options":{}}')
	assert res.err.contains('no options'), res.err
	assert h.fake.count() == 0, 'an empty option map must not reach aria2'
}

// ---- engine errors reach the user ---------------------------------------

// "No such download" has to arrive as a rejection naming the reason. An empty
// success is how a UI reports a button press that did nothing as one that worked.
fn test_an_aria2_refusal_arrives_as_a_rejection() {
	h := harness_for([rpc.err_body('1', 'No such download for GID#aaa')])
	res := h.call('pause', '{"gid":"aaa"}')
	assert !res.ok, 'aria2 said no, so the command must fail'
	assert res.err.contains('No such download'), res.err
}

// ---- settings -----------------------------------------------------------

fn test_settings_can_be_read_and_the_document_is_valid_json() {
	h := harness_for([])
	res := h.call('get_settings', '')
	assert res.ok, res.err
	v := json2.decode[SettingsView](res.result) or {
		assert false, err.msg()
		return
	}
	assert v.settings.max_concurrent == 5, v.settings.max_concurrent.str()
	assert v.path.len > 0, 'the UI needs to be able to show where the file is'
}

// The defaults have to reach aria2 under ITS names, which is the one place the two
// vocabularies meet - so the wire is asserted rather than the mapping's output.
fn test_writing_settings_pushes_them_to_aria2_with_aria2s_option_names() {
	h := harness_for([rpc.ok('{}')])
	res := h.call('set_settings', json2.encode(store.Settings{
		max_concurrent: 3
		max_per_server: 8
		split:          4
		min_split_size: 1048576
		bt_enabled:     true
		seed_ratio:     '1.0'
		seed_time:      '60'
		save_session:   true
	}))
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.changeGlobalOption', h.fake.method_of(0)
	params := h.fake.params_of(0)
	assert params.contains('max-concurrent-downloads'), params
	assert params.contains('max-connection-per-server'), params
	assert params.contains('"3"'), 'the value did not travel: ${params}'
}

// A value out of range is corrected and REPORTED, not rejected: refusing the whole
// document because one field was 0 leaves the user unable to fix the other ten.
fn test_an_out_of_range_setting_is_corrected_and_reported() {
	h := harness_for([rpc.ok('{}')])
	res := h.call('set_settings', json2.encode(store.Settings{
		max_concurrent: 0
		max_per_server: 4
		split:          3
		min_split_size: 1048576
		bt_enabled:     true
		seed_ratio:     '1.0'
		seed_time:      '60'
		save_session:   true
	}))
	assert res.ok, res.err
	v := json2.decode[SettingsView](res.result) or {
		assert false, err.msg()
		return
	}
	assert v.settings.max_concurrent == 1, v.settings.max_concurrent.str()
	assert v.notes.len == 1, 'the correction must be visible: ${v.notes}'
	assert v.notes[0].contains('max_concurrent'), v.notes[0]
}

// The document on disk has to match what the ENGINE holds, not what the user asked
// for. Otherwise the next start asks again for something aria2 already refused,
// forever, with no explanation.
fn test_settings_the_engine_refused_are_not_kept_as_saved() {
	h := harness_for([
		rpc.ok('{"split":"Must be between 1 and 16"}'),
		rpc.ok_raw('{"max-concurrent-downloads":"5","split":"2"}'),
	])
	res := h.call('set_settings', json2.encode(store.Settings{
		max_concurrent: 5
		max_per_server: 16
		split:          99
		min_split_size: 1048576
		bt_enabled:     true
		seed_ratio:     '1.0'
		seed_time:      '60'
		save_session:   true
	}))
	assert res.ok, res.err
	assert h.fake.method_of(0) == 'aria2.changeGlobalOption', h.fake.method_of(0)
	assert h.fake.method_of(1) == 'aria2.getGlobalOption', 'a refused value must be read back: ${h.fake.method_of(1)}'
	v := json2.decode[SettingsView](res.result) or {
		assert false, err.msg()
		return
	}
	assert v.settings.split == 2, 'the document kept a value the engine refused: ${v.settings.split}'
	assert v.notes.len >= 2, 'both the clamp and the refusal must be reported: ${v.notes}'
}

// And the corrected document is what gets WRITTEN, so the next start does not
// re-ask for the impossible value.
fn test_the_document_on_disk_is_what_the_engine_accepted() {
	h := harness_for([
		rpc.ok('{"split":"Must be between 1 and 16"}'),
		rpc.ok_raw('{"split":"2"}'),
	])
	res := h.call('set_settings', json2.encode(store.Settings{
		max_concurrent: 5
		max_per_server: 16
		split:          99
		min_split_size: 1048576
		bt_enabled:     true
		seed_ratio:     '1.0'
		seed_time:      '60'
		save_session:   true
	}))
	assert res.ok, res.err
	got, notes := store.load(h.app.settings_path)
	assert got.split == 2, 'the file still asks for 99: ${got.split}'
	assert notes.len == 0, 'and the next start would report a correction again: ${notes}'
}

// ---- applying settings at startup ---------------------------------------

// window_ready pushes the settings right after the engine comes up. This test
// exists because that call DEADLOCKED once: window_ready held app.state.lock() and
// apply_settings -> push_settings locked the same plain mutex again, so the
// webview's main thread never came back. The app did not crash - it painted and
// then ignored every key, and the screenshot tool hung waiting for it.
//
// A deadlock cannot be asserted, only survived: if this test hangs, the nesting is
// wrong again. That is the whole point of having it.
fn test_applying_settings_at_startup_does_not_deadlock() {
	h := harness_for([rpc.ok('{}')])
	h.app.apply_settings()
	assert h.fake.method_of(0) == 'aria2.changeGlobalOption', h.fake.method_of(0)
}

// And a refusal at startup has to reach the user as a notice rather than being
// swallowed - the whole reason startup reads the answer back instead of assuming.
fn test_settings_aria2_refuses_at_startup_are_reported() {
	h := harness_for([rpc.ok('{"split":"Must be between 1 and 16"}')])
	h.app.apply_settings()
	assert h.app.state.notices.count() == 1, 'a refused limit at startup must be visible'
	ns := h.app.state.notices.drain()
	assert ns.len == 1, ns.len.str()
	assert ns[0].text.contains('aria2'), ns[0].text
}

// ---- notices ------------------------------------------------------------

// A button press has to be visible immediately; the tick that confirms it is up to
// a second away. The notice is the feedback, not the confirmation.
fn test_a_pause_produces_a_notice_delivered_exactly_once() {
	h := harness_for([rpc.ok('"aaa"')])
	h.call('pause', '{"gid":"aaa"}')
	assert h.app.state.notices.count() == 1, 'a press with no feedback reads as a dead button'
	ns := h.app.state.notices.drain()
	assert ns.len == 1, 'and it must be delivered exactly once, got ${ns.len}'
	assert ns[0].gid == 'aaa', ns[0].gid
}

// forget_all is housekeeping, and a toast for it would be noise on every clear.
fn test_clearing_the_history_says_nothing() {
	h := harness_for([rpc.ok('"OK"')])
	res := h.call('forget_all', '')
	assert res.ok, res.err
	assert h.app.state.notices.count() == 0, 'housekeeping should be quiet'
}
