// engine_test.v - the facade, driven through a scripted aria2.
//
// No socket, no process. rpc.Fake answers from a table and RECORDS every request
// body, which is the only way these tests are worth anything: the interesting
// question about a facade is not "did it return" but "did it send the right
// aria2 call", and that is asserted on the wire, not on the return value.
module engine

import json2
import rpc

// snap_body is a complete system.multicall response, in the order
// rpc.snapshot_calls asks for: global stat, active, waiting, stopped, version,
// global options.
//
// Each result is wrapped in a single-element array, which is what a real aria2
// does: a sub-call that succeeds comes back as `[result]` and one that fails
// comes back as a bare `{code, message}`. Verified against aria2 1.37.0. An
// earlier version of this fixture was flat and the tests were green anyway -
// which is exactly the failure mode of a fake that does not reproduce the wire
// format.
//
// Written out here rather than reused from rpc/fake.v because those fixtures
// are private to that module, and a test that reaches into another module's
// privates is a test that breaks when the other module is tidied up.
fn snap_body() string {
	return '{"jsonrpc":"2.0","id":"1","result":[' +
		'[{"downloadSpeed":"131072","uploadSpeed":"0","numActive":"1","numWaiting":"0","numStopped":"0"}],' +
		'[[{"gid":"aa01","status":"active","totalLength":"1024","completedLength":"512","downloadSpeed":"131072","dir":"/d"}]],' + 
	// waiting, then stopped. Both bare arrays inside their wrappers: a quoted
	// "[]" decodes as a string and the list decoder refuses it.
	'[[]],[[]],' +
		'[{"version":"1.37.0","enabledFeatures":["BitTorrent"]}],' +
		'[{"max-overall-download-limit":"0","dir":"/d"}]]}'
}

// eng wires an Engine to a fake. The indirection through &Fake is rpc/fake.v's
// documented requirement: a closure that has to advance a cursor needs a mutable
// capture.
fn eng(f &rpc.Fake) Engine {
	return new(f.client('tok'))
}

// the method of the first request the fake saw.
fn method_of(f &rpc.Fake) string {
	return f.method_of(0)
}

// the params of the first request, as raw JSON, so the option map can be read.
fn params_of(f &rpc.Fake) string {
	return f.params_of(0)
}

// Every test binds the Engine to a `mut` local before calling it.
//
// V 0.5.2 rejects a mut method on a temporary outright ("cannot pass expression
// as `mut`"), so `eng(f).add(...)` does not compile however it is parenthesised.
// The helper stays a function; the `mut` local is the caller's job.
fn test_adding_a_url_sends_add_uri_with_the_uris_as_one_array() {
	// Mirrors go in ONE addUri call. Several calls would be several Downloads,
	// which is the single most common way a client gets mirrors wrong.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	gid := e.add(AddRequest{
		uris: ['https://example.com/a.iso', 'https://mirror.example/a.iso']
	}) or {
		assert false, err.msg()
		return
	}
	assert gid == 'aa01'
	assert method_of(f) == 'aria2.addUri'
	assert params_of(f).contains('example.com/a.iso')
	assert params_of(f).contains('mirror.example/a.iso')
}

fn test_an_empty_add_is_refused_before_aria2_ever_sees_it() {
	// aria2 answers "OK" to addUri with an empty array, and there is no gid in
	// it. The UI would then wait forever for a download that does not exist.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add(AddRequest{}) or {
		assert err.msg().contains('no uri'), err.msg()
		return
	}
	assert false, 'an empty add must be an error'
	assert f.requests.len == 0, 'and it must not reach the wire: ${f.requests}'
}

fn test_blank_uris_are_dropped_rather_than_sent() {
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	mut req := AddRequest{}
	req.uris = ['  https://example.com/a.iso  ', '', '   ']
	e.add(req) or {
		assert false, err.msg()
		return
	}
	assert params_of(f).contains('https://example.com/a.iso')
	assert !params_of(f).contains('  https'), 'the uri must be trimmed: ${params_of(f)}'
}

fn test_a_runaway_mirror_list_is_refused() {
	// aria2 would accept thousands. So would a frontend bug. The cap is here so
	// the failure is a rejected request rather than a queue that stops.
	//
	// The entries are DISTINCT on purpose. A list of two hundred identical URLs is
	// a de-duplication away from being one mirror, and collapsing it is the right
	// answer - so a test built from repeats would be testing the wrong thing and
	// would fail for the right reason.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	mut req := AddRequest{}
	// `len` alongside `init`, never `cap`: V 0.5.2 rejects `init` without it.
	mut urls := []string{cap: max_add_uris + 1}
	for i in 0 .. max_add_uris + 1 {
		urls << 'https://m${i}.example/a'
	}
	req.uris = urls
	e.add(req) or {
		assert err.msg().contains('more than'), err.msg()
		return
	}
	assert false, 'too many uris must be refused'
}

