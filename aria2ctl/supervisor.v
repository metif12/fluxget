// supervisor.v - starting, watching and stopping the aria2c process.
//
// The shape of this file is the interesting part, and it follows from two rules
// that pull in opposite directions:
//
//   * `v test` must stay pure (AGENTS.md section 4). No test may spawn a
//     process, so everything that decides anything is a pure function over a
//     value, and this file is the thin shell that acts on those decisions.
//   * A command handler runs on the webview main thread (vails ADR-0010), so a
//     handler may not sleep, may not block, and may never emit. The engine's
//     whole life cycle therefore has to be expressible as "check, decide, act
//     on the next tick".
//
// So: the RESTART POLICY below is pure and tested; `start`, `stop` and `pump`
// are not tested at all, and that is deliberate rather than a gap. A test for
// `start` would have to start aria2c, which is exactly what the test suite is
// forbidden to do. The logic those three functions contain is deliberately thin
// enough to read.
//
// Two consequences worth stating, because both look like omissions:
//
//   * There is no log-reading thread. stderr is drained by `pump`, which
//     `pipe_read` makes non-blocking (PeekNamedPipe on Windows), and pump is
//     called from the tick. A reader thread would own shared state, need the
//     core mutex, and still could not emit - it would add a lock and a race to
//     solve a problem the polling model does not have. It becomes worth it the
//     day the Control API's listener needs log lines between ticks.
//
//   * A restart is scheduled, never slept through. `schedule_restart` records
//     when the next attempt is due; the tick performs it. A handler that called
//     time.sleep(4000) would freeze the window for four seconds, which is the
//     single most visible thing a desktop app can do wrong.
module aria2ctl

import os
import rpc
import time

// Phase is where the daemon is in its life.
//
// These words cross the bridge in the health and tick payloads, so they are
// pinned by supervisor_test.v: a rename is a wire change, and the frontend picks
// its Setup screen by matching on them.
pub enum Phase {
	// never_started is the state before the window opens. It is not `stopped`,
	// because "we have not tried yet" and "we tried and it is not running" are
	// different things to show a user.
	never_started
	// starting means the process was spawned and readiness has not been proven.
	starting
	// ready means aria2 answered aria2.getVersion. The ONLY definition of ready.
	ready
	// crashed means the process exited without being asked to.
	crashed
	// missing means no aria2c binary was found. Never restarts: see decide().
	missing
	// stopping means a clean shutdown is in progress.
	stopping
	// stopped means it is not running and we are not trying.
	stopped
}

// label is the wire word for a phase. Kept as a function rather than relying on
// a derived enum string, because the derived name is a compiler detail and this
// is a published vocabulary.
pub fn (p Phase) label() string {
	return match p {
		.never_started { 'never-started' }
		.starting { 'starting' }
		.ready { 'ready' }
		.crashed { 'crashed' }
		.missing { 'missing' }
		.stopping { 'stopping' }
		.stopped { 'stopped' }
	}
}

// ---- restart policy (pure) -----------------------------------------------

// The budget, as chosen and documented rather than guessed at.
//
//   3 restarts in 60 seconds, backing off 1s, 2s, 4s.
//
// Why 3: two restarts covers a single transient (an antivirus scan holding the
// exe, a port released a moment late), three covers a genuine bad day. Why stop
// there: a crash loop that runs forever is indistinguishable from a working app
// as far as the window is concerned - the UI would show a spinner and the queue
// would silently never advance. Stopping after three turns that into a visible,
// explicable failure ("the engine keeps crashing", with the log above it) which
// is the only outcome a user can act on.
//
// Why stop at 4s: long enough that a repeated failure is not hammering the disk
// or the port, short enough that the third retry still happens inside the
// session a user is watching.
pub const max_restarts = 3
pub const restart_window_ms = 60000
pub const backoff_base_ms = 1000
pub const backoff_cap_ms = 4000

// Exit is one recorded daemon exit.
pub struct Exit {
pub:
	// at_ms is a unix millisecond stamp.
	at_ms i64
	// code is the process exit code, or -1 when it was killed.
	code int
}

// Decision is the pure answer to "should we start it again, and how soon".
pub struct Decision {
pub:
	restart bool
	wait_ms int
	// reason is a sentence, because the only reader is the Logs tab and a user
	// deciding whether to file a bug.
	reason string
}

// Budget is the restart state. A value, not a field on the Supervisor, so the
// policy can be driven from a table in a test.
pub struct Budget {
pub mut:
	// exits holds the recent exits, oldest first. Pruned to the window on every
	// record, so its length is the crash count in the window.
	exits []Exit
	// max is how many are allowed in the window.
	max int = max_restarts
	// window_ms is how far back an exit still counts.
	window_ms int = restart_window_ms
	// stopping means the app asked for the shutdown. Set before the shutdown
	// RPC, because the exit that follows is the point of the exercise and must
	// not be counted as a crash.
	stopping bool
}

