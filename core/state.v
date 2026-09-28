// state.v - the shared state, and the one lock in the app.
//
// What lives here is deliberately small: the engine, the supervisor, the notice
// queue, and the last-seen map the diffing needs. The rule from ADR-0001 is
// that this module is ordinary V with zero knowledge of vails, and the rule from
// ADR-0010 is that nothing in it may ever push to the frontend. Both hold: the
// only way a Notice leaves this file is `drain`, called by the tick.
//
// ---- on the lock --------------------------------------------------------
//
// core.State owns a mutex, and here is the honest account of what it is for
// today, because a lock that is not needed yet is a lock nobody reasons about
// when it starts being needed.
//
// In Phase 1 there is exactly ONE thread: the webview main thread runs the
// handlers, and nothing else exists (aria2ctl deliberately has no reader
// thread - see its header). So the mutex is UNCONTENDED. Every acquire
// succeeds immediately and no State access can race.
//
// It is here anyway, for two reasons, and both are about Phase 6 rather than
// about now:
//
//   * api/'s Control API listener will be a spawned thread, and it will read this
//     same state. The moment it exists, the lock is load-bearing, and adding one
//     to a struct that is already shared through &State is a much smaller change
//     than retrofitting it.
//   * The invariant "every State accessor takes the lock" is only enforceable
//     while there is a single obvious place. Stating it now, in the file, means
//     the audit at Phase 6 is a grep for `s.` outside a locked method rather
//     than a reading exercise.
//
// The one caveat worth knowing: a panic between lock and unlock deadlocks the
// process. That is acceptable here precisely because a panic in a handler
// already takes the window down, and a frozen window is a smaller problem than
// a corrupted queue.
module core

import aria2ctl
import engine
import os
import rpc
import sync
import time

// Config is the app's runtime configuration.
//
// In memory only, and that is a Phase 1 decision with a reason: the one setting
// that must never be written to disk is the RPC secret (aria2ctl/conf.v), and
// building a settings file around it now would mean a store/ that mostly exists
// to hold one number that must be ephemeral. store/ lands in Phase 3 with
// history and presets, which are worth persisting.
pub struct Config {
pub mut:
	// root is the project root: where vails.json, runtime/ and downloads/ live.
	root string
	// port is the RPC port. Overridable so a second instance, or a port clash
	// with a user's own aria2, has an escape hatch.
	port int = aria2ctl.default_rpc_port
	// aria2_path is the user's hand-picked binary. Empty means "search".
	aria2_path string
	// download_dir overrides the default <root>/downloads.
	download_dir string
	// probe_url seeds one download at startup when set. See the note on
	// State.seed_probe.
	probe_url string
}

// now_ms is a unix millisecond stamp, shared by everything that needs one so
// the values in a single tick are comparable.
pub fn now_ms() i64 {
	return time.now().unix_milli()
}

// State is the shared state.
pub struct State {
pub mut:
	// guard is the lock. See the header for why it exists while it is still
	// uncontended.
	guard &sync.Mutex
	// conf is the configuration, kept so health and the Setup page can report it.
	conf Config
	// client is the engine's RPC client. One value, copied into the Engine and
	// the Supervisor; the copies differ only in their request-id counter and
	// timeout, which rpc.Client's own comment calls cosmetic.
	client rpc.Client
	// eng is the app-facing facade.
	eng engine.Engine
	// sup is the daemon supervisor. none until the window is ready, because the
	// engine starts in on_ready and not before (see platform/app.v).
	sup ?&aria2ctl.Supervisor
	// notices is the queue drained into the next tick.
	notices NoticeQueue
	// seen is the previous tick's view, for diffing. Opaque here: the Notice
	// contract is between this map and core.diff, and nothing else may read it.
	seen map[string]Seen
	// started_ms is when the app booted, for the uptime in the tick payload.
	started_ms i64
	// ticks counts completed polls. Cheap, and it makes "the window is alive and
	// polling" a fact rather than an inference from a moving progress bar.
	ticks int
	// aria2_path and aria2_source record which binary the search rules chose, at
	// the moment the engine started. Remembered rather than re-derived per tick:
	// re-running the search would stat every PATH entry on every frame, and the
	// answer cannot have changed without a restart.
	aria2_path   string
	aria2_source string
	// probe_pending is set when a probe download still has to be handed to the
	// engine. See seed_probe.
	probe_pending bool
}