// Two hundred identical URLs are one mirror, and saying so is more useful than
// refusing them: the user asked for one file from one host.
fn test_a_repeated_mirror_list_collapses_instead_of_being_refused() {
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	mut urls := []string{cap: max_add_uris + 1}
	for _ in 0 .. max_add_uris + 1 {
		urls << 'https://same.example/a'
	}
	gid := e.add(AddRequest{
		uris: urls
	}) or {
		assert false, 'a repeated list is one mirror, not a rejection: ${err.msg()}'
		return
	}
	assert gid == 'aa01', gid
}

fn test_a_magnet_is_a_uri_and_not_a_second_code_path() {
	// CONTEXT.md: a Magnet is a URI form. One addUri, no special casing.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add_magnet('magnet:?xt=urn:btih:0123456789abcdef', '') or {
		assert false, err.msg()
		return
	}
	assert method_of(f) == 'aria2.addUri'
	assert params_of(f).contains('magnet:?xt=urn:btih:')
}

fn test_only_the_options_that_were_set_are_sent() {
	// An absent key and an empty one are different instructions to aria2, so
	// nothing optional is ever sent empty.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add(AddRequest{
		uris: ['https://example.com/a.iso']
		dir:  '/downloads/here'
		out:  'renamed.iso'
	}) or {
		assert false, err.msg()
		return
	}
	p := params_of(f)
	assert p.contains('"dir":"/downloads/here"'), p
	assert p.contains('"out":"renamed.iso"'), p
	assert !p.contains('select-file'), 'unset options must be absent: ${p}'
	assert !p.contains('"pause"'), 'pause is only ever sent when true: ${p}'
}

fn test_a_paused_add_says_so_and_a_running_one_does_not() {
	// The torrent picker needs a paused item: an active one starts fetching
	// before the user has chosen which files they want.
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add(AddRequest{
		uris:   ['https://example.com/a.iso']
		paused: true
	}) or {
		assert false, err.msg()
		return
	}
	assert params_of(f).contains('"pause":"true"'), params_of(f)
}

fn test_a_staged_torrent_is_paused_with_its_selection_applied() {
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add_staged('ZDEzOmJ5dGVz', '1,3-5') or {
		assert false, err.msg()
		return
	}
	assert method_of(f) == 'aria2.addTorrent'
	p := params_of(f)
	assert p.contains('"select-file":"1,3-5"'), p
	assert p.contains('"pause":"true"'), p
}

fn test_a_torrent_add_without_bytes_is_refused() {
	f := rpc.new_fake([rpc.ok('"aa01"')])
	mut e := eng(f)
	e.add_torrent('', [], AddRequest{}) or {
		assert err.msg().contains('torrent'), err.msg()
		return
	}
	assert false, 'an empty torrent must be refused'
}

fn test_queue_controls_target_the_command_they_name() {
	// The Status vocabulary in CONTEXT.md is aria2's, passed through unchanged.
	// These four are the ones the UI's buttons call, and the argument order is
	// the part that can be wrong silently.
	cases := [
		['aria2.pause', 'aa01'],
		['aria2.unpause', 'aa01'],
		['aria2.remove', 'aa01'],
		['aria2.removeDownloadResult', 'aa01'],
	]
	for c in cases {
		f := rpc.new_fake([rpc.ok('"OK"')])
		mut e := eng(f)
		match c[0] {
			'aria2.pause' {
				e.pause('aa01') or { assert false, err.msg() }
			}
			'aria2.unpause' {
				e.resume('aa01') or { assert false, err.msg() }
			}
			'aria2.remove' {
				e.remove('aa01') or { assert false, err.msg() }
			}
			else {
				e.forget('aa01') or { assert false, err.msg() }
			}
		}
		assert method_of(f) == c[0], 'got ${method_of(f)} for ${c[0]}'
		assert params_of(f).contains('aa01'), 'the gid must be sent: ${params_of(f)}'
	}
}

fn test_pause_all_and_resume_all_need_no_gid() {
	f := rpc.new_fake([rpc.ok('"OK"'), rpc.ok('"OK"')])
	mut e := eng(f)
	e.pause_all() or { assert false, err.msg() }
	e.resume_all() or { assert false, err.msg() }
	assert f.method_of(0) == 'aria2.pauseAll'
	assert f.method_of(1) == 'aria2.unpauseAll'
}

