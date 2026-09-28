// conf_test.v - the spawn contract, asserted positionally.
//
// `args` is pure, so this file needs no process, no disk and no network. That is
// the whole reason it is a function and not a method on the supervisor: the four
// security-relevant flags below are checked on every commit, on every machine,
// in milliseconds.
//
// The order assertions are not about performance. They are so that a bug report
// can carry a spawn line that someone else can read.
module aria2ctl

// fixture is a Conf with every field set, so a test that changes one thing can
// be sure the rest did not move underneath it.
fn fixture() Conf {
	return conf_for('C:\\fluxget', 'C:\\fluxget\\runtime\\aria2c.exe', 16800, 's3cret')
}

// must_value returns what follows `flag=`, or fails the test.
//
// It exists because `assert value_of(a, '--x')! == 'y'` does not compile in
// V 0.5.2: `!` propagates a Result into the enclosing *function*, and assert is
// a statement, so the error surfaces as "to propagate a Result, the call must
// also return a Result type". The other in-assert idiom, `or { 'MISSING' }`,
// compiles but turns a missing flag into a confusing mismatch instead of a
// message that names the flag.
fn must_value(a []string, flag string) string {
	v := value_of(a, flag) or {
		assert false, '${flag} is missing from: ${a}'
		return ''
	}
	return v
}

fn test_the_loopback_bind_is_never_optional() {
	// The one flag in this file that must never become conditional. The secret
	// is a bearer token in the request body, so this flag decides whether it
	// stays on this machine or goes onto the wifi.
	a := args(fixture())
	assert has_flag(a, '--rpc-listen-all=false'), 'got ${a}'
	assert must_value(a, '--rpc-listen-all') == 'false', 'aria2 reads this as the string "false", not as absent'
	assert '--rpc-listen-all' !in a, 'the bare form would mean TRUE to aria2'
}

fn test_rpc_is_enabled_and_carries_a_secret() {
	a := args(fixture())
	assert has_flag(a, '--enable-rpc'), 'aria2 1.32+ ships with RPC off'
	assert must_value(a, '--rpc-secret') == 's3cret'
	assert must_value(a, '--rpc-listen-port') == '16800'
}

fn test_the_secret_is_never_the_empty_string() {
	// aria2 accepts `--rpc-secret=` and then requires no token at all. An empty
	// secret is the difference between an authenticated and an open RPC port, and
	// nothing on either side complains.
	for _ in 0 .. 4 {
		s := new_secret()
		assert s.len == secret_bytes * 2, 'got ${s.len} chars: ${s}'
		assert s != '', 'crypto.rand must not hand back nothing'
	}
}

fn test_two_secrets_are_not_the_same_secret() {
	// Four draws is enough to catch a constant, a reseed-per-call bug, or a
	// PRNG that forgot to advance. It is not a randomness claim, and it is not
	// meant to be.
	mut seen := map[string]bool{}
	for _ in 0 .. 8 {
		s := new_secret()
		assert !(s in seen), 'new_secret repeated itself: ${s}'
		seen[s] = true
	}
}

fn test_the_port_is_aria2s_neighbour_and_not_its_default() {
	// rpc/rpc.v's default_port is aria2's 6800. Using it would collide with the
	// user's own aria2, and the symptom of that collision is a first tick that
	// talks to the wrong daemon and calls it "not ready".
	assert default_rpc_port != 6800, '6800 is aria2s own default'
	assert default_rpc_port == 16800
	assert default_rpc_host == '127.0.0.1', 'a hostname can resolve to ::1 while aria2 binds 127.0.0.1'
}

fn test_the_child_never_inherits_the_users_aria2_conf() {
	// A user with their own aria2 almost certainly has
	// %USERPROFILE%\.aria2\aria2.conf, and it may set --rpc-listen-port or
	// --rpc-secret. Inheriting it means supervising somebody else's config.
	a := args(fixture())
	assert has_flag(a, '--no-conf=true'), 'got ${a}'
	assert a[0] == '--no-conf=true', 'hermeticity is the first thing on the line'
}

fn test_the_session_file_is_both_input_and_output() {
	// The round trip aria2s manual documents. Asymmetric values would mean a
	// queue that is read from one place and written to another.
	c := fixture()
	a := args(c)
	assert must_value(a, '--input-file') == c.session_file
	assert must_value(a, '--save-session') == c.session_file
	assert must_value(a, '--save-session-interval') == '60', 'without an interval the file is written only on a clean exit, which is exactly the case a crash is not'
}

