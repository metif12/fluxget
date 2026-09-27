// fake.v — a scripted aria2, with no aria2 in sight.
//
// This is the whole reason Transport is a function pointer. `v test` must stay
// pure (the vails rule: never open a window, never start a process), and yet
// the client, the multicall batching, the decoding and the error paths all
// need to be exercised. A fake answers from a table.
//
// It is a module file rather than part of a _test.v because the supervisor's
// tests need it too, and V compiles each test file as its own module - so
// helpers cannot be shared between them. Same reason services/install_test.v
// says in the vails repo.
module rpc

import json2
import time

// Reply is one canned response, or a refusal.
pub struct Reply {
pub mut:
	// body is the raw response. Used when result is none.
	body string
	// result, when set, is encoded as a successful JSON-RPC response.
	result ?json2.Any
	// err makes the transport itself fail, standing in for a connection that
	// never completed.
	err string
	// delay_ms makes the fake slow, for timeout tests.
	delay_ms int
}

// Fake is a scripted transport. It records every request body it saw, so a
// test can assert on the wire - that is how the token parameter and the
// multicall shape are checked, not just the decoded result.
pub struct Fake {
pub mut:
	// replies are returned in order. The last one repeats once exhausted, so a
	// test can script "one failure, then healthy" without counting calls.
	replies []Reply
	// requests is every body received, in order.
	requests []string
	// index is the next reply to serve.
	index int
}

// new_fake builds a fake with a fixed reply sequence.
pub fn new_fake(replies []Reply) &Fake {
	mut f := &Fake{}
	for r in replies {
		f.replies << r
	}
	return f
}

// ok encodes a successful response around a result.
pub fn ok(result string) Reply {
	return Reply{
		result: json2.Any(result)
	}
}

// ok_raw encodes a successful response around a raw JSON fragment, so a test
// can hand the client a pre-built object without escaping it by hand.
pub fn ok_raw(fragment string) Reply {
	return Reply{
		body: '{"jsonrpc":"2.0","id":"1","result":' + fragment + '}'
	}
}

// ok_envelope serves a *complete* response body verbatim, for the cases where
// the fixture already includes the JSON-RPC envelope. Using ok_raw on such a
// fixture double-wraps it, and the client then correctly reports that the
// result is an object rather than the array it should be - a mistake worth a
// named helper for.
pub fn ok_envelope(body string) Reply {
	return Reply{
		body: body
	}
}

// err_body encodes a JSON-RPC error response, the way aria2 answers a bad call.
pub fn err_body(code string, message string) Reply {
	return Reply{
		body: '{"jsonrpc":"2.0","id":"1","error":{"code":' + code + ',"message":"' +
			message + '"}}'
	}
}

// transport is the Transport to hand a Client.
//
// The `mut p := f` indirection is load-bearing. The closure has to advance the
// reply cursor and record requests, and a V closure gets a *copy* of whatever
// it captures unless that capture is mutable - so the pointer is copied into a
// mutable local first. Without it the fake answers from a script it never
// advances, and every recorded-request assertion passes for the wrong reason.
pub fn (f &Fake) transport() Transport {
	mut p := f
	return fn [mut p] (body string) !string {
		p.requests << body
		if p.replies.len == 0 {
			return error('fake: no reply scripted')
		}
		i := if p.index < p.replies.len { p.index } else { p.replies.len - 1 }
		p.index++
		r := p.replies[i]
		if r.delay_ms > 0 {
			time.sleep(r.delay_ms)
		}
		if r.err != '' {
			return error(r.err)
		}
		// `if r.result != none` does not smart-cast in V, and calling .str() on
		// the Option itself miscompiles. Bind it instead.
		if v := r.result {
			return '{"jsonrpc":"2.0","id":"1","result":' + v.str() + '}'
		}
		return r.body
	}
}

// client returns a Client wired to this fake, so a test never has to wire the
// transport itself and get the direction wrong.
pub fn (f &Fake) client(secret string) Client {
	return new('127.0.0.1', 6800, secret).with_transport(f.transport())
}

// request_json decodes one recorded request body.
//
// Narrowed in two steps on purpose: `json2.decode[map[string]json2.Any]` on a
// body that is not an object *panics* rather than returning an error, so a
// test helper must not assume its own client encoded things correctly. Decode
// to `Any` first, then narrow.
fn (f &Fake) request_json(index int) map[string]json2.Any {
	if index >= f.requests.len {
		return map[string]json2.Any{}
	}
	any := json2.decode[json2.Any](f.requests[index]) or {
		return map[string]json2.Any{}
	}
	return opt_map(any) or { map[string]json2.Any{} }
}

