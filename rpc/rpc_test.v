// rpc_test.v — the aria2 client, exercised with no aria2 and no socket.
//
// Everything here runs through the fake transport, which is the point of
// Transport being a function pointer: the decoding, the multicall batching, the
// auth token and the error paths are all covered in milliseconds and cannot be
// flaky.
module rpc

import json2

// ---- the auth token -----------------------------------------------------

fn test_every_call_carries_the_token_as_the_first_parameter() {
	// aria2 authorises by a `token:<secret>` leading parameter, not a header
	// and not a login call. Forgetting it on one method is a silent 401, so
	// this asserts the position rather than just the presence.
	f := new_fake([ok('"1"')])
	mut c := f.client('s3cret')
	c.pause('abc') or { assert false, err.msg() }

	params := f.params_of(0)
	assert params.starts_with('["token:s3cret","abc"]'), 'got: ${params}'
}

fn test_the_token_is_not_sent_when_the_secret_is_empty() {
	// No secret configured is a legitimate setup (aria2 without --rpc-secret,
	// bound to loopback). The parameter must be dropped, not sent empty:
	// "token:" is a real string to aria2 and would fail authentication.
	f := new_fake([ok('"1"')])
	mut c := f.client('')
	c.pause('abc') or { assert false, err.msg() }
	assert f.params_of(0) == '["abc"]', 'got: ${f.params_of(0)}'
}

fn test_request_ids_are_unique_per_call() {
	f := new_fake([ok_raw(fixture_version)])
	mut c := f.client('s')
	c.version() or { assert false, err.msg() }
	c.version() or { assert false, err.msg() }
	assert f.requests.len == 2
	assert f.requests[0] != f.requests[1], 'ids must differ: ${f.requests[0]} vs ${f.requests[1]}'
}

// ---- error handling -----------------------------------------------------

fn test_an_aria2_error_becomes_an_error_value_with_code_and_message() {
	// Never a panic and never a silent zero: the UI has to be able to say
	// "download 3 failed" rather than render an empty row.
	f := new_fake([err_body('1', 'Unauthorized')])
	mut c := f.client('wrong')
	mut msg := ''
	c.pause('abc') or { msg = err.msg() }
	assert msg != '', 'a rejected call must return an error'
	assert msg.contains('Unauthorized'), 'got: ${msg}'
	assert msg.starts_with('aria2: '), 'errors are namespaced: ${msg}'
}

fn test_a_response_with_neither_result_nor_error_is_an_error() {
	// A proxy or a captive portal can answer 200 with HTML. That must not
	// decode into a plausible-looking empty result, and it must not panic -
	// the endpoint is on loopback, so a wrong answer there is reachable.
	for junk in ['<html>captive portal</html>', '"just a string"', '42', 'null', '[]', '[1,2,3]'] {
		f := new_fake([ok_raw(junk)])
		mut c := f.client('s')
		mut msg := ''
		c.version() or { msg = err.msg() }
		assert msg != '', 'garbage must not decode: ${junk}'
	}
}

fn test_a_transport_failure_propagates_unchanged() {
	// Connection refused is a transport error, not a JSON-RPC one, and the two
	// want different handling in the UI.
	f := new_fake([Reply{
		err: 'connection refused'
	}])
	mut c := f.client('s')
	mut msg := ''
	c.version() or { msg = err.msg() }
	assert msg.contains('connection refused'), 'got: '
}

fn test_a_client_with_no_transport_says_so_instead_of_crashing() {
	// A misconfigured engine must produce a sentence, not a nil dereference.
	mut c := new('127.0.0.1', 6800, 's')
	mut msg := ''
	c.version() or { msg = err.msg() }
	assert msg.contains('no transport'), 'got: '
}

fn test_error_codes_from_several_failures_stay_distinct() {
	// The UI groups failures by code, so two different aria2 errors must not
	// collapse into one message.
	//
	// `for a, b in array` iterates (index, element) in V, so the pairs are
	// unpacked by hand - a `for code, want in [[..],[..]]` reads like Python and
	// silently binds the index to the code.
	mut seen := map[string]string{}
	for pair in [['1', 'Unauthorized'], ['3', 'Not found'], ['32', 'Timeout']] {
		code := pair[0]
		want := pair[1]
		f := new_fake([err_body(code, want)])
		mut c := f.client('s')
		mut got := ''
		c.version() or { got = err.msg() }
		assert got != '', 'error ${code} must be reported'
		seen[code] = got
		assert got.contains(want), 'code ${code}: got ${got}'
		assert got.contains(code), 'code ${code}: got ${got}'
	}
	assert seen.len == 3
}

