// rpc.v - the aria2 JSON-RPC client.
//
// One design decision shapes this file: the network is a parameter, not a
// dependency. `Transport` is a function pointer, so the whole client is
// testable without a socket, without an aria2 binary and without flakiness -
// which matters because `v test` must stay pure (the vails rule: never open a
// window, never start a process). The real HTTP transport lives in http.v; a
// scripted one lives in fake.v.
//
// Errors are values, always. aria2 signals failure with a JSON-RPC error
// object, and the rule here is that a failed call returns an `err`, never a
// panic and never a silent zero.
//
// V 0.5.x notes, all of which this file has to work around (see also the list
// in platform/contract.v):
//   * `x as T` yields T, not an Option, so `x as T or { ... }` does not
//     compile. The opt_* helpers at the bottom return Options instead.
//   * a map literal with mixed value types needs an explicit type annotation
//     and quoted keys.
//   * control methods return `!string` rather than `!`, so aria2's "OK" is
//     available and so the error path is testable: a `!void` result cannot be
//     captured with `:=`, which makes "did this call fail?" awkward to assert.
module rpc

import json2
import time

// Transport posts one JSON body and returns the raw response body. Returning an
// error means the request never completed (connection refused, timeout); a
// JSON-RPC error inside a 200 response is decoded by the client instead.
pub type Transport = fn (body string) !string

// default_port is aria2's own default. Fluxget does not use it: aria2ctl/conf.v
// explains why the RPC port is offset to avoid colliding with a user's own
// aria2 instance.
pub const default_port = 6800

// default_path is the JSON-RPC endpoint path.
pub const default_path = '/jsonrpc'

// Client talks to one aria2 endpoint.
pub struct Client {
pub mut:
	// endpoint is the full URL, e.g. 'http://127.0.0.1:16800/jsonrpc'.
	endpoint string
	// secret is aria2's --rpc-secret, sent as a `token:<secret>` first
	// parameter. That is how aria2 1.32+ authorises: no header, no cookie, no
	// separate login call.
	secret string
	// transport is the injected network. `none` means "not configured", which
	// every call reports as an error rather than dereferencing.
	transport ?Transport
	// next_id is the JSON-RPC id, sent as a string and incremented per request.
	next_id int
	// timeout_ms bounds a request. Local calls answer in single-digit
	// milliseconds, and a wedged aria2 must not stall the UI's heartbeat.
	timeout_ms int = 5000
}

// new builds a client for a host/port/secret triple.
pub fn new(host string, port int, secret string) Client {
	return Client{
		endpoint: 'http://${host}:${port}${default_path}'
		secret:   secret
	}
}

// with_transport returns a copy wired to a specific transport. The value
// semantics are deliberate: a test builds one client and never mutates the
// production one.
pub fn (c Client) with_transport(t Transport) Client {
	mut copy := c
	copy.transport = t
	return copy
}

// next_request_id hands out a unique-per-call id as a decimal string. The value
// is cosmetic: nothing correlates a response to a request except the id coming
// back unchanged, and a fresh id per call is what makes two concurrent ticks
// harmless.
fn (mut c Client) next_request_id() string {
	c.next_id++
	return c.next_id.str()
}

// authed prepends the token parameter. Applied to every method rather than left
// to callers, because the one place it can be forgotten is the one place it
// matters - and an aria2 that rejects a call answers with a message that looks
// like a version problem.
fn (c Client) authed(params []json2.Any) []json2.Any {
	// With no secret configured (aria2 without --rpc-secret, bound to
	// loopback) the parameter is dropped rather than sent empty: "token:" is a
	// real string to aria2 and would fail authentication.
	if c.secret == '' {
		mut out := []json2.Any{len: params.len}
		for i, p in params {
			out[i] = p
		}
		return out
	}
	mut out := []json2.Any{len: params.len + 1}
	out[0] = json2.Any('token:${c.secret}')
	for i, p in params {
		out[i + 1] = p
	}
	return out
}