// record notes an exit, forgetting any that have aged out of the window.
//
// The prune is not an optimisation. Without it a daemon that crashed once an
// hour would be "crashed three times in an hour" by the fourth hour, and the
// budget would never refill - the app would refuse to restart an engine that
// has been fine for days.
pub fn (mut b Budget) record(at_ms i64, code int) {
	b.prune(at_ms)
	b.exits << Exit{
		at_ms: at_ms
		code:  code
	}
}

// prune drops exits older than the window.
pub fn (mut b Budget) prune(now_ms i64) {
	mut kept := []Exit{cap: b.exits.len}
	for e in b.exits {
		if now_ms - e.at_ms <= b.window_ms {
			kept << e
		}
	}
	b.exits = kept
}

// crash_count is how many exits are still inside the window.
pub fn (b Budget) crash_count() int {
	return b.exits.len
}

// decide is the whole policy, and the only place it is written down.
//
// The counting is worth stating once, because an off-by-one here is invisible:
//
//   b.max is a budget of RESTARTS, not of crashes. After the first crash we
//   perform restart 1 of 3; after the fourth crash there is nothing left to
//   spend, so the guard is `n > b.max`. With `n >= b.max` the third crash would
//   silently buy only two restarts and the documented budget would be a lie.
pub fn (b Budget) decide(now_ms i64) Decision {
	// A clean shutdown is not a crash. This check is first because it is the
	// case that must never be wrong: a budget that counted our own shutdown
	// would leave the app unable to start its engine again after a restart.
	if b.stopping {
		return Decision{
			reason: 'the app asked the engine to stop'
		}
	}
	// Prune into a copy rather than mutating: decide is a query, and a handler
	// that only wanted to know whether a restart was owed must not change the
	// state it is asking about.
	mut live := Budget{
		max:       b.max
		window_ms: b.window_ms
	}
	live.exits = b.exits
	live.prune(now_ms)
	n := live.exits.len
	// No crash means nothing to recover from. A supervisor that has never run is
	// in this state, and answering "restart" would spawn a daemon nobody asked
	// for.
	if n == 0 {
		return Decision{
			reason: 'no crash to recover from'
		}
	}
	if n > b.max {
		return Decision{
			restart: false
			reason:  'the engine has crashed ' + n.str() + ' times in ' +
				(b.window_ms / 1000).str() + 's; the restart budget of ' +
				b.max.str() + ' is spent, so it will not be restarted again'
		}
	}
	// n-1, not n: we are about to perform restart number n, and restart 1 is the
	// fastest one.
	wait := backoff_ms(n - 1)
	return Decision{
		restart: true
		wait_ms: wait
		reason:  'restart ' + n.str() + ' of ' + b.max.str() +
			': the engine crashed, retrying in ' + wait.str() + 'ms'
	}
}

// backoff_ms is attempt N's delay: 1000, 2000, 4000, then capped.
//
// N is the number of crashes ALREADY recorded, so the first restart is the
// fastest - a crash we did not predict should be recovered from as quickly as
// the port allows, not after a delay.
pub fn backoff_ms(attempt int) int {
	if attempt <= 0 {
		return backoff_base_ms
	}
	mut ms := backoff_base_ms
	for _ in 0 .. attempt {
		if ms * 2 >= backoff_cap_ms {
			return backoff_cap_ms
		}
		ms = ms * 2
	}
	return ms
}

// ---- the process (not tested, on purpose) --------------------------------

// Pending is a scheduled restart.
pub struct Pending {
pub:
	at_ms   i64
	wait_ms int
	reason  string
}

// Supervisor owns the child process and the log ring.
pub struct Supervisor {
pub mut:
	// conf is the spawn contract, kept so a restart reuses the same line.
	conf Conf
	// ring is the Logs tab's buffer. Not optional and never nil: a supervisor
	// with no log is the failure mode that makes an engine failure unexplainable.
	ring &Ring
	// phase is the current state.
	phase Phase = .never_started
	// budget is the restart policy's state.
	budget Budget
	// proc is the live child. none before start() and after stop().
	proc ?&os.Process
	// client is a COPY of the app's rpc.Client, used only for readiness and
	// shutdown.
	//
	// A copy is deliberate, for one reason: readiness wants a short timeout
	// (a probe that hangs is a frozen window) while the engine's own calls want
	// the full one. Sharing one value would mean compromising both. Two copies
	// means two JSON-RPC id counters, which is harmless - rpc.Client's own
	// comment says nothing correlates a response to a request but the id coming
	// back unchanged.
	client rpc.Client
	// pid is the child's process id, 0 when not running.
	pid int
	// started_ms is when the current process was spawned.
	started_ms i64
	// last_error is the most recent failure, for health and the Logs tab.
	last_error string
	// ready_timeout_ms bounds the readiness wait inside start(). See there.
	ready_timeout_ms int = 1500
	// pending is a scheduled restart, none when nothing is owed.
	pending ?Pending
	// restarts is how many times this supervisor has (re)started the daemon
	// after the first. Reported in health so a crash loop is visible even in the
	// window where it is still within budget.
	restarts int
}