// ---- decoding -----------------------------------------------------------

fn test_status_decodes_the_fields_the_ui_binds_to() {
	f := new_fake([ok_raw(fixture_status_active)])
	mut c := f.client('s')
	s := c.tell_status('2089b05ecca3d829', []) or { assert false, err.msg() }
	assert s.gid == '2089b05ecca3d829'
	assert s.status == 'active'
	assert s.total_length == 1048576
	assert s.completed_length == 524288
	assert s.download_speed == 131072
	assert s.upload_speed == 2048
	assert s.connections == 4
	assert s.num_pieces == 64
	assert s.dir == '/downloads'
}

fn test_a_real_aria2_failure_payload_decodes_to_the_reason() {
	// This is the test that could not have failed before, and that is the point.
	//
	// The decoder read the JSON key `error`, and the fake's fixture also said
	// `error`, so the suite proved that a failure's reason arrived intact. Real
	// aria2 has never sent a key called `error`. It sends `errorCode` and
	// `errorMessage`; the fixture was written from memory and encoded the wish.
	// The consequence was invisible in the tests and obvious in the app: every
	// failed download toasted "no reason given".
	//
	// The payload below is copied from aria2 1.37.0 on this machine, so the
	// assertion is about a key set that really exists - and, just as important,
	// there is no `error` key in it for a decoder to fall back on.
	payload := '{"gid":"910f7f5c4e3ad7a4","status":"error","totalLength":"0","completedLength":"0","uploadLength":"0","downloadSpeed":"0","connections":"0","errorCode":"1","errorMessage":"gopher is not supported yet.","dir":"/downloads","numPieces":"0","pieceLength":"1048576"}'
	// The key form, with the colon. Searching for a bare `"error"` matches
	// `"status":"error"` - which is a VALUE - and so would pass or fail for
	// reasons that have nothing to do with the bug this test is about.
	assert !payload.contains('"error":'), 'the payload must not invent an error key'

	f := new_fake([ok_raw(payload)])
	mut c := f.client('s')
	s := c.tell_status('910f7f5c4e3ad7a4', []) or { assert false, err.msg() }
	assert s.error == 'gopher is not supported yet.', 'reason lost: ${s.error}'
	assert s.error_code == '1', 'code lost: ${s.error_code}'
	assert s.status == 'error'
}

// The shipped fixture has to keep saying the same thing, or the contract test
// above and the fake have drifted apart - which is how the original bug lived
// for a whole phase.
fn test_the_error_fixture_matches_the_real_payload() {
	f := new_fake([ok_raw(fixture_status_error)])
	mut c := f.client('s')
	s := c.tell_status('910f7f5c4e3ad7a4', []) or { assert false, err.msg() }
	assert s.error == 'gopher is not supported yet.', s.error
	assert s.error_code == '1', s.error_code
	assert !fixture_status_error.contains('"error":'), 'the fixture invented an error key'
}

fn test_status_derivations_are_safe_at_the_edges() {
	// Zero and unknown sizes are normal, and a NaN or a negative ETA would
	// render as garbage in the row.
	mut s := Status{
		gid:              'x'
		status:           'active'
		total_length:     0
		completed_length: 0
		download_speed:   0
	}
	assert s.percent() == 0.0, 'unknown size must be 0%, not a division by zero'
	assert s.eta_seconds() == -1, 'no rate means no ETA'

	s.total_length = 100
	s.completed_length = 50
	s.download_speed = 10
	assert s.percent() == 50.0
	assert s.eta_seconds() == 5

	// More completed than total happens when a torrent is re-checked.
	s.completed_length = 150
	assert s.percent() == 100.0, 'progress is clamped, not reported as 150%'
	assert s.eta_seconds() == 0
}