fn test_move_to_top_and_to_end_use_aria2_keywords_not_numbers() {
	// changePosition's third argument is a keyword string. Sending 0 there
	// happens to work for POS_SET and silently does nothing for POS_END, which
	// is the kind of bug that survives a demo.
	f := rpc.new_fake([rpc.ok('1'), rpc.ok('1')])
	mut e := eng(f)
	e.move_to_top('aa01') or { assert false, err.msg() }
	e.move_to_end('aa01') or { assert false, err.msg() }
	assert params_of(f).contains(pos_set), params_of(f)
	assert f.params_of(1).contains(pos_end), f.params_of(1)
}

fn test_changing_the_files_of_an_active_download_is_refused() {
	// The domain rule from CONTEXT.md, enforced in the engine rather than the
	// UI: aria2 RESTARTS an active download to apply a new Selection, throwing
	// away its connections and its place in the queue. "The UI only offers the
	// picker before the item starts" is a suggestion; this is a refusal.
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := eng(f)
	e.set_selection('aa01', '1,3-5', status_active) or {
		assert err.msg().contains('active'), err.msg()
		return
	}
	assert false, 'an active download must refuse a selection change'
	assert f.requests.len == 0, 'and it must not reach aria2: ${f.requests}'
}

fn test_a_paused_download_accepts_a_selection_change() {
	for status in ['waiting', 'paused', 'complete', 'error'] {
		f := rpc.new_fake([rpc.ok('"OK"')])
		mut e := eng(f)
		e.set_selection('aa01', '2', status) or {
			assert false, '${status}: ${err.msg()}'
			return
		}
		assert method_of(f) == 'aria2.changeOption'
		assert params_of(f).contains('"select-file":"2"'), params_of(f)
	}
}

fn test_an_empty_selection_is_refused() {
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := eng(f)
	e.set_selection('aa01', '', 'paused') or {
		assert err.msg().contains('file index'), err.msg()
		return
	}
	assert false, 'an empty selection must be refused'
}

fn test_a_snapshot_costs_exactly_one_request() {
	// This is the UI's heartbeat. One system.multicall, not six round trips.
	f := rpc.new_fake([rpc.ok_envelope(snap_body())])
	mut e := eng(f)
	s := e.snapshot() or {
		assert false, err.msg()
		return
	}
	assert f.requests.len == 1, 'got ${f.requests.len} requests'
	assert f.method_of(0) == 'system.multicall'
	assert s.stat.download_speed == 131072
	assert s.active.len == 1
	assert s.active[0].gid == 'aa01'
	assert s.version.supports_torrents()
}

fn test_the_snapshot_asks_for_a_bounded_queue() {
	// The caps keep a tick from becoming megabytes of JSON for rows nobody is
	// looking at. aria2 keeps everything; we just do not pull it all.
	f := rpc.new_fake([rpc.ok_envelope(snap_body())])
	mut e := eng(f)
	e.snapshot() or {
		assert false, err.msg()
		return
	}
	p := params_of(f)
	assert p.contains(waiting_window.str()), 'tellWaiting cap missing: ${p}'
	assert p.contains(stopped_window.str()), 'tellStopped cap missing: ${p}'
}

fn test_an_aria2_error_reaches_the_caller_as_an_error() {
	// Not swallowed, not turned into a zero gid. A refused add must be
	// refusable all the way to the UI.
	f := rpc.new_fake([rpc.err_body('1', 'Unauthorized')])
	mut e := eng(f)
	e.add(AddRequest{
		uris: ['https://example.com/a.iso']
	}) or {
		assert err.msg().contains('Unauthorized'), err.msg()
		return
	}
	assert false, 'an aria2 error must not be a successful gid'
}

fn test_a_transport_failure_is_not_a_gid_of_empty_string() {
	// The failure mode this guards: an unreachable daemon returning '' and the
	// UI adding a row for a download that will never exist.
	f := rpc.new_fake([rpc.Reply{
		err: 'connection refused'
	}])
	mut e := eng(f)
	e.add(AddRequest{
		uris: ['https://example.com/a.iso']
	}) or {
		assert err.msg().contains('connection refused'), err.msg()
		return
	}
	assert false, 'a transport failure must be an error'
}