// new_supervisor allocates a supervisor. It starts nothing and touches nothing:
// the whole point is that a handler can build one and ask it questions before
// deciding whether the engine should exist.
pub fn new_supervisor(conf Conf, client rpc.Client) &Supervisor {
	mut s := &Supervisor{
		conf: conf
		ring: new_ring(default_capacity)
	}
	s.client = client
	// Readiness must not be able to freeze the window. A wedged daemon answers
	// nothing, the loop below gives up, and the tick keeps reporting `starting`
	// with an explanation instead of the window hanging.
	s.client.timeout_ms = 800
	return s
}

// now_ms is a unix millisecond stamp. One function so the policy's inputs and
// the supervisor's inputs are the same clock.
pub fn now_ms() i64 {
	return time.now().unix_milli()
}

// prepare creates the directories and the session file the spawn line names.
//
// This exists as its own function, and it exists at all, because of one line in
// aria2's manual: --input-file must name a file that EXISTS. Given a path that
// does not, aria2 fails to start at all - it is not a warning. Without this,
// the very first run of the app would spawn a daemon, watch it die, and blame
// the port.
//
// The file is created empty, which is the documented workaround: aria2 accepts an
// empty input file and starts with an empty queue.
pub fn (mut s Supervisor) prepare() ! {
	if s.conf.dir != '' {
		os.mkdir_all(s.conf.dir)!
	}
	if s.conf.log_file != '' {
		os.mkdir_all(os.dir(s.conf.log_file))!
	}
	if s.conf.session_file != '' {
		os.mkdir_all(os.dir(s.conf.session_file))!
		if !os.exists(s.conf.session_file) {
			os.write_file(s.conf.session_file, '')!
		}
	}
}

// start spawns the daemon and waits, briefly, for it to answer.
//
// The readiness wait is bounded at ready_timeout_ms (1.5s) and a timeout is NOT
// fatal. The alternative - block until the engine is up - would hold the
// webview's main thread, because start() is reached from on_ready, and a
// 30-second wait for a port that is never going to answer is a 30-second
// application that looks hung. A bounded wait followed by a tick that keeps
// probing degrades instead: the window is usable and says `starting`.
pub fn (mut s Supervisor) start() ! {
	s.prepare()!
	mut p := os.new_process(s.conf.binary)
	p.set_args(args(s.conf))
	// The working folder is aria2c's own directory, not ours. Windows resolves a
	// sibling DLL from the executable's directory before the working folder, so
	// this is what makes a build that ships its own libs work regardless of
	// where Fluxget was launched from.
	p.set_work_folder(os.dir(s.conf.binary))
	// aria2c is a console program. Without this a black console window flashes
	// on every spawn, which for a background daemon is the most visible possible
	// bug.
	p.create_no_window = true
	// Must precede run(): the pipe has to exist when the child starts, and
	// Process._check_redirection_call panics if a stdio method is called first.
	p.set_redirect_stdio()
	p.run()
	if p.status == .exited || p.err != '' {
		s.phase = .crashed
		detail := if p.err == '' {
			'no message; the spawn line is in the Logs tab'
		} else {
			p.err
		}
		s.last_error = 'aria2c exited immediately (code ${p.code}): ' + detail
		return error('aria2ctl: aria2c exited immediately (code ${p.code})')
	}
	s.proc = p
	s.pid = p.pid
	s.started_ms = now_ms()
	s.phase = .starting
	s.ring.clear()
	s.pending = none

	s.client.wait_ready(s.ready_timeout_ms, 150) or {
		s.last_error = 'aria2c started (pid ${p.pid}) but did not answer on port ' +
			s.conf.port.str() + ' within ' + s.ready_timeout_ms.str() +
			'ms; it may still be binding, or the port may be taken'
		return
	}
	s.phase = .ready
	s.last_error = ''
}