fn test_status_recognises_torrents_and_seeding() {
	plain := Status{
		gid:    'a'
		status: 'complete'
	}
	assert !plain.is_torrent()
	assert !plain.is_finished() == false, 'complete is finished'

	torrent := Status{
		gid:       'b'
		status:    'complete'
		seeder:    true
		info_hash: '0123456789abcdef0123456789abcdef01234567'
	}
	assert torrent.is_torrent()
	assert torrent.is_finished()
	assert torrent.is_seeding(), 'a complete torrent with a seed flag is seeding'

	seeding_active := Status{
		gid:       'c'
		status:    'active'
		seeder:    true
		info_hash: 'abc'
	}
	assert !seeding_active.is_seeding(), 'seeding is a complete state, not an active one'
}

fn test_global_stat_reads_both_the_shipped_and_the_documented_key_names() {
	// aria2's manual documents downloadSpeedOverall; every released build
	// answers downloadSpeed. Reading only one of them yields a plausible 0,
	// which is the worst kind of bug: the speedometer just never moves.
	f := new_fake([ok_raw(fixture_global_stat)])
	mut c := f.client('s')
	g := c.global_stat() or { assert false, err.msg() }
	assert g.download_speed == 131072
	assert g.upload_speed == 2048
	assert g.num_active == 1
	assert g.num_waiting == 2
	assert g.num_stopped == 3
	assert g.num_stopped_total == 7

	f2 := new_fake([ok_raw(fixture_global_stat_documented_names)])
	mut c2 := f2.client('s')
	g2 := c2.global_stat() or { assert false, err.msg() }
	assert g2.download_speed == 131072, 'the documented name must work too'
	assert g2.upload_speed == 2048
}

fn test_version_exposes_bit_torrent_support() {
	// The setup screen has to be able to say "this aria2 build cannot do
	// torrents" instead of failing later on the first magnet.
	f := new_fake([ok_raw(fixture_version)])
	mut c := f.client('s')
	v := c.version() or { assert false, err.msg() }
	assert v.version == '1.37.0'
	assert v.supports_torrents()
	assert v.has_feature('WebSocket')
	assert !v.has_feature('Telepathy')

	f2 := new_fake([ok_raw(fixture_version_no_bt)])
	mut c2 := f2.client('s')
	v2 := c2.version() or { assert false, err.msg() }
	assert !v2.supports_torrents()
}

fn test_peers_decode_and_the_usable_test_excludes_choking_ones() {
	f := new_fake([ok_raw(fixture_peers)])
	mut c := f.client('s')
	peers := c.get_peers('x') or { assert false, err.msg() }
	assert peers.len == 2
	assert peers[0].ip == '10.0.0.7'
	assert peers[0].port == 51413
	assert peers[0].download_speed == 65536
	assert peers[0].is_usable()
	assert !peers[1].is_usable(), 'a mutually choking peer transfers nothing'
	assert peers[1].seeder
}

fn test_files_decode_selection_state() {
	// `selected` is how the torrent file picker shows what aria2 will actually
	// fetch, so a missing key must read as "not selected" rather than true.
	f := new_fake([ok_raw(fixture_files)])
	mut c := f.client('s')
	files := c.get_files('x') or { assert false, err.msg() }
	assert files.len == 3
	assert files[0].index == 0
	assert files[0].selected
	assert files[0].length == 1024
	assert !files[1].selected
	assert files[2].path.ends_with('c.bin')
}

fn test_trackers_decode_from_the_nested_server_list() {
	f := new_fake([ok_raw(fixture_trackers)])
	mut c := f.client('s')
	ts := c.get_trackers('x') or { assert false, err.msg() }
	assert ts.len == 1
	assert ts[0].index == 1
	assert ts[0].uri == 'udp://tracker.example/announce'
}

fn test_options_decode_as_strings_because_aria2_sends_strings() {
	// aria2 types every option as text and parses it itself, so a numeric
	// option like max-concurrent-downloads arrives quoted. Reading it as a
	// number would silently yield 0.
	f := new_fake([ok_raw(fixture_global_option)])
	mut c := f.client('s')
	opts := c.get_global_option() or { assert false, err.msg() }
	assert opts['max-concurrent-downloads'] == '5'
	assert opts['max-overall-upload-limit'] == '1048576'
	assert opts['dir'] == '/downloads'
}

