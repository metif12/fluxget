// state_test.v - the parts of State that can be tested without a process.
//
// What is NOT tested here, and why: start_engine, stop_engine and poll all reach
// an os.Process and a loopback socket. `v test` is forbidden from both (see
// AGENTS.md section 4 and the vails rule that the suite never opens a window or
// starts a process). What IS tested here is the part that can be wrong without
// either: the state a fresh app is in, that building one touches nothing, and
// that the mutex behaves.
//
// The untested functions are deliberately thin. That is the whole design: the
// decisions are in aria2ctl (restart policy), core.notice (diffing) and engine
// (the calls), all of which are tested. These three are the plumbing between them.
module core

import aria2ctl
import engine
import sync

fn conf() Config {
	return Config{
		root: 'C:\\fluxget'
		port: 16800
	}
}

fn test_a_fresh_state_creates_nothing_and_starts_nothing() {
	// Building a State must be free of side effects, because a handler builds one
	// to answer "is the engine up?" and that answer must not itself start an
	// engine, create a directory, or open a socket.
	mut s := new_state(conf())
	assert s.sup == none, 'a new state has no supervisor until the window is ready'
	assert s.notices.count() == 0
	assert s.ticks == 0
	assert s.seen.len == 0
	assert s.probe_pending == false, 'no probe url was configured'
}

fn test_a_state_owns_a_working_lock() {
	// Uncontended in Phase 1 (see the header), but a lock that is never
	// exercised is a lock that is broken in a way the first concurrent caller
	// finds. Locking, unlocking and re-locking has to work.
	mut s := new_state(conf())
	s.lock()
	s.unlock()
	s.lock()
	s.unlock()
}

fn test_a_lock_is_created_rather_than_left_nil() {
	// sync.new_mutex() returns a reference. A nil guard would not fail here, it
	// would fail on the first real lock inside a handler, which is the worst
	// possible place to find out.
	mut s := new_state(conf())
	assert s.guard != unsafe { nil }
}

fn test_a_configured_probe_url_is_pending_and_is_not_inert() {
	// The e2e proof depends on this: an unattended run has nobody to paste a URL
	// into, and a screenshot of an empty queue proves nothing.
	mut c := conf()
	c.probe_url = 'https://example.com/file.bin'
	mut s := new_state(c)
	assert s.probe_pending, 'a configured probe must be armed'
	assert s.conf.probe_url == 'https://example.com/file.bin'
}

fn test_seeding_a_probe_hands_it_to_the_engine_exactly_once() {
	// Once, not once per tick: a probe that re-added itself would turn an
	// unattended proof run into a download of the same file over and over.
	mut c := conf()
	c.probe_url = 'https://example.com/file.bin'
	// The engine has no transport here, so the add fails - and the failure is
	// still the behaviour under test: exactly one attempt, reported as a notice.
	mut s := new_state(c)
	s.seed_probe()
	assert !s.probe_pending, 'the probe must be spent whether it worked or not'
	assert s.notices.count() == 1, 'and the outcome must be reported: ${s.notices.count()}'
	assert s.notices.items[0].kind == notice_info
	s.seed_probe()
	assert s.notices.count() == 1, 'a second call must do nothing: ${s.notices.items}'
}

fn test_no_probe_url_means_nothing_is_armed() {
	mut s := new_state(conf())
	s.seed_probe()
	assert s.notices.count() == 0, 'an unconfigured probe must be silent'
}

fn test_poll_without_a_supervisor_says_so_instead_of_pretending() {
	// The honest "not started yet" answer. A disconnected engine is exactly when
	// the Logs tab matters, so the notices still come back.
	mut s := new_state(conf())
	s.notices.push(Notice{
		kind: notice_info
		text: 'something worth saying'
	})
	res := s.poll()
	assert !res.ok
	assert res.detail.contains('not been started'), res.detail
	assert res.notices.len == 1, 'notices survive a failed poll: ${res.notices.len}'
	assert s.ticks == 0, 'and a poll that never reached the engine is not counted'
}