// call performs one JSON-RPC request and returns the raw `result` member, still
// as JSON. Typed wrappers decode it; this stays untyped so a new aria2 field
// never needs a client change.
pub fn (mut c Client) call(method string, params []json2.Any) !json2.Any {
	mut req := map[string]json2.Any{}
	req['jsonrpc'] = json2.Any('2.0')
	req['id'] = json2.Any(c.next_request_id())
	req['method'] = json2.Any(method)
	req['params'] = json2.Any(c.authed(params))
	body := json2.encode(req)

	transport := c.transport or {
		return error('rpc: no transport configured (${c.endpoint})')
	}
	raw := transport(body) or { return err }

	// Decode in two steps, and this is not defensive overthinking: in V 0.5.2
	// `json2.decode[map[string]json2.Any]` on a body that is not an object
	// *panics* ("as cast: cannot cast string to map") instead of returning an
	// error. The RPC endpoint sits on loopback where a captive portal, a proxy
	// or a confused daemon can answer 200 with something that is not JSON-RPC.
	// A desktop app must not die because of that, so the narrowing happens
	// after a safe decode.
	decoded := json2.decode[json2.Any](raw) or {
		return error('rpc: ${method}: response is not JSON')
	}
	res := opt_map(decoded) or {
		return error('rpc: ${method}: response is not a JSON object')
	}
	// Membership, not truthiness. A missing map key yields a zero json2.Any,
	// and `if e := res['error']` asks "is this non-zero Any", which is not the
	// same question as "is the key there" - it happens to work for the zero
	// value and would silently stop working for any other falsy-looking one.
	if 'error' in res {
		return error('aria2: ${describe_error(res['error'])}')
	}
	if 'result' !in res {
		return error('rpc: ${method}: response has neither result nor error')
	}
	return res['result']
}

// multicall batches several calls into one HTTP request via
// system.multicall. This is why a tick costs one round trip and not six: the UI
// needs global stats, active, waiting, stopped, version and options, and asking
// for them separately would make the window stutter on every beat.
//
// The result is an array whose i-th element is the i-th response, so a partial
// failure stays visible per item instead of collapsing into one opaque error.
pub fn (mut c Client) multicall(calls []Call) ![]json2.Any {
	if calls.len == 0 {
		return []json2.Any{}
	}
	mut inner := []json2.Any{len: calls.len}
	for i, c2 in calls {
		// Each sub-call carries the token too, or aria2 rejects the inner ones
		// even though the outer system.multicall was authorised.
		mut params := [json2.Any('token:${c.secret}')]
		params << json2.Any(json2.encode(c2.params))
		mut entry := map[string]json2.Any{}
		entry['methodName'] = json2.Any(c2.method)
		entry['params'] = json2.Any(params)
		inner[i] = json2.Any(entry)
	}
	res := c.call('system.multicall', [json2.Any(inner)]) or { return err }
	// A separate statement rather than `return opt_arr(res) or { ... }`: when a
	// decode goes wrong the message needs to carry what actually arrived, and
	// inlining it in the return expression lost that.
	arr := opt_arr(res) or {
		return error('rpc: system.multicall did not return an array (got: ${res.str()})')
	}
	return arr
}

// Call is one entry in a multicall.
pub struct Call {
pub mut:
	method string
	params []json2.Any
}

fn call_of(method string, params []json2.Any) Call {
	return Call{
		method: method
		params: params
	}
}

// describe_error renders aria2's error object as "code: message".
fn describe_error(e json2.Any) string {
	m := opt_map(e) or { return e.str() }
	code := (m['code'] or { json2.Any('') }).str()
	msg := (m['message'] or { json2.Any('') }).str()
	if code == '' {
		return msg
	}
	return '${code}: ${msg}'
}

// ---- typed decoding -----------------------------------------------------
//
// Each of these decodes one aria2 result. They exist so a shape change shows up
// as a compile error here rather than as a wrong number in the UI.