// ---- multicall ----------------------------------------------------------

// aria2's multicall result is NESTED, and the nesting differs between success and
// failure. Verified against aria2 1.37.0 with curl:
//
//   success ->  [ [ {...} ], [ [] ] ]     each result inside a 1-element array
//   failure ->  [ [ {...} ], {code:1,...} ]   the error comes back BARE
//
// The client's first version assumed one result per element, unwrapped nothing,
// and decoded a correctly-answered call into "expected a global stat object".
fn test_multicall_unwraps_the_success_wrapper() {
	// One element, wrapped, exactly as aria2 sends it.
	body := '{"jsonrpc":"2.0","id":"1","result":[[{"version":"1.37.0"}]]}'
	f := new_fake([ok_envelope(body)])
	mut c := f.client('tok')
	got := c.multicall([call_of('aria2.getVersion', [])]) or {
		assert false, err.msg()
		return
	}
	assert got.len == 1
	m := opt_map(got[0]) or {
		assert false, 'the wrapper must be removed, got ${got[0].str()}'
		return
	}
	assert (m['version'] or { json2.Any('') }).str() == '1.37.0'
}

fn test_a_failed_sub_call_is_an_error_that_names_the_call() {
	// aria2 reports a per-call failure as a bare error object in that slot. If it
	// were decoded as a result, a tellWaiting that failed would surface as
	// "expected a list of statuses" - which names none of the six calls and
	// points at the wrong one.
	//
	// All six slots are present: the length check runs first, so a short fixture
	// would fail for the wrong reason and this test would prove nothing.
	body := '{"jsonrpc":"2.0","id":"1","result":[' +
		'[{"downloadSpeed":"0","numActive":"0","numWaiting":"0","numStopped":"0","numStoppedTotal":"0","uploadSpeed":"0"}],' +
		'[[]],' +
		'{"code":1,"message":"No such method: aria2.tellWaiting"},' +
		'[[]],[[]],' +
		'[{"version":"1.37.0"}],' +
		'[{}]' +
		']}'
	f := new_fake([ok_envelope(body)])
	mut c := f.client('tok')
	c.snapshot(10, 5) or {
		assert err.msg().contains('aria2.tellWaiting'), err.msg()
		assert err.msg().contains('No such method'), err.msg()
		return
	}
	assert false, 'a failed sub-call must not decode as a snapshot'
}

fn test_the_calls_before_a_failed_one_still_decode() {
	// What makes the per-call error useful: the slots BEFORE the failure are fine,
	// and a caller asking for one of them directly gets a value. (A snapshot
	// cannot be assembled from a partial multicall - it would be a queue with a
	// hole in it - which is why the whole thing is an error.)
	body := '{"jsonrpc":"2.0","id":"1","result":[' +
		'[{"downloadSpeed":"1","numActive":"0","numWaiting":"0","numStopped":"0","numStoppedTotal":"0","uploadSpeed":"0"}],' +
		'[[]],' +
		'{"code":1,"message":"boom"}]}'
	f := new_fake([ok_envelope(body)])
	mut c := f.client('tok')
	mut calls := [call_of('aria2.getGlobalStat', []json2.Any{}),
		call_of('aria2.tellActive', []json2.Any{})]
	got := c.multicall(calls) or {
		assert false, err.msg()
		return
	}
	assert got.len == 3, 'every slot comes back, failed or not: ${got.len}'
	res := as_global_stat(as_sub_result('aria2.getGlobalStat', got[0])!) or {
		assert false, err.msg()
		return
	}
	assert res.download_speed == 1
	// And the failed slot is an error that names itself.
	as_sub_result('aria2.tellWaiting', got[2]) or {
		assert err.msg().contains('aria2.tellWaiting'), err.msg()
		assert err.msg().contains('boom'), err.msg()
		return
	}
	assert false, 'a bare error object must not pass as a result'
}

fn test_a_multicall_result_that_is_not_an_array_is_an_error() {
	// Defensive, and cheap: the endpoint is on loopback where something that is
	// not aria2 can answer.
	f := new_fake([ok_raw('{"nope":true}')])
	mut c := f.client('tok')
	c.multicall([call_of('aria2.getVersion', [])]) or {
		assert err.msg().contains('did not return an array'), err.msg()
		return
	}
	assert false, 'a non-array result must be an error'
}