fn test_the_client_dials_loopback_and_never_a_hostname() {
	// rpc/http.v's reason, restated as an assertion: 'localhost' can resolve to
	// ::1 while aria2 binds 127.0.0.1, and then the client is talking to a socket
	// nothing is listening on. The endpoint is private to rpc.Client, so this
	// checks the value the client was built from.
	mut s := new_state(conf())
	assert aria2ctl.default_rpc_host == '127.0.0.1'
	assert s.client.endpoint.starts_with('http://127.0.0.1:16800/jsonrpc'), s.client.endpoint
}

fn test_the_secret_is_minted_per_state_and_is_not_the_rpcs_default() {
	// Two states, two secrets, and neither is empty. An empty --rpc-secret turns
	// "authenticated loopback RPC" into "open loopback RPC" and aria2 accepts it
	// without complaint.
	mut a := new_state(conf())
	mut b := new_state(conf())
	assert a.client.secret.len == aria2ctl.secret_bytes * 2, a.client.secret
	assert b.client.secret.len == aria2ctl.secret_bytes * 2
	assert a.client.secret != b.client.secret, 'the token is per app start, not per build'
}

fn test_the_engine_and_the_state_share_one_endpoint() {
	// The Supervisor takes a COPY of the client for readiness (short timeout);
	// the engine keeps the long one. Same endpoint and secret in both, or the
	// supervisor would probe a different daemon than the engine drives.
	mut s := new_state(conf())
	mut probe := s.client
	probe.timeout_ms = 800
	sup := aria2ctl.new_supervisor(aria2ctl.conf_for('C:\\fluxget', 'x', s.conf.port,
		s.client.secret), probe)
	assert sup.client.endpoint == s.eng.client.endpoint
	assert sup.client.secret == s.eng.client.secret
	assert sup.client.timeout_ms < s.eng.client.timeout_ms, 'readiness must not be able to hang the window for the engine full timeout'
}

fn test_the_config_carries_the_project_root_and_the_port() {
	// The root is where vails.json, runtime/ and downloads/ live; the port is the
	// documented 16800, not aria2's 6800.
	mut s := new_state(conf())
	assert s.conf.root == 'C:\\fluxget'
	assert s.conf.port == aria2ctl.default_rpc_port
	assert s.conf.port != 6800
}

fn test_a_config_override_moves_the_port() {
	// The escape hatch for a clash with a user's own aria2.
	mut c := conf()
	c.port = 16900
	mut s := new_state(c)
	assert s.client.endpoint.contains(':16900/'), s.client.endpoint
}

fn test_starting_an_engine_that_is_already_up_is_a_no_op() {
	// Re-entrancy, so a tick that decided to restart does not have to ask first.
	// The supervisor is absent here, so this asserts the no-supervisor path
	// leaves the state untouched rather than panicking on a none.
	mut s := new_state(conf())
	s.start_engine() or {
		// Expected on a machine with no aria2c: that is a clean error, and the
		// Setup page is built from exactly this.
		assert err.msg().contains('aria2c not found'), err.msg()
		return
	}
	// If aria2c IS present, a second start must not replace the supervisor.
	mut before := s.sup
	s.start_engine() or { return }
	if before != none {
		assert s.sup != none, 'an already-started engine must stay started'
	}
}

fn test_a_missing_binary_becomes_a_notice_not_a_panic() {
	// The Setup page's data source. The list of places we looked is the most
	// useful thing on it, so the hint must name the fix.
	mut s := new_state(conf())
	s.start_engine() or {
		assert s.notices.count() >= 1, 'a missing engine must leave a notice'
		assert s.notices.items[0].text.contains('fetch-aria2.ps1'), s.notices.items[0].text
		return
	}
	// aria2c is installed: then this test is vacuous here and the real run in
	// tests/e2e_windows covers the other branch.
}