// new_state builds the state. It creates no directories, starts no process and
// opens no socket: a handler can build one and interrogate it, which is what
// makes the health command's "not started yet" answer honest.
pub fn new_state(conf Config) &State {
	secret := aria2ctl.new_secret()
	mut c := rpc.new(conf_port_host(conf), conf.port, secret)
	// The engine's own calls get the full timeout. Readiness wants a short one,
	// and sharing a single value would compromise both - so the Supervisor takes
	// a copy and lowers it.
	c = c.with_http()
	// `guard: unsafe { nil }` is not a way out of this: V requires a reference
	// field to be initialised at construction, which is the point. The mutex is
	// created here and nowhere else, so there is no way to get a State with no
	// lock.
	mut s := &State{
		conf:       conf
		client:     c
		eng:        engine.new(c)
		seen:       map[string]Seen{}
		guard:      sync.new_mutex()
		started_ms: now_ms()
	}
	s.probe_pending = conf.probe_url != ''
	return s
}

// conf_port_host is the loopback host the client dials.
//
// Always aria2ctl's constant rather than something from Config, and the reason
// is the one in rpc/http.v: a hostname can resolve to ::1 while aria2 binds
// 127.0.0.1, so the client would be talking to a socket nothing is listening
// on. A remote endpoint is refused at the setup screen, not dialled.
fn conf_port_host(_ Config) string {
	return aria2ctl.default_rpc_host
}

// ---- the lock ------------------------------------------------------------

// lock and unlock are the only sanctioned way in. Every accessor in this file
// takes the lock, and the App's handlers hold it for the duration of one
// operation, so a handler is a transaction rather than a sequence of steps a
// reader could observe half-finished.
pub fn (mut s State) lock() {
	s.guard.lock()
}

pub fn (mut s State) unlock() {
	s.guard.unlock()
}

// ---- engine lifecycle ----------------------------------------------------

// start_engine locates aria2c, builds the spawn line and starts the daemon.
//
// The first three steps are the ones that can fail before anything is spawned,
// and each one produces a phase the Setup page can render rather than an
// exception: a missing binary is a `missing` phase with the list of places we
// looked, which is exactly the information a user needs to fix it.
//
// Re-entrant: calling it when the engine is already up is a no-op, so a tick
// that decides to restart does not have to ask first.
pub fn (mut s State) start_engine() ! {
	if s.sup != none {
		mut p := s.sup or { return }
		if p.phase == .ready || p.phase == .starting {
			return
		}
	}
	loc := aria2ctl.locate(aria2ctl.search_from_env(exe_dir(), s.conf.root,
		s.conf.aria2_path))
	if !loc.found {
		s.sup = none
		s.aria2_path = ''
		s.aria2_source = ''
		s.notices.push(Notice{
			kind: notice_info
			text: loc.hint
		})
		return error('core: aria2c not found: ${loc.hint}')
	}
	s.aria2_path = loc.path
	s.aria2_source = loc.source
	mut c := aria2ctl.conf_for(s.conf.root, loc.path, s.conf.port, s.client.secret)
	if s.conf.download_dir != '' {
		c.dir = s.conf.download_dir
	}
	// The readiness client is a copy with a short timeout, so a daemon that
	// never binds costs a bounded wait instead of a frozen window. The engine
	// keeps the long one.
	mut probe := s.client
	sup := aria2ctl.new_supervisor(c, probe)
	s.sup = sup
	sup.start() or {
		// start() already recorded why. The error propagates so the caller can
		// log it, but the state is consistent either way: a failed spawn leaves
		// phase=crashed, not a half-started supervisor.
		return err
	}
	if loc.source != aria2ctl.source_runtime && loc.source != aria2ctl.source_beside {
		s.notices.push(Notice{
			kind: notice_info
			text: 'aria2c found on PATH (' + loc.source + '); run .\\scripts\\fetch-aria2.ps1 for the bundled build'
		})
	}
}

// stop_engine shuts the daemon down cleanly. Safe to call when nothing is
// running, because main.v calls it unconditionally after the window closes.
pub fn (mut s State) stop_engine() {
	mut sup := s.sup or { return }
	sup.stop()
}

// ---- the tick ------------------------------------------------------------