fn test_a_snapshot_costs_exactly_one_request() {
	// This is the number one latency in the app: the UI heartbeat. Six
	// separate round trips would make the window stutter on every beat.
	body := snapshot_body(fixture_global_stat, '[' + fixture_status_active + ']',
		'[]', '[]')
	f := new_fake([ok_envelope(body)])
	mut c := f.client('s')
	s := c.snapshot(100, 50) or { assert false, err.msg() }
	assert f.requests.len == 1, 'a snapshot must be one request, got ${f.requests.len}'
	assert f.method_of(0) == 'system.multicall'
	assert s.stat.download_speed == 131072
	assert s.active.len == 1
	assert s.waiting.len == 0
	assert s.version.supports_torrents()
	assert s.options['dir'] == '/downloads'
}

fn test_the_multicall_batches_the_six_calls_the_ui_actually_needs() {
	f := new_fake([ok_raw('[]')])
	mut c := f.client('tok')
	c.multicall(snapshot_calls(10, 5)) or { assert false, err.msg() }
	body := f.params_of(0)
	for want in ['aria2.getGlobalStat', 'aria2.tellActive', 'aria2.tellWaiting', 'aria2.tellStopped',
		'aria2.getVersion', 'aria2.getGlobalOption'] {
		assert body.contains(want), 'the batch is missing ${want}: ${body}'
	}
	// Each sub-call carries the token too, or aria2 rejects the inner ones.
	assert body.contains('"token:tok"')
	// NOTE: there is deliberately no `contains('[0,10]')` assertion here any more.
	// That substring appeared only while the arguments were wrongly wrapped, and
	// it matched inside both the broken string form and the broken nested-array
	// form - it passed on two shapes that a real aria2 rejects. The positional
	// arguments are checked structurally in
	// test_the_multicall_params_are_arrays_and_not_strings below.
}

// The test that should have existed. It failed against a real aria2 and passed
// against the fake, because the fake never validates the request shape.
//
// The bug: each sub-call's params were sent wrapped - first as one JSON string,
// then as a nested array - so a real aria2 answered `1: The parameter at 0 has
// wrong type.` for every single tick. The assertion above could not see either
// shape, because the substring `[0,10]` occurs inside a quoted string and inside
// a nested array alike.
//
// So this one decodes the recorded body and checks the SHAPE, which is the thing
// that was actually wrong.
fn test_the_multicall_params_are_arrays_and_not_strings() {
	f := new_fake([ok_raw('[]')])
	mut c := f.client('tok')
	c.multicall(snapshot_calls(10, 5)) or { assert false, err.msg() }

	// Decode the recorded request the same way aria2 will: as JSON, then by type.
	any := json2.decode[json2.Any](f.requests[0]) or {
		assert false, err.msg()
		return
	}
	req := opt_map(any) or {
		assert false, 'the body is not an object'
		return
	}
	batch := opt_arr(req['params'] or { json2.Any('') }) or {
		assert false, 'the outer params must be an array'
		return
	}
	// The outer params are the batch and NOTHING ELSE. A token beside it is the
	// one shape a real aria2 rejects outright ("The parameter at 0 has wrong
	// type."), verified against aria2 1.37.0 with curl - see call_with.
	assert batch.len == 1, 'the batch must be the ONLY outer argument, got ${batch.len}'
	entries := opt_arr(batch[0]) or {
		assert false, 'the batch must be an array of sub-calls, got ${batch[0].str()}'
		return
	}
	assert entries.len == 6, 'got ${entries.len} sub-calls'
	for e in entries {
		m := opt_map(e) or {
			assert false, 'each sub-call is an object'
			return
		}
		name := (m['methodName'] or { json2.Any('') }).str()
		// THE assertion. opt_arr, not `as []json2.Any`: in V 0.5.2 an `as` cast on
		// a json2.Any holding something else PANICS rather than returning none,
		// which would turn a clear test failure into a crashed test binary.
		params := opt_arr(m['params'] or { json2.Any('') }) or {
			assert false, '${name}: params must be an ARRAY, not ${(m['params'] or { json2.Any('') }).str()}'
			return
		}
		assert params[0].str() == 'token:tok', '${name}: the token must come first, got ${params[0].str()}'
		// Nothing may be NESTED. aria2 reads positional arguments from a flat
		// list, so ["token:x", [0,10]] is as wrong as ["token:x", "[0,10]"].
		for j, p in params {
			// The token at index 0 is a string by design; everything after it must
			// be a scalar, because aria2 reads positional arguments from a flat list.
			if j == 0 {
				continue
			}
			match p {
				[]json2.Any {
					assert false, '${name}: argument ${j} is a nested array: ${p.str()}'
				}
				string {
					assert false, '${name}: argument ${j} is a string: ${p.str()}'
				}
				else {}
			}
		}
	}
	// And the positional numbers survive as numbers, not as text.
	//
	// `opt_map` returns an Option, not a Result, so there is NO `err` in scope
	// here - `or { assert false, err.msg() }` does not compile. An Option has no
	// error to report, so the message has to say what was expected instead.
	waiting := opt_map(entries[2]) or {
		assert false, 'the third sub-call must be an object: ${entries[2].str()}'
		return
	}
	wp := opt_arr(waiting['params'] or { json2.Any('') }) or {
		assert false, 'tellWaiting params must be an array'
		return
	}
	assert wp.len == 3, 'token + two positional numbers, got ${wp.len}'
	assert wp[1].str() == '0', wp[1].str()
	assert wp[2].str() == '10', wp[2].str()
}