fn as_status(a json2.Any) !Status {
	m := opt_map(a) or {
		return error('rpc: expected a status object, got ${a.str()}')
	}
	return Status{
		gid:                      str_of(m, 'gid')
		status:                   str_of(m, 'status')
		total_length:             i64_of(m, 'totalLength')
		completed_length:         i64_of(m, 'completedLength')
		upload_length:            i64_of(m, 'uploadLength')
		download_speed:           i64_of(m, 'downloadSpeed')
		upload_speed:             i64_of(m, 'uploadSpeed')
		connections:              int_of(m, 'connections')
		num_seeders:              int_of(m, 'numSeeders')
		num_leechers:             int_of(m, 'numLeechers')
		num_pieces:               int_of(m, 'numPieces')
		piece_length:             i64_of(m, 'pieceLength')
		seeder:                   bool_of(m, 'seeder')
		info_hash:                str_of(m, 'infoHash')
		dir:                      str_of(m, 'dir')
		error:                    str_of(m, 'error')
		error_code:               str_of(m, 'errorCode')
		followed_by:              str_of(m, 'followedBy')
		following_gid:            str_of(m, 'followingGid')
		belongs_to:               str_of(m, 'belongsTo')
		available_peer_count:     int_of(m, 'availablePeerCount')
		verified_length:          i64_of(m, 'verifiedLength')
		verify_integrity_pending: bool_of(m, 'verifyIntegrityPending')
		removed:                  removed_of(m)
	}
}

// removed_of reads the `removed` member, which was a boolean on older aria2 and
// became a string later. Both decode; anything else is "not removed".
fn removed_of(m map[string]json2.Any) string {
	v := m['removed'] or { return '' }
	if b := opt_bool(v) {
		return if b { 'true' } else { '' }
	}
	return v.str()
}

fn as_status_list(a json2.Any) ![]Status {
	arr := opt_arr(a) or { return error('rpc: expected a list of statuses') }
	mut out := []Status{len: arr.len}
	for i, item in arr {
		out[i] = as_status(item)!
	}
	return out
}

fn as_global_stat(a json2.Any) !GlobalStat {
	m := opt_map(a) or { return error('rpc: expected a global stat object') }
	return GlobalStat{
		// The shipped name first, the documented name second. Reading only one
		// yields a plausible zero, which is a speedometer that never moves.
		download_speed:    i64_either(m, 'downloadSpeed', 'downloadSpeedOverall')
		upload_speed:      i64_either(m, 'uploadSpeed', 'uploadSpeedOverall')
		num_active:        int_of(m, 'numActive')
		num_waiting:       int_of(m, 'numWaiting')
		num_stopped:       int_of(m, 'numStopped')
		num_stopped_total: int_of(m, 'numStoppedTotal')
	}
}

fn as_version(a json2.Any) !Version {
	m := opt_map(a) or { return error('rpc: expected a version object') }
	mut v := Version{
		version: str_of(m, 'version')
	}
	if feats := opt_arr(m['enabledFeatures'] or { json2.Any('') }) {
		for f in feats {
			v.enabled_features << f.str()
		}
	}
	return v
}

fn as_session_info(a json2.Any) !SessionInfo {
	m := opt_map(a) or { return SessionInfo{} }
	return SessionInfo{
		session_id: str_of(m, 'sessionId')
	}
}

fn as_files(a json2.Any) ![]FileEntry {
	arr := opt_arr(a) or { return error('rpc: expected a list of files') }
	mut out := []FileEntry{len: arr.len}
	for i, item in arr {
		m := opt_map(item) or { continue }
		out[i] = FileEntry{
			index:            int_of(m, 'index')
			path:             str_of(m, 'path')
			length:           i64_of(m, 'length')
			completed_length: i64_of(m, 'completedLength')
			selected:         bool_of(m, 'selected')
		}
	}
	return out
}

fn as_peers(a json2.Any) ![]Peer {
	arr := opt_arr(a) or { return error('rpc: expected a list of peers') }
	mut out := []Peer{len: arr.len}
	for i, item in arr {
		m := opt_map(item) or { continue }
		out[i] = Peer{
			peer_id:        str_of(m, 'peerId')
			ip:             str_of(m, 'ip')
			port:           int_of(m, 'port')
			am_choking:     bool_of(m, 'amChoking')
			peer_choking:   bool_of(m, 'peerChoking')
			download_speed: i64_of(m, 'downloadSpeed')
			upload_speed:   i64_of(m, 'uploadSpeed')
			seeder:         bool_of(m, 'seeder')
			bitfield:       str_of(m, 'bitfield')
		}
	}
	return out
}

fn as_trackers(a json2.Any) ![]Tracker {
	arr := opt_arr(a) or { return error('rpc: expected a list of trackers') }
	mut out := []Tracker{len: arr.len}
	for i, item in arr {
		m := opt_map(item) or { continue }
		mut t := Tracker{
			index: int_of(m, 'index')
		}
		if servers := opt_arr(m['servers'] or { json2.Any('') }) {
			if s0 := opt_map(servers[0]) {
				t.uri = str_of(s0, 'uri')
				t.current_uri = str_of(s0, 'currentUri')
				t.download_speed = i64_of(s0, 'downloadSpeed')
			}
		}
		out[i] = t
	}
	return out
}

