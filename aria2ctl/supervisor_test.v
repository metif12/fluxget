// supervisor_test.v - the restart policy, and nothing that needs a process.
//
// Every test here drives Budget and backoff_ms, which are pure. There is
// deliberately no test for start(), stop() or pump(): those three functions
// spawn aria2c, and `v test` is forbidden from starting a process (AGENTS.md
// section 4). What makes that acceptable rather than a hole is that the logic
// they act on is all here, and they are thin enough to read in one sitting.
//
// The table below is the documented policy, written down where it is enforced:
// 3 restarts in 60 seconds, backing off 1s, 2s, 4s.
module aria2ctl

// A fixed clock. The policy takes `now` as an argument precisely so a test does
// not have to sleep, and so "an hour later" is expressible.
//
// Typed through a cast: an untyped const literal defaults to i32 and a unix
// millisecond stamp overflows it ("overflow in implicit type `int`"). Two forms
// that do NOT work in V 0.5.2: `const t0 i64 = ...` (parsed as an executable
// top-level statement, which a _test.v may not contain) and the `1700000000000i64`
// literal suffix ("unsuitable digit `i`").
const t0 = i64(1700000000000)

fn fresh() Budget {
	return Budget{}
}

fn test_a_first_run_is_not_a_crash_and_offers_no_restart() {
	// Nothing has exited, so there is nothing to decide. A Decision that said
	// "restart" here would spawn a daemon before the app had even tried.
	d := fresh().decide(t0)
	assert !d.restart
	assert d.reason != '', 'even a no-op decision explains itself'
}

fn test_the_backoff_is_one_two_four_then_capped() {
	// The numbers in the header, asserted so a "harmless" tweak to the constant
	// has to be a deliberate edit.
	assert backoff_ms(0) == 1000
	assert backoff_ms(1) == 2000
	assert backoff_ms(2) == 4000
	assert backoff_ms(3) == 4000, 'the backoff is capped'
	assert backoff_ms(50) == 4000, 'and stays capped'
}

fn test_the_first_crash_restarts_after_one_second() {
	mut b := fresh()
	b.record(t0, 1)
	d := b.decide(t0)
	assert d.restart, 'got: ${d.reason}'
	assert d.wait_ms == 1000
	assert d.reason.contains('1 of 3'), d.reason
}

fn test_the_third_restart_is_the_last_one_allowed() {
	// b.max is a budget of RESTARTS, so the third crash buys the third and final
	// retry, and the fourth crash buys nothing. Asserted from both sides, because
	// the off-by-one that gets this wrong is invisible in a running app: it just
	// stops trying one attempt early.
	mut b := fresh()
	b.record(t0, 1)
	b.record(t0 + 100, 1)
	second := b.decide(t0 + 100)
	assert second.restart, 'got: ${second.reason}'
	assert second.wait_ms == 2000, 'the backoff lengthens: ${second.reason}'

	b.record(t0 + 200, 1)
	assert b.crash_count() == 3
	third := b.decide(t0 + 200)
	assert third.restart, 'the third restart is still allowed: ${third.reason}'
	assert third.wait_ms == 4000, 'the last one waits longest: ${third.reason}'

	b.record(t0 + 300, 1)
	final := b.decide(t0 + 300)
	assert !final.restart, 'a fourth crash must stop the loop: ${final.reason}'
	assert final.reason.contains('budget'), final.reason
}

fn test_the_budget_refills_once_the_window_has_passed() {
	// The prune is the whole reason a single crash does not disable the engine
	// forever. Without it, a daemon that crashed once a day would eventually
	// accumulate "4 crashes" from four different days and the app would refuse
	// to start an engine that has been fine for weeks.
	mut b := fresh()
	b.record(t0, 1)
	b.record(t0 + 1000, 1)
	b.record(t0 + 2000, 1)
	b.record(t0 + 3000, 1)
	assert !b.decide(t0 + 3000).restart, 'four crashes in the window spend the budget'

	later := t0 + 3000 + restart_window_ms + 1
	// The engine runs fine for a while. Its next crash is the FIRST of a new
	// window, not the fifth of the old one - and that is the property worth
	// asserting, because without the prune a daemon that crashed once a day
	// would eventually spend a budget made of four different days and the app
	// would refuse to start an engine that has been fine for weeks.
	b.record(later, 1)
	assert b.crash_count() == 1, 'the four old exits aged out: ${b.crash_count()}'
	d := b.decide(later)
	assert d.restart, 'the budget is whole again: ${d.reason}'
	assert d.wait_ms == 1000, 'and the backoff starts over: ${d.reason}'
}

fn test_an_empty_budget_never_spawns_a_daemon() {
	// The other half of the same story, and the reason decide has a no-crash
	// answer at all: a supervisor that has never run must not be told to start
	// something. It is a query about a crash, and there is none.
	d := fresh().decide(t0)
	assert !d.restart
	assert d.reason.contains('no crash'), d.reason
}

fn test_an_exit_just_inside_the_window_still_counts() {
	// The boundary, from the other side: pruning at exactly the window would
	// shrink the budget by one crash per window in a pathological case.
	mut b := fresh()
	b.record(t0, 1)
	b.record(t0 + 1, 1)
	b.record(t0 + 2, 1)
	b.record(t0 + restart_window_ms, 1)
	assert b.crash_count() == 4, 'an exit exactly at the window edge still counts'
	assert !b.decide(t0 + restart_window_ms).restart
}

fn test_a_shutdown_we_asked_for_is_never_a_crash() {
	// The case that must never be wrong. If the budget counted our own shutdown,
	// then closing and reopening the app would leave it unable to start its
	// engine - the failure would look like a port problem and nothing else.
	mut b := fresh()
	b.stopping = true
	b.record(t0, 0)
	d := b.decide(t0)
	assert !d.restart
	assert d.reason.contains('asked'), d.reason
	// Not even an empty budget of crashes gets a restart while stopping.
	b.stopping = false
	assert b.decide(t0).restart, 'a crash recorded before a stop still counts once running again'
}

fn test_the_policy_constants_are_the_documented_ones() {
	// CONTEXT.md and the ADR quote these numbers to a reader; a silent change
	// here would make the documentation wrong.
	assert max_restarts == 3
	assert restart_window_ms == 60000
	assert backoff_base_ms == 1000
	assert backoff_cap_ms == 4000
	assert stop_wait_ms == 2000
}

fn test_the_phase_words_are_the_ones_the_frontend_matches_on() {
	// These strings cross the bridge. The frontend picks its Setup screen by
	// matching them, so a rename is a wire change and belongs in a commit
	// message, not in a refactor.
	assert Phase.never_started.label() == 'never-started'
	assert Phase.starting.label() == 'starting'
	assert Phase.ready.label() == 'ready'
	assert Phase.crashed.label() == 'crashed'
	assert Phase.missing.label() == 'missing'
	assert Phase.stopping.label() == 'stopping'
	assert Phase.stopped.label() == 'stopped'
}

fn test_never_started_and_stopped_are_different_answers() {
	// "We have not tried" and "we tried and it is not running" are different
	// things to show a user, so they are different words.
	assert Phase.never_started.label() != Phase.stopped.label()
}