// method_of pulls the `method` member out of a recorded request body.
pub fn (f &Fake) method_of(index int) string {
	m := f.request_json(index)
	return (m['method'] or { json2.Any('') }).str()
}

// params_of pulls the `params` member out of a recorded request body, as raw
// JSON, so a test can assert on the token and the argument order.
pub fn (f &Fake) params_of(index int) string {
	m := f.request_json(index)
	p := m['params'] or { return '' }
	return p.str()
}

// ---- fixtures -----------------------------------------------------------
//
// Real-shaped aria2 payloads, trimmed to the fields Fluxget reads. Handwritten
// rather than captured so the important shape decisions stay visible.

const fixture_status_active = '{"gid":"2089b05ecca3d829","status":"active","totalLength":"1048576","completedLength":"524288","uploadLength":"1024","downloadSpeed":"131072","uploadSpeed":"2048","connections":"4","numPieces":"64","pieceLength":"16384","dir":"/downloads","files":[{"index":"1","path":"/downloads/big.iso","length":"1048576","selected":"true"}]}'

const fixture_status_complete = '{"gid":"aaaaaaaaaaaaaa01","status":"complete","totalLength":"2097152","completedLength":"2097152","downloadSpeed":"0","uploadSpeed":"0","seeder":"true","infoHash":"0123456789abcdef0123456789abcdef01234567","dir":"/downloads/linux-image","numSeeders":"42","numLeechers":"3","pieceLength":"131072","numPieces":"16"}'

const fixture_status_error = '{"gid":"bbbbbbbbbbbbbb02","status":"error","totalLength":"100","completedLength":"0","error":"Connection failed","errorCode":"3","dir":"/downloads"}'

const fixture_global_stat = '{"downloadSpeed":"131072","uploadSpeed":"2048","numActive":"1","numWaiting":"2","numStopped":"3","numStoppedTotal":"7"}'

const fixture_global_stat_documented_names = '{"downloadSpeedOverall":"131072","uploadSpeedOverall":"2048","numActive":"1","numWaiting":"2","numStopped":"3","numStoppedTotal":"7"}'

const fixture_version = '{"version":"1.37.0","enabledFeatures":["BitTorrent","Metalink","JSON-RPC","WebSocket"]}'

const fixture_version_no_bt = '{"version":"1.37.0","enabledFeatures":["JSON-RPC"]}'

const fixture_peers = '[{"peerId":"-WG0100-abcdef","ip":"10.0.0.7","port":"51413","amChoking":"false","peerChoking":"false","downloadSpeed":"65536","uploadSpeed":"1024","seeder":"false","bitfield":"0f"},{"peerId":"-WG0200-abcdef","ip":"10.0.0.8","port":"51414","amChoking":"true","peerChoking":"true","downloadSpeed":"0","seeder":"true"}]'

const fixture_files = '[{"index":"0","path":"/downloads/torrent/a.bin","length":"1024","completedLength":"1024","selected":"true"},{"index":"1","path":"/downloads/torrent/b.bin","length":"2048","completedLength":"0","selected":"false"},{"index":"2","path":"/downloads/torrent/c.bin","length":"512","completedLength":"0","selected":"false"}]'

const fixture_trackers = '[{"index":"1","servers":[{"uri":"udp://tracker.example/announce","currentUri":"udp://tracker.example/announce","downloadSpeed":"0"}]}]'

const fixture_global_option = '{"max-overall-download-limit":"0","max-overall-upload-limit":"1048576","max-concurrent-downloads":"5","dir":"/downloads","save-session":"C:/fluxget/session.txt"}'

// A whole snapshot as system.multicall would return it: an array of per-call
// results, in request order, inside a complete JSON-RPC envelope. Serve it with
// ok_envelope, not ok_raw - it already has the envelope.
fn snapshot_body(stat string, active string, waiting string, stopped string) string {
	return '{"jsonrpc":"2.0","id":"1","result":[' + stat + ',' + active + ',' + waiting + ',' +
		stopped + ',' + fixture_version + ',' + fixture_global_option + ']}'
}