fn test_the_options_helper_agrees_with_what_is_on_the_wire() {
	// The map literal in AddRequest.options() and the JSON aria2 receives are
	// asserted from the same source, so a rename of an aria2 option name cannot
	// pass here and fail in a real run.
	opts := AddRequest{
		uris:        ['u']
		dir:         '/d'
		out:         'o'
		select_file: '1'
		paused:      true
	}.options()
	decoded := json2.decode[map[string]json2.Any](json2.encode(opts)) or {
		assert false, err.msg()
		return
	}
	assert decoded['dir']! == json2.Any('/d')
	assert decoded['out']! == json2.Any('o')
	assert decoded['select-file']! == json2.Any('1')
	assert decoded['pause']! == json2.Any('true')
}

// ---- retry --------------------------------------------------------------

// The full sequence, with aria2 still holding the source: read the status, read
// the source, discard the record, then add. Re-adding first fails with
// "GID#... is not unique"; discarding first loses the destination.
fn test_retry_reads_the_source_discards_the_record_then_readds() {
	f := rpc.new_fake([
		rpc.ok_raw('{"gid":"old","status":"error","dir":"D:/downloads"}'),
		rpc.ok_raw('[{"uri":"https://example.com/a.bin"}]'),
		rpc.ok('"old"'),
		rpc.ok('"fresh"'),
	])
	mut e := eng(f)
	got := e.retry('old', ['https://example.com/a.bin']) or {
		assert false, err.msg()
		return
	}
	assert f.count() == 4, 'four calls expected, got ${f.count()}'
	assert f.method_of(0) == 'aria2.tellStatus', f.method_of(0)
	assert f.method_of(1) == 'aria2.getUris', f.method_of(1)
	assert f.method_of(2) == 'aria2.removeDownloadResult', f.method_of(2)
	assert f.method_of(3) == 'aria2.addUri', f.method_of(3)
	// A new gid, always. Wrapping this as "the same download" would leave the UI
	// holding a handle to a gid the engine has already forgotten.
	assert got == 'fresh', got
}

// A retry that lands somewhere else would leave the old copy on disk and the new
// one somewhere the user did not choose.
fn test_retry_keeps_the_directory_the_download_came_from() {
	f := rpc.new_fake([
		rpc.ok_raw('{"gid":"old","status":"error","dir":"D:/downloads/movies"}'),
		rpc.ok_raw('[{"uri":"https://example.com/a.mkv"}]'),
		rpc.ok('"old"'),
		rpc.ok('"fresh"'),
	])
	mut e := eng(f)
	e.retry('old', ['https://example.com/a.mkv']) or { assert false, err.msg() }
	assert f.params_of(3).contains('movies'), f.params_of(3)
}

// Mirrors survive the retry: a download that failed on one mirror should come back
// with all of them, or a retry is a worse version of the original attempt.
fn test_retry_readds_every_mirror() {
	f := rpc.new_fake([
		rpc.ok_raw('{"gid":"old","status":"error","dir":"D:/x"}'),
		rpc.ok_raw('[{"uri":"https://a/1.bin"},{"uri":"https://b/1.bin"}]'),
		rpc.ok('"old"'),
		rpc.ok('"fresh"'),
	])
	mut e := eng(f)
	e.retry('old', ['https://example.com/a.mkv']) or { assert false, err.msg() }
	params := f.params_of(3)
	assert params.contains('https://a/1.bin') && params.contains('https://b/1.bin'), params
}

// A download added from .torrent bytes has no URI. The refusal has to come BEFORE
// the record is discarded, or the retry destroys the entry it cannot rebuild.
fn test_retry_refuses_when_there_is_no_uri_and_discards_nothing() {
	f := rpc.new_fake([
		rpc.ok_raw('{"gid":"old","status":"error","dir":"D:/x"}'),
		rpc.ok_raw('[]'),
	])
	mut e := eng(f)
	e.retry('old', []) or {
		assert err.msg().contains('nothing to retry'), err.msg()
		return
	}
	assert false, 'a download with no URI must not be retried'
	assert f.count() == 2, 'the record must not be discarded: ${f.count()} calls'
}

// The message has to say what the user can DO, not just that it failed. The answer
// is "add the .torrent again", and that is what the text says.
fn test_the_no_uri_refusal_names_the_way_out() {
	f := rpc.new_fake([
		rpc.ok_raw('{"gid":"old","status":"error","dir":"D:/x"}'),
		rpc.ok_raw('[]'),
	])
	mut e := eng(f)
	e.retry('old', []) or {
		assert err.msg().contains('.torrent'), 'the message should point at the cause: ${err.msg()}'
		return
	}
	assert false, 'expected a refusal'
}