fn test_a_short_multicall_result_is_an_error_not_a_partial_snapshot() {
	// A snapshot missing a section would render as an empty list, which reads
	// as "no downloads" - the most misleading possible answer.
	f := new_fake([ok_raw('[1,2,3]')])
	mut c := f.client('s')
	mut msg := ''
	c.snapshot(10, 10) or { msg = err.msg() }
	assert msg.contains('of 6'), 'got: '
}

fn test_an_empty_batch_is_a_no_op() {
	// A snapshot with nothing to ask should not spend a request.
	f := new_fake([ok_raw('[]')])
	mut c := f.client('s')
	res := c.multicall([]) or { assert false, err.msg() }
	assert res.len == 0
	assert f.requests.len == 0
}

fn test_snapshot_all_orders_active_then_queued_then_finished() {
	// The order is the queue's own, so the frontend must not have to sort.
	body := snapshot_body(fixture_global_stat, '[' + fixture_status_active + ']',
		'[' + fixture_status_complete + ']', '[' + fixture_status_error + ']')
	f := new_fake([ok_envelope(body)])
	mut c := f.client('s')
	s := c.snapshot(100, 50) or { assert false, err.msg() }
	all := s.all()
	assert all.len == 3
	assert all[0].status == 'active'
	assert all[1].status == 'complete'
	assert all[2].status == 'error'
	// The message and the code both survive the batch, and the batch is where a
	// field used to get lost: a multicall wraps every result, so a key read from the
	// wrong level is empty rather than wrong. Real values from aria2 1.37.0.
	assert all[2].error == 'gopher is not supported yet.', 'the error message must survive: ${all[2].error}'
	assert all[2].error_code == '1', all[2].error_code
}

// ---- adding downloads ---------------------------------------------------

fn test_add_uri_sends_mirrors_as_one_array() {
	// Several URIs for one file is how aria2 does multi-source fetching, so
	// they belong in a single addUri call, not in several.
	f := new_fake([ok('"2089b05ecca3d829"')])
	mut c := f.client('s')
	gid := c.add_uri(['https://a.example/f.iso', 'https://b.example/f.iso'], {
		'dir':                       '/downloads'
		'max-connection-per-server': '16'
	}) or { assert false, err.msg() }
	assert gid == '2089b05ecca3d829'
	params := f.params_of(0)
	assert params.contains('["https://a.example/f.iso","https://b.example/f.iso"]'), params
	// Options go in as strings, because that is what aria2 parses.
	assert params.contains('"max-connection-per-server":"16"'), params
}