// TickResult is one poll's outcome: what the engine said, plus whatever events
// happened since the last poll.
//
// A struct rather than a tuple because the caller is a JSON builder and named
// fields are the only way to keep the two in step.
pub struct TickResult {
pub mut:
	// ok is false when aria2 could not be reached this tick. The notices and the
	// logs are still returned: a disconnected engine is exactly when the Logs
	// tab matters most.
	ok bool
	// snap is the decoded snapshot. Its zero value is meaningful when ok is
	// false, and the UI must not read counts out of it as if they were real.
	snap rpc.Snapshot
	// notices are the events since the last tick, already drained.
	notices []Notice
	// detail is why the poll failed, for health and the Logs tab.
	detail string
}

// poll is one Tick (CONTEXT.md): drain the log pipe, notice a crash, ask aria2
// for the world, and diff it.
//
// The order is the design:
//
//  1. pump the stderr pipe, so anything aria2 just said about dying is in the
//     ring before we decide it died
//  2. reap a crash and, if the policy allows, restart - BEFORE asking for a
//     snapshot, so one crash costs one dead tick rather than two
//  3. drain the notice queue into the result
//  4. the multicall
//  5. diff, so the next tick has a baseline
//
// All of it is expected to be fast. The one call that can be slow is the
// multicall, and rpc.Client's timeout bounds it.
pub fn (mut s State) poll() TickResult {
	mut res := TickResult{}
	mut sup := s.sup or {
		res.detail = 'the engine has not been started'
		res.notices = s.notices.drain()
		return res
	}
	sup.pump()
	if sup.restart_due() {
		sup.take_pending()
		sup.start() or { res.detail = err.msg() }
	} else if sup.reap() {
		if sup.schedule_restart() {
			s.notices.push(Notice{
				kind: notice_info
				text: sup.pending_reason()
			})
		} else {
			s.notices.push(Notice{
				kind: notice_info
				text: sup.last_error
			})
		}
	}
	// The queue is drained whatever happened. A notice that survived a failed
	// poll would be re-sent on every tick until it succeeded, which is how a
	// single "engine crashed" becomes a per-second toast.
	res.notices = s.notices.drain()
	s.ticks++

	snap := s.eng.snapshot() or {
		res.detail = err.msg()
		return res
	}
	res.ok = true
	res.snap = snap
	// snapshot.all() is a fresh slice each call, so this copy is a second
	// allocation. Kept explicit rather than calling all() twice because diff()
	// takes one slice and the alternative is two different lengths depending on
	// which call you looked at.
	//
	// The loop variable is `it`, not `s`: this function's receiver is also `s`,
	// and V rejects a redefinition of an iteration variable in the same scope
	// ("redefinition of value iteration variable `s`").
	all := snap.all()
	mut fresh := []rpc.Status{len: all.len, init: rpc.Status{}}
	for i, it in all {
		fresh[i] = it
	}
	ns, next := diff(s.seen, fresh, now_ms())
	s.seen = next
	s.notices.extend(ns)
	// The notices produced by THIS diff belong to the NEXT tick, not this one.
	//
	// Not an accident and not laziness: the frontend is about to render this
	// snapshot, and a "Finished x" that arrives in the same payload as the row
	// for x is a toast the user cannot read yet. One beat of latency is the
	// price of the notice arriving after the thing it is about.
	res.notices << s.notices.drain()
	return res
}

// seed_probe hands the configured probe URL to the engine exactly once.
//
// This exists for the e2e proof in tests/e2e_windows: an unattended run has
// nobody to paste a URL into, and a screenshot of an empty queue proves
// nothing. It is opt-in (an env var read in main.v), it fires at most once per
// app run, and it is a normal add through the normal engine path - there is no
// privileged back door into aria2 for it.
pub fn (mut s State) seed_probe() {
	if !s.probe_pending {
		return
	}
	if s.conf.probe_url == '' {
		s.probe_pending = false
		return
	}
	s.probe_pending = false
	s.eng.add(engine.AddRequest{
		uris: [s.conf.probe_url]
	}) or {
		s.notices.push(Notice{
			kind: notice_info
			text: 'probe: ' + err.msg()
		})
		return
	}
	s.notices.push(Notice{
		kind: notice_added
		text: 'probe: added ' + s.conf.probe_url
	})
}

// exe_dir is the directory holding this binary, which is rule 1 of the aria2c
// search order: a portable install ships aria2c next to fluxget.exe.
fn exe_dir() string {
	return os.dir(os.executable())
}