fn as_options(a json2.Any) !Options {
	m := opt_map(a) or { return Options{} }
	mut out := Options{}
	for k, v in m {
		out[k] = v.str()
	}
	return out
}

// ---- public typed API ---------------------------------------------------

// version asks what aria2 is. Also the readiness probe: a daemon that answers
// this is up, whatever the spawner thinks.
pub fn (mut c Client) version() !Version {
	return as_version(c.call('aria2.getVersion', [])!)
}

// global_stat returns the current totals.
pub fn (mut c Client) global_stat() !GlobalStat {
	return as_global_stat(c.call('aria2.getGlobalStat', [])!)
}

// session_info returns the daemon's session id.
pub fn (mut c Client) session_info() !SessionInfo {
	return as_session_info(c.call('aria2.getSessionInfo', [])!)
}

// add_uri starts a download from one or more sources. Mirrors go in one array,
// which is how aria2 does multi-source fetching for a single file: several
// addUri calls would be several downloads.
//
// `options` is passed through as JSON strings. aria2 types every option as text
// and parses it itself ("2M", "16", "true"), so re-typing it in Fluxget would
// only create a second place for the two sides to disagree.
pub fn (mut c Client) add_uri(uris []string, options map[string]string) !string {
	mut uri_arr := []json2.Any{len: uris.len}
	for i, u in uris {
		uri_arr[i] = json2.Any(u)
	}
	mut params := [json2.Any(uri_arr)]
	// A two-argument call is not the same as an empty options object, and
	// aria2 has bitten clients over that distinction.
	if options.len > 0 {
		params << json2.Any(strings_to_json(options))
	}
	return c.call('aria2.addUri', params)!.str()
}

// add_torrent starts a torrent download from raw .torrent bytes, base64
// encoded, which is what aria2.addTorrent expects over JSON-RPC.
pub fn (mut c Client) add_torrent(base64_data string, uris []string, options map[string]string) !string {
	mut params := [json2.Any(base64_data)]
	if uris.len > 0 {
		mut uri_arr := []json2.Any{len: uris.len}
		for i, u in uris {
			uri_arr[i] = json2.Any(u)
		}
		params << json2.Any(uri_arr)
	}
	if options.len > 0 {
		params << json2.Any(strings_to_json(options))
	}
	return c.call('aria2.addTorrent', params)!.str()
}

// snapshot_calls is the exact batch a tick needs, in one place so the frontend
// and the Control API cannot drift into asking for different things.
pub fn snapshot_calls(waiting int, stopped int) []Call {
	return [
		call_of('aria2.getGlobalStat', []json2.Any{}),
		call_of('aria2.tellActive', []json2.Any{}),
		call_of('aria2.tellWaiting', [json2.Any(0), json2.Any(waiting)]),
		call_of('aria2.tellStopped', [json2.Any(0), json2.Any(stopped)]),
		call_of('aria2.getVersion', []json2.Any{}),
		call_of('aria2.getGlobalOption', []json2.Any{}),
	]
}

// Snapshot is one decoded tick.
pub struct Snapshot {
pub mut:
	stat    GlobalStat
	active  []Status
	waiting []Status
	stopped []Status
	version Version
	options Options
}

// snapshot does the whole world in one request. This is the function the UI
// heartbeat calls, so its cost is the largest single latency in the app.
pub fn (mut c Client) snapshot(waiting int, stopped int) !Snapshot {
	results := c.multicall(snapshot_calls(waiting, stopped))!
	if results.len < 6 {
		return error('rpc: system.multicall returned ${results.len} of 6 results')
	}
	return Snapshot{
		stat:    as_global_stat(results[0])!
		active:  as_status_list(results[1])!
		waiting: as_status_list(results[2])!
		stopped: as_status_list(results[3])!
		version: as_version(results[4])!
		options: as_options(results[5]) or { Options{} }
	}
}