// pump drains whatever aria2 has written to stderr into the ring. Returns the
// number of lines added, which the tick uses to decide whether the Logs tab
// needs repainting.
//
// Non-blocking by construction: pipe_read returns none when the pipe is empty,
// so a tick never waits on a quiet engine. The 4096 check is the same read size
// V uses internally; anything shorter than a full buffer means the pipe is
// drained, and looping again would just ask a second time for nothing.
pub fn (mut s Supervisor) pump() int {
	mut p := s.proc or { return 0 }
	before := s.ring.count()
	for {
		chunk := p.pipe_read(.stderr) or { break }
		s.ring.feed(chunk)
		if chunk.len < 4096 {
			break
		}
	}
	return s.ring.count() - before
}

// is_alive reports whether the child is still running.
pub fn (mut s Supervisor) is_alive() bool {
	mut p := s.proc or { return false }
	return p.is_alive()
}

// reap notices an exit we did not ask for, and records it against the budget.
//
// Called from the tick, which is where a crash becomes visible: a process that
// died is a fact nobody is notified about, and a download manager that keeps
// showing a stale queue is worse than one that admits the engine is gone.
pub fn (mut s Supervisor) reap() bool {
	if s.phase in [.never_started, .stopped, .missing, .stopping] {
		return false
	}
	if s.is_alive() {
		return false
	}
	mut p := s.proc or { return false }
	s.budget.record(now_ms(), p.code)
	s.phase = .crashed
	s.proc = none
	s.pid = 0
	s.last_error = 'aria2c exited (code ${p.code})'
	return true
}

// schedule_restart applies the policy to the current state. Returns true when a
// retry is now owed.
//
// It only RECORDS the attempt. The tick performs it (see restart_due), because
// the policy's whole point is to avoid sleeping inside a handler.
pub fn (mut s Supervisor) schedule_restart() bool {
	d := s.budget.decide(now_ms())
	if !d.restart {
		s.pending = none
		s.last_error = d.reason
		return false
	}
	s.pending = Pending{
		at_ms:   now_ms() + i64(d.wait_ms)
		wait_ms: d.wait_ms
		reason:  d.reason
	}
	return true
}

// restart_due reports whether a scheduled attempt is now owed. The tick calls
// this before it decides whether the engine is alive.
pub fn (s Supervisor) restart_due() bool {
	if s.pending == none {
		return false
	}
	return now_ms() >= s.pending.at_ms
}

// take_pending consumes the scheduled attempt, so two ticks cannot both fire it.
pub fn (mut s Supervisor) take_pending() ?Pending {
	p := s.pending or { return none }
	s.pending = none
	return p
}

// pending_reason is the sentence for the scheduled attempt, for a Notice. Falls
// back to last_error when nothing is scheduled, so a caller can use it
// unconditionally after reap().
pub fn (s Supervisor) pending_reason() string {
	p := s.pending or { return s.last_error }
	return p.reason
}

// stop shuts the daemon down cleanly, then insists.
//
// The order is not negotiable. saveSession writes the queue to
// --save-session, shutdown makes aria2 exit on its own terms, and only if it
// has not exited within stop_wait_ms do we kill it. A kill loses the session
// file, which is the one thing a user notices about a download manager closing.
//
// stop_wait_ms is how long a polite shutdown is given before the process is
// killed. aria2 finishing a hash check on a torrent can take a moment, and
// cutting it off would throw that work away.
pub const stop_wait_ms = 2000

pub fn (mut s Supervisor) stop() {
	if s.phase == .never_started || s.phase == .stopped {
		return
	}
	// Set BEFORE the shutdown RPC: the exit that follows is the one we asked
	// for, and the budget must not see it as a crash.
	s.budget.stopping = true
	s.phase = .stopping

	mut p := s.proc or {
		s.phase = .stopped
		return
	}
	if s.phase == .ready || s.phase == .starting {
		s.client.save_session() or {
			s.last_error = 'could not save the session: ' + err.msg()
		}
		s.client.shutdown() or {
			s.last_error = 'clean shutdown refused: ' + err.msg()
		}
	}
	mut waited := 0
	for s.is_alive() && waited < stop_wait_ms {
		time.sleep(100 * time.millisecond)
		waited += 100
	}
	if s.is_alive() {
		p.signal_kill()
		// Give the kill a moment so the pipe reaches EOF and the last log lines
		// are actually readable. Flushing a fragment that was never written
		// would put a truncated line in the Logs tab.
		time.sleep(200 * time.millisecond)
	}
	// Drain whatever is left in the pipe, then rescue an unterminated tail.
	s.pump()
	s.ring.flush()
	s.proc = none
	s.pid = 0
	s.phase = .stopped
}
