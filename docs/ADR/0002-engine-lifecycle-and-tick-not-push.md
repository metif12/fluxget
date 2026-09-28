# ADR-0002 — the engine is a supervised child, and nothing is ever pushed

- Status: accepted
- Date: 2026-09-28
- Applies to: `aria2ctl/`, `core/`, `platform/app.v`, the frontend's tick loop

## Context

Phase 0 proved the bridge. Phase 1 has to put a real download on screen, and
three decisions had to be made before any of that code could be written. All
three are expensive to reverse, and all three are forced by something outside
our control.

**1. The engine is a child process, and we own its whole life cycle.**

aria2 has three deployment shapes and only one of them is ours to supervise: a
daemon the user started, a system service, and a child process. The first two
are not Fluxget's to control. A system service cannot be given a per-app RPC
secret, restarted on our schedule, or shut down when our window closes; and a
user's own aria2 already holds port 6800, so pointing at it means our client
either authenticates against somebody else's token or talks to nothing. So
Fluxget spawns its own aria2c, finds it first, and stops it last. The RPC secret
becomes *ours*, which is what makes "the extension never sees the engine's
credential" (CONTEXT.md, Control API) a property rather than a hope.

**2. The framework forbids pushing, and the engine offers no way to push.**

vails ADR-0010 requires V→JS eval to happen on the webview main thread, and a
handler *is* that thread. aria2's completion hooks (`onDownloadComplete` and
friends) are not callbacks — they are a shell-out to a program named in a
config file. So there is no push available even if the framework allowed it.
Polling is not a compromise here; it is the only shape that exists.

**3. A successful spawn proves nothing.**

`os.Process.run()` returning means the process started. aria2 then has to bind
its RPC port, and a failed bind is a second, different failure that arrives
later and looks like a port problem. So readiness is defined as exactly one
thing — aria2 answered `aria2.getVersion` — and nothing else counts as ready.

## Decision

**1. Readiness is a phase, and only the tick can advance it.**

`aria2ctl.Phase` is the state machine: `never-started`, `starting`, `ready`,
`crashed`, `missing`, `stopping`, `stopped`. `never-started` and `stopped` are
separate values on purpose — "we have not tried" and "we tried and it is not
running" are different things to show a user, and collapsing them makes the Setup
screen lie to someone whose aria2c is installed but not running.

`start()` waits for readiness, but **bounded**, and a timeout is not fatal. The
wait is 1.5s. The alternative — block until the engine answers — would hold the
window frozen, because `start()` is reached from `on_ready` on the main thread,
and a daemon that is never going to bind would be a window that never responds. A
bounded wait followed by a tick that keeps probing degrades instead: the window is
usable and honestly says `starting`.

**2. The engine starts in `on_ready`, not before `boot`.**

This is the placement that makes the Setup page possible. If a missing aria2c
stopped the app from opening a window, the user would have no way to reach the
screen that explains how to install it. So the window *always* opens; the engine
is a consequence of the window existing. `main.v` hands `platform.boot` a
`ready_fn` that starts the engine, and the Setup screen is rendered from the
`missing` phase.

**3. Notifications are queued and diffed, never emitted.**

`core.notice.diff(prev, now)` is a pure function from the last tick's view of the
world to this tick's, returning the events in between. The rule is one sentence:

> an event is a **change of status that lands on a terminal one**.

Both halves matter. "Lands on terminal" is the obvious one. "Change of status" is
the half that is easy to get wrong in the *stricter* direction: requiring the
previous status to be non-terminal as well looks tidier and silently drops
`complete → removed`, which is what happens when a user deletes a finished row.
The row vanishing with no explanation is the behaviour the queue exists to
prevent.

`core.NoticeQueue` is drained into the next tick and emptied. A notice is
delivered exactly once — a notice left in the queue reappears on every tick for
the life of the window, and a user watching a queue sees "Finished x" appear
again every second.

**4. A notice produced by this tick rides the *next* one.**

The frontend is about to render this snapshot when the notices are drained, and a
"Finished x" arriving in the same payload as the row for x is a toast the user
cannot read yet. One beat of latency is the price of the notice arriving after
the thing it is about.

**5. The restart policy is a pure function over a value, and it is documented
rather than guessed.**

`aria2ctl.Budget.decide(now) -> Decision`: **3 restarts in 60 seconds, backing
off 1s, 2s, 4s.**

Why 3: two restarts cover a single transient (an antivirus scan holding the exe,
a port released a moment late); three covers a genuine bad day. Why stop there: a
crash loop that runs forever is indistinguishable from a working app as far as
the window is concerned — the UI would show a spinner and the queue would
silently never advance. Stopping turns that into a visible, explicable failure
with the log above it, which is the only outcome a user can act on.