fn test_add_uri_without_options_omits_the_options_argument() {
	// aria2 accepts a two-argument call; sending an empty object is not the
	// same thing and has bitten clients before.
	f := new_fake([ok('"g"')])
	mut c := f.client('s')
	c.add_uri(['https://a.example/f'], {}) or { assert false, err.msg() }
	params := f.params_of(0)
	assert params.starts_with('["token:s"'), params
	assert params.ends_with(']') && !params.contains('{}'), params
}

fn test_add_torrent_sends_base64_metadata() {
	f := new_fake([ok('"c"')])
	mut c := f.client('s')
	c.add_torrent('ZDE0OmEubWFnbmV0', [], {
		'dir': '/downloads'
	}) or { assert false, err.msg() }
	params := f.params_of(0)
	assert params.contains('"ZDE0OmEubWFnbmV0"'), params
	assert params.contains('"dir":"/downloads"'), params
}

// ---- options the UI drives ---------------------------------------------

fn test_change_option_sends_the_gid_and_the_option_map() {
	f := new_fake([ok('"OK"')])
	mut c := f.client('s')
	c.change_option('abc', {
		'max-download-limit': '2M'
		'seed-ratio':         '1.5'
	}) or { assert false, err.msg() }
	params := f.params_of(0)
	assert params.contains('"abc"'), params
	assert params.contains('"max-download-limit":"2M"'), params
	assert params.contains('"seed-ratio":"1.5"'), params
}

fn test_change_global_option_needs_no_gid() {
	// The scheduler drives this one, and the difference from change_option is
	// a missing first argument - which is easy to get wrong.
	f := new_fake([ok('"OK"')])
	mut c := f.client('s')
	c.change_global_option({
		'max-overall-download-limit': '1048576'
	}) or { assert false, err.msg() }
	params := f.params_of(0)
	assert params.starts_with('["token:s",{'), params
	assert params.contains('"max-overall-download-limit":"1048576"'), params
}

fn test_queue_control_methods_target_the_right_command() {
	// A typo in an aria2 method name fails at runtime with a confusing error,
	// and these names all look alike. Asserting the wire keeps them honest.
	cases := [
		['pause', 'aria2.pause']
		['force_pause', 'aria2.forcePause']
		['resume', 'aria2.unpause']
		['remove', 'aria2.remove']
		['remove_result', 'aria2.removeDownloadResult']
		['pause_all', 'aria2.pauseAll']
		['resume_all', 'aria2.unpauseAll']
		['force_pause_all', 'aria2.forcePauseAll']
		['purge_results', 'aria2.purgeDownloadResult']
		['save_session', 'aria2.saveSession']
		['shutdown', 'aria2.shutdown']
		['force_shutdown', 'aria2.forceShutdown'],
	]
	for c2 in cases {
		f := new_fake([ok('"OK"')])
		mut c := f.client('s')
		match c2[0] {
			'pause' { c.pause('g') or {} }
			'force_pause' { c.force_pause('g') or {} }
			'resume' { c.resume('g') or {} }
			'remove' { c.remove('g') or {} }
			'remove_result' { c.remove_result('g') or {} }
			'pause_all' { c.pause_all() or {} }
			'resume_all' { c.resume_all() or {} }
			'force_pause_all' { c.force_pause_all() or {} }
			'purge_results' { c.purge_results() or {} }
			'save_session' { c.save_session() or {} }
			'shutdown' { c.shutdown() or {} }
			'force_shutdown' { c.force_shutdown() or {} }
			else {
				assert false, 'unhandled case ${c2[0]}'
			}
		}
		assert f.method_of(0) == c2[1], '${c2[0]} sent ${f.method_of(0)}, want ${c2[1]}'
	}
}

fn test_change_position_passes_pos_and_how() {
	// The drag handle in the queue reorders, and aria2's signature is
	// (gid, pos, how) with `how` being a keyword string, not a flag.
	f := new_fake([ok('2')])
	mut c := f.client('s')
	c.change_position('abc', 0, 'POS_SET') or { assert false, err.msg() }
	params := f.params_of(0)
	assert params.starts_with('["token:s","abc",0,"POS_SET"]'), params
}

// ---- endpoint handling --------------------------------------------------

fn test_the_client_builds_a_loopback_endpoint_by_default() {
	c := new('127.0.0.1', 16800, 's')
	assert c.endpoint == 'http://127.0.0.1:16800/jsonrpc'
}