// all returns every status in the order the UI shows them: active, then queued,
// then finished. That is the queue's own order, so the frontend never has to
// sort.
pub fn (s Snapshot) all() []Status {
	mut out := []Status{len: s.active.len + s.waiting.len + s.stopped.len}
	mut i := 0
	for item in s.active {
		out[i] = item
		i++
	}
	for item in s.waiting {
		out[i] = item
		i++
	}
	for item in s.stopped {
		out[i] = item
		i++
	}
	return out
}

// tell_status reads one download. `keys` narrows the response to a subset,
// which matters when the detail panel polls a single row every frame.
pub fn (mut c Client) tell_status(gid string, keys []string) !Status {
	mut params := [json2.Any(gid)]
	if keys.len > 0 {
		// `init:` rather than `len:`: V zero-initialises arrays of sum types,
		// and a bare `len:` leaves the array with no capacity to assign into.
		mut k := []json2.Any{len: keys.len, init: json2.Any('')}
		for i, key in keys {
			k[i] = json2.Any(key)
		}
		params << json2.Any(k)
	}
	return as_status(c.call('aria2.tellStatus', params)!)
}

// The queue and lifecycle controls all answer with aria2's literal "OK", so they
// return `!string` rather than `!`. The string is rarely needed, but returning
// it keeps the error path testable and costs nothing.

pub fn (mut c Client) pause(gid string) !string {
	return c.call('aria2.pause', [json2.Any(gid)])!.str()
}

pub fn (mut c Client) force_pause(gid string) !string {
	return c.call('aria2.forcePause', [json2.Any(gid)])!.str()
}

pub fn (mut c Client) resume(gid string) !string {
	return c.call('aria2.unpause', [json2.Any(gid)])!.str()
}

pub fn (mut c Client) remove(gid string) !string {
	return c.call('aria2.remove', [json2.Any(gid)])!.str()
}

pub fn (mut c Client) remove_result(gid string) !string {
	return c.call('aria2.removeDownloadResult', [json2.Any(gid)])!.str()
}

pub fn (mut c Client) purge_results() !string {
	return c.call('aria2.purgeDownloadResult', [])!.str()
}

pub fn (mut c Client) pause_all() !string {
	return c.call('aria2.pauseAll', [])!.str()
}

pub fn (mut c Client) resume_all() !string {
	return c.call('aria2.unpauseAll', [])!.str()
}

pub fn (mut c Client) force_pause_all() !string {
	return c.call('aria2.forcePauseAll', [])!.str()
}

// change_position reorders the queue, for the drag handle and "move to top".
// aria2's signature is (gid, pos, how) where `how` is a keyword string
// ('POS_SET', 'POS_CUR', 'POS_END'), not a flag. The result is aria2's new
// position as a bare number.
pub fn (mut c Client) change_position(gid string, pos int, how string) !int {
	res := c.call('aria2.changePosition', [json2.Any(gid), json2.Any(pos), json2.Any(how)]) or {
		return err
	}
	if n := opt_i64(res) {
		return int(n)
	}
	return 0
}

pub fn (mut c Client) get_option(gid string) !Options {
	return as_options(c.call('aria2.getOption', [json2.Any(gid)])!)
}

pub fn (mut c Client) get_global_option() !Options {
	return as_options(c.call('aria2.getGlobalOption', [])!)
}

// change_option sets per-download options. Safe at runtime for the speed caps
// and the seed policy; aria2 restarts an *active* download for anything not on
// its no-restart list, which is why the UI applies a file selection only while
// an item is queued.
pub fn (mut c Client) change_option(gid string, options map[string]string) !string {
	return c.call('aria2.changeOption', [json2.Any(gid), json2.Any(strings_to_json(options))])!.str()
}

// change_global_option sets the daemon-wide options: the speed caps, the
// concurrency limit, the session file, the log. This is what the scheduler
// drives, and it is the one call that needs no gid.
pub fn (mut c Client) change_global_option(options map[string]string) !string {
	return c.call('aria2.changeGlobalOption',
		[json2.Any(strings_to_json(options))])!.str()
}

pub fn (mut c Client) get_files(gid string) ![]FileEntry {
	return as_files(c.call('aria2.getFiles', [json2.Any(gid)])!)
}

pub fn (mut c Client) get_peers(gid string) ![]Peer {
	return as_peers(c.call('aria2.getPeers', [json2.Any(gid)])!)
}