Why cap at 4s: long enough that a repeated failure is not hammering the disk or
the port, short enough that the third retry still happens inside the session a
user is watching.

Two things are never restarts: a **missing binary** (that is the Setup page, and
restarting would fail identically forever), and a **clean shutdown we asked for**
(the budget is marked `stopping` *before* the shutdown RPC, so the exit that
follows is not counted as a crash — otherwise closing and reopening the app would
leave it unable to start its own engine).

The budget counts **restarts, not crashes**, and the guard is therefore `n > max`
rather than `n >= max`. With `>=` the third crash silently buys only two retries
and the documented budget is a lie. The off-by-one is invisible in a running app;
it just stops trying one attempt early. It is asserted from both sides in
`supervisor_test.v`.

**6. A restart is scheduled, never slept through.**

`schedule_restart()` records *when* the next attempt is due; the tick performs
it. A handler that called `time.sleep(4000)` would freeze the window for four
seconds, which is the most visible thing a desktop app can do wrong.

**7. There is no log-reading thread, and this is a considered omission.**

aria2's stderr is drained by `Supervisor.pump()` from the tick, because
`os.Process.pipe_read(.stderr)` is non-blocking (it is `PeekNamedPipe` on
Windows). A reader thread would own shared state, need `core`'s mutex, and still
could not emit — so it would add a lock and a race to solve a problem the polling
model does not have. It becomes worth it the day the Control API's listener needs
log lines *between* ticks.

This is why `core.State` owns a mutex that is currently **uncontended**: in
Phase 1 there is exactly one thread. The mutex is there so that Phase 6's
listener is an addition rather than a retrofit, and the invariant "every State
accessor takes the lock" is stated in the file so the audit is a grep.

**8. Limits have one meaning each, and the distinction is load-bearing.**

`''` means *do not send this option*; `0` means *unlimited*. They are different
instructions to aria2, and losing the difference means a scheduler that only
knows about bandwidth silently resets somebody's seed policy. The one genuinely
awkward field is `GlobalLimits.max_concurrent`, where `0` means *leave it alone*
rather than *unlimited*, because aria2 accepts
`--max-concurrent-downloads=0` as a real value with a third meaning.

## Alternatives considered

**Talk to the user's own aria2 if one is running, and spawn one only as a
fallback.** Cheaper, and it means an existing session of 200 downloads is picked
up for free. Rejected: we cannot give that instance our secret, cannot choose its
port, and cannot stop it when our window closes — so "supervise" would be a claim
the code could not honour. It is also the shape with the worst failure mode: our
first tick reaching the *user's* aria2, getting an auth error, and reporting
"engine not ready" while the daemon we spawned died on the port bind.

**Spawn the engine before `boot`, so the window opens already connected.** One
fewer `starting` frame on screen. Rejected: it makes a missing aria2c a
missing window, and the Setup page is the only way out of that.

**Block in `on_ready` until aria2 answers.** Simplest, and readiness becomes a
fact rather than a polled state. Rejected for the reason in (1): it is a frozen
window, and the bound would have to be so generous that it is not a bound.

**Read aria2's log file for the Logs tab instead of its stderr.** No pipe to
manage, no reader thread, and it survives a crash of our own. Rejected as the
*primary* source: it is written with a delay and a buffer, so the log tab would
lag the thing it is explaining. Kept as the on-disk log (`--log`) for after the
fact, which is what it is good at.

**Restart forever, with a longer and longer backoff.** Eventually the engine
comes back on its own. Rejected: the UI cannot distinguish it from a hang, and an
unbounded retry loop against a broken install is a way to keep a laptop's fan
running for no reason.

**A worker thread that polls aria2 and pushes into the webview.** The obvious
design, and the one the framework explicitly forbids (ADR-0010). Recorded here so
the next person does not spend a day rediscovering that it does not work.

## Consequences

- The window opens whether or not aria2c exists, and the `missing` phase is a
  real, reachable state with a real screen behind it.
- Readiness is polled, so the first second of every launch is `starting`. That is
  visible and correct.
- A notice can be up to one tick late, by design.
- Three restarts, then silence with an explanation. A user who wants more has to
  press Restart (Phase 3), and by then they have a log to look at.
- `core.State` has a lock and exactly one caller. The next caller must take it.
- Nothing in the project pushes. `grep -r emit` finds one function
  (`platform/host.v`'s `Ctx.emit`) and no callers.

## Notes

The restart numbers in this ADR are asserted in
`aria2ctl/supervisor_test.v::test_the_policy_constants_are_the_documented_ones`
and the notice bound in `core/notice_test.v`, so a quiet change to either fails
the build rather than quietly contradicting this document.