fn test_remote_endpoints_are_rejected() {
	// The RPC secret is a bearer token in the request body. Over the network it
	// is a token on the network, and Fluxget has no reason to accept that -
	// the daemon is always a child process on this machine.
	assert is_loopback('http://127.0.0.1:8735/jsonrpc')
	assert is_loopback('http://localhost:6800/jsonrpc')
	assert is_loopback('http://[::1]:6800/jsonrpc')
	assert !is_loopback('http://192.168.1.10:6800/jsonrpc')
	assert !is_loopback('http://example.com/jsonrpc')
}

fn test_endpoint_default_path_is_the_documented_one() {
	assert default_path == '/jsonrpc'
	assert default_port == 6800
}

// ---- getUris: the source of a download ---------------------------------

// Captured shape from aria2 1.37.0. `uri` is the field name, and it is the only
// way a failed download can be retried - which is why this decoder exists rather
// than a command handler re-parsing the raw JSON.
const fixture_uris = '[{"uri":"https://example.com/a.bin","status":"used"},{"uri":"https://mirror.example.com/a.bin","status":"waiting"}]'

fn test_uris_are_decoded_from_the_uri_field() {
	f := new_fake([ok_raw(fixture_uris)])
	mut c := f.client('s')
	got := c.uris('2089b05ecca3d829') or {
		assert false, err.msg()
		return
	}
	assert got.len == 2, got.len.str()
	assert got[0] == 'https://example.com/a.bin', got[0]
	assert got[1] == 'https://mirror.example.com/a.bin', got[1]
	assert f.method_of(0) == 'aria2.getUris', f.method_of(0)
}

// aria2 reports every mirror separately, and re-adding the same URI twice is how a
// mirror list becomes a self-inflicted stampede on one host.
fn test_duplicate_uris_are_collapsed() {
	f := new_fake([ok_raw('[{"uri":"https://a/b"},{"uri":"https://a/b"},{"uri":"https://a/c"}]')])
	mut c := f.client('s')
	got := c.uris('g') or {
		assert false, err.msg()
		return
	}
	assert got.len == 2, 'duplicates must collapse: ${got}'
	assert got[0] == 'https://a/b' && got[1] == 'https://a/c', '${got}'
}

// A torrent added from .torrent bytes has no address to re-add. Reporting an empty
// list is how the caller learns to say "this cannot be retried" instead of
// attempting an add with nothing to add.
fn test_an_entry_with_no_uri_is_dropped_rather_than_reported_as_empty() {
	f := new_fake([ok_raw('[{"uri":""},{"status":"used"}]')])
	mut c := f.client('s')
	assert (c.uris('g') or { []string{} }).len == 0
}

// Empty is a legitimate answer, not an error.
fn test_no_uris_is_an_empty_list_not_an_error() {
	f := new_fake([ok_raw('[]')])
	mut c := f.client('s')
	got := c.uris('g') or {
		assert false, 'an empty array must not be an error'
		return
	}
	assert got.len == 0
}

// ---- refused options ----------------------------------------------------

// The most misreadable thing in aria2's API: changeOption and changeGlobalOption
// answer with the options they would NOT set. A caller that ignores this renders a
// limit as saved while the engine runs with a different one.
fn test_refused_options_are_decoded_from_the_answer() {
	got := refused_options('{"split":"Must be between 1 and 16"}')
	assert got.len == 1, '${got}'
	assert got['split'] == 'Must be between 1 and 16', '${got}'
}

fn test_nothing_refused_is_an_empty_map_not_a_json_object() {
	assert refused_options('{}').len == 0, 'aria2 answers {} when nothing was refused'
	assert refused_options('').len == 0, 'an empty answer is nothing refused'
	assert refused_options('   ').len == 0
}

// Unparseable is treated as "nothing refused" on purpose: a malformed refusal is
// not evidence that the settings failed, and the settings path reports the
// engine's own echo separately so a real mismatch still surfaces.
fn test_an_unparseable_refusal_is_treated_as_nothing_refused() {
	assert refused_options('not json').len == 0
	assert refused_options('[1,2,3]').len == 0, 'an array is not a refusal map'
}