fn test_the_standard_layout_is_under_the_project_root() {
	// fetch-aria2.ps1 populates runtime/ and .gitignore excludes it, so keeping
	// the engine state there means deleting the directory is a full uninstall.
	c := conf_for('C:\\fluxget', 'C:\\fluxget\\runtime\\aria2c.exe', 16800, 'x')
	assert c.session_file == 'C:\\fluxget\\runtime\\aria2.session'
	assert c.log_file == 'C:\\fluxget\\runtime\\aria2.log'
	assert c.dir == 'C:\\fluxget\\downloads'
}

fn test_the_order_of_the_arguments_is_stable() {
	// Positional, on purpose: a diff in a bug report is worth more than the
	// comparisons a sort would save, and an unstable order would make every
	// future diff of this line unreadable.
	c := fixture()
	a := args(c)
	// 14, not 16: the two speed caps are absent at 0, which is the point of the
	// next-to-last test. Pinning the count as well as the order means a flag
	// cannot be added without this file noticing.
	assert a.len == 14, 'got ${a.len}: ${a}'
	assert a[0] == '--no-conf=true'
	assert a[1] == '--enable-rpc'
	assert a[2] == '--rpc-listen-all=false'
	assert a[3] == '--rpc-listen-port=16800'
	assert a[4] == '--rpc-secret=s3cret'
	assert a[5] == '--dir=C:\\fluxget\\downloads'
	assert a[6] == '--input-file=C:\\fluxget\\runtime\\aria2.session'
	assert a[7] == '--save-session=C:\\fluxget\\runtime\\aria2.session'
	assert a[8] == '--save-session-interval=60'
	assert a[9] == '--continue=true'
	assert a[10] == '--max-concurrent-downloads=5'
	assert a[11] == '--log=C:\\fluxget\\runtime\\aria2.log'
	assert a[12] == '--log-level=notice'
	assert a[13] == '--console-log-level=warn'
	// Two calls with the same input must be the same line, byte for byte.
	assert args(fixture()) == a
}

fn test_speed_limits_are_omitted_when_unset_and_present_when_set() {
	// The three Limit layers in CONTEXT.md. Zero means "no cap" and is expressed
	// by leaving the flag out, not by passing a magic value aria2 would have to
	// be trusted to interpret.
	plain := args(fixture())
	assert value_of(plain, '--max-overall-download-limit') == none
	assert value_of(plain, '--max-overall-upload-limit') == none

	mut capped := fixture()
	capped.download_limit = 1048576
	capped.upload_limit = 262144
	full := args(capped)
	assert must_value(full, '--max-overall-download-limit') == '1048576'
	assert must_value(full, '--max-overall-upload-limit') == '262144'
}

fn test_the_console_level_is_quiet_enough_to_render() {
	// aria2 logs every chunk at info level. The Logs tab would scroll a firehose
	// faster than the UI could draw it, and it is all noise at that granularity.
	mut c := fixture()
	assert must_value(args(c), '--console-log-level') == 'warn'
	c.console_level = 'error'
	assert must_value(args(c), '--console-log-level') == 'error'
}

fn test_an_empty_path_omits_the_flag_instead_of_passing_nothing() {
	// '--dir=' is not "use the default", it is an empty relative path: the cwd.
	// A degraded mode has to be spelled as an absent flag.
	mut c := fixture()
	c.dir = ''
	c.session_file = ''
	c.log_file = ''
	a := args(c)
	assert value_of(a, '--dir') == none
	assert value_of(a, '--input-file') == none
	assert value_of(a, '--save-session') == none
	assert value_of(a, '--save-session-interval') == none
	assert value_of(a, '--log') == none
	// The security flags are never conditional, even in the degraded mode.
	assert has_flag(a, '--enable-rpc')
	assert has_flag(a, '--rpc-listen-all=false')
}

fn test_there_is_no_daemon_flag() {
	// aria2c -d detaches and forks. We would hold a handle to a parent that has
	// already exited, with no stderr pipe and no way to wait for readiness. If
	// this test ever fails because somebody added --daemon, that is a bug.
	for a in args(fixture()) {
		assert !a.starts_with('--daemon'), 'aria2c must stay a foreground child: ${a}'
	}
}