pub fn (mut c Client) get_trackers(gid string) ![]Tracker {
	return as_trackers(c.call('aria2.getServers', [json2.Any(gid)])!)
}

pub fn (mut c Client) get_uris(gid string) !string {
	return c.call('aria2.getUris', [json2.Any(gid)])!.str()
}

// save_session flushes the queue to the --save-session file. The supervisor
// calls this before shutdown, so a crash costs at most one interval.
pub fn (mut c Client) save_session() !string {
	return c.call('aria2.saveSession', [])!.str()
}

// shutdown asks aria2 to stop cleanly, which also writes the session file.
pub fn (mut c Client) shutdown() !string {
	return c.call('aria2.shutdown', [])!.str()
}

pub fn (mut c Client) force_shutdown() !string {
	return c.call('aria2.forceShutdown', [])!.str()
}

// ---- encoding helpers ---------------------------------------------------

// strings_to_json renders an option map.
pub fn strings_to_json(options map[string]string) map[string]json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in options {
		out[k] = json2.Any(v)
	}
	return out
}

fn str_of(m map[string]json2.Any, key string) string {
	return (m[key] or { return '' }).str()
}

// i64_of reads a numeric member. Three shapes are accepted, because aria2 has
// used more than one over the years and a miss reads as a plausible zero:
// a JSON number (which json2 hands back as `int` or `i64` depending on size)
// and a numeric *string*.
fn i64_of(m map[string]json2.Any, key string) i64 {
	v := m[key] or { return 0 }
	if n := opt_i64(v) {
		return n
	}
	if n := opt_int(v) {
		return i64(n)
	}
	if s := opt_str(v) {
		return s.i64()
	}
	return 0
}

fn int_of(m map[string]json2.Any, key string) int {
	return int(i64_of(m, key))
}

fn i64_either(m map[string]json2.Any, primary string, secondary string) i64 {
	if primary in m {
		return i64_of(m, primary)
	}
	return i64_of(m, secondary)
}

fn bool_of(m map[string]json2.Any, key string) bool {
	v := m[key] or { return false }
	if b := opt_bool(v) {
		return b
	}
	return v.str() == 'true'
}

// ---- cast helpers -------------------------------------------------------
//
// These are `match` on the sum type, not `as`. In V 0.5.2, `x as map[...]` on a
// json2.Any holding something else does not return none - it *panics* with
// "as cast: cannot cast string to map[string]json2.Any". The RPC endpoint is on
// loopback where a captive portal, a proxy or a confused daemon can answer 200
// with something that is not JSON-RPC, so that panic would be a way to kill the
// app. Matching the sum type narrows safely.

fn opt_bool(v json2.Any) ?bool {
	return match v {
		bool { v }
		else { none }
	}
}

fn opt_str(v json2.Any) ?string {
	return match v {
		string { v }
		else { none }
	}
}

fn opt_i64(v json2.Any) ?i64 {
	return match v {
		i64 { v }
		else { none }
	}
}

// opt_int is separate because json2 decodes an integral JSON number to `int`,
// not `i64`. A helper that only knew about i64 would read every aria2 number as
// absent, which is the same class of bug as reading the wrong key name: a
// plausible zero.
fn opt_int(v json2.Any) ?int {
	return match v {
		int { v }
		else { none }
	}
}

fn opt_arr(v json2.Any) ?[]json2.Any {
	return match v {
		[]json2.Any { v }
		else { none }
	}
}

fn opt_map(v json2.Any) ?map[string]json2.Any {
	return match v {
		map[string]json2.Any { v }
		else { none }
	}
}

// ---- readiness ----------------------------------------------------------

// wait_ready polls version() until aria2 answers or the deadline passes. The
// supervisor calls this after spawning, because a successful spawn only means
// the process started: aria2 needs a moment to bind its RPC port, and a failed
// bind surfaces here rather than at the first UI tick.
//
// Time.add() takes nanoseconds in V 0.5.2, so the millisecond budget is
// converted rather than added directly.
pub fn (mut c Client) wait_ready(timeout_ms int, interval_ms int) ! {
	deadline := time.now().add(i64(timeout_ms) * 1000000)
	for {
		c.version() or {
			if time.now() > deadline {
				return error('rpc: aria2 did not answer within ${timeout_ms}ms (${c.endpoint})')
			}
			time.sleep(interval_ms)
			continue
		}
		return
	}
}
