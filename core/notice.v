// notice.v - the Notice queue and the diffing that fills it.
//
// CONTEXT.md's Notice is "a queued event, delivered in the next snapshot rather
// than pushed, because a handler may not emit from a worker thread". This file is
// the whole of that mechanism, and it is pure: it takes the previous tick's
// view of the world and this tick's, and returns the events in between. No
// socket, no process, no window - which is why a table of transitions can be
// tested exhaustively here instead of being discovered by a user.
//
// The alternative - an aria2 event stream, or a background watcher that pushes
// into the webview - is not available and not wanted. vails ADR-0010 forbids
// V->JS eval from a spawned worker, and aria2's notification hooks (onDownload
// Complete and friends) are a shell-out, not a callback. Polling and diffing is
// the honest shape for this framework.
module core

import rpc

// The Notice kinds. These strings cross the bridge and the frontend switches on
// them, so they are constants and they are pinned by the tests.
pub const notice_added = 'added'
pub const notice_finished = 'finished'
pub const notice_failed = 'failed'
pub const notice_removed = 'removed'
pub const notice_info = 'info'

// Notice is one queued event.
pub struct Notice {
pub mut:
	// kind is one of the notice_* constants.
	kind string
	// gid is the download it concerns. Empty for a notice about the engine
	// itself, which is why it is not the key.
	gid string
	// text is the human sentence. The frontend shows it verbatim; nothing
	// rephrases a Notice, because two components inventing their own wording for
	// the same event is how a log becomes unreadable.
	text string
	// at_ms is when the transition was observed.
	at_ms i64
}

// The aria2 Status values this file reacts to. Passed through unchanged
// elsewhere (CONTEXT.md), named here only where a transition is defined.
const status_complete = 'complete'
const status_error = 'error'
const status_removed = 'removed'

// terminal reports whether a status is one no more bytes will come from.
fn terminal(status string) bool {
	return status == status_complete || status == status_error || status == status_removed
}

// Seen is what the last tick remembered about one download.
pub struct Seen {
pub:
	status string
	// is_torrent is remembered separately because a torrent finishing and
	// starting to seed is a different event from a file finishing, and the
	// Status alone does not say which happened.
	is_torrent bool
}

// diff is the transition detector, and it is the heart of the tick.
//
// `prev` is the map the last call returned; `now` is this tick's statuses in the
// order the queue gave them; the return is the notices plus the map to pass in
// next time. Passing the previous RESULT back in (rather than mutating it) is
// what makes this testable: a test can hold two snapshots and ask what happened
// between them.
//
// The transitions, and why each one exists:
//
//   (new gid)          -> added      so a download handed over by the browser
//                                    extension, or added from the API, is
//                                    announced instead of silently appearing
//   -> complete        -> finished   the only event a user actually waits for
//   -> error           -> failed     with aria2's own message, not a generic one
//   -> removed         -> removed    a finished row that aria2 has discarded
//   -> non-terminal    -> (nothing)  aria2 moving an item back out of `stopped`
//                                    after a retry must NOT re-announce it
//
// The rule in one sentence: an event is a CHANGE OF STATUS that lands on a
// terminal one. Both halves matter.
//
// The "lands on terminal" half is the obvious one: becoming complete is an
// event, still being active is not.
//
// The "change of status" half is the one that is easy to get wrong in the
// stricter direction. Requiring the previous status to be NON-terminal as well
// looks tidier and is wrong: it silently drops complete -> removed, which is
// exactly what happens when a user removes a finished row, and the row
// disappearing with no explanation is the behaviour this queue exists to
// prevent. Terminal -> a DIFFERENT terminal is still news.
//
// A retry (error -> waiting -> error) announces the second error, and that is
// correct: something did change, and a user watching a queue wants to know the
// retry failed again. What must stay silent is the middle step, and it does.
pub fn diff(prev map[string]Seen, now []rpc.Status, now_ms i64) ([]Notice, map[string]Seen) {
	mut notices := []Notice{}
	// `map[string]Seen{}` with no attributes: V 0.5.2 rejects
	// `map[string]Seen{cap: n}` outright ("explicit `map` initialization does
	// not support parameters"). Maps are not presized, unlike arrays.
	mut next := map[string]Seen{}
	for s in now {
		before := prev[s.gid] or { Seen{} }
		next[s.gid] = Seen{
			status:     s.status
			is_torrent: s.is_torrent()
		}
		if n := transition(before, s, now_ms) {
			notices << n
		}
	}
	return notices, next
}

// transition is one download's worth of diffing, split out so the table above
// and the code cannot drift apart.
fn transition(before Seen, s rpc.Status, now_ms i64) ?Notice {
	// A gid we have never seen is new to the window, whatever state it is in.
	// A resumed session's finished downloads arrive here on the first tick, and
	// telling the user about them is more useful than pretending the list was
	// always that way.
	if before.status == '' {
		mut kind := notice_added
		if s.status == status_complete {
			kind = notice_finished
		} else if s.status == status_error {
			kind = notice_failed
		}
		return Notice{
			kind:  kind
			gid:   s.gid
			text:  describe(kind, s)
			at_ms: now_ms
		}
	}
	// Unchanged status is never an event, whatever it is. Everything else that
	// lands on a terminal state is - including terminal -> a different terminal,
	// which is what makes a removed finished row explain itself.
	if before.status == s.status {
		return none
	}
	if terminal(s.status) {
		mut kind := notice_finished
		if s.status == status_error {
			kind = notice_failed
		} else if s.status == status_removed {
			kind = notice_removed
		}
		return Notice{
			kind:  kind
			gid:   s.gid
			text:  describe(kind, s)
			at_ms: now_ms
		}
	}
	return none
}

// describe is the one place a Notice's sentence is written. Every component
// shows this text rather than composing its own, so the same event reads the
// same in the toast, the log and the history.
fn describe(kind string, s rpc.Status) string {
	name := s.display_name('')
	match kind {
		notice_finished {
			if s.is_torrent() && s.seeder {
				return 'Finished seeding ' + name
			}
			return 'Finished ' + name
		}
		notice_failed {
			// aria2's own message, verbatim. A generic "download failed" is what
			// a user cannot act on; "Connection refused" is what they can.
			reason := if s.error == '' { 'no reason given' } else { s.error }
			return 'Failed ' + name + ': ' + reason
		}
		notice_removed {
			return 'Removed ' + name
		}
		else {
			return 'Added ' + name
		}
	}
}

// max_notices bounds the queue.
//
// A burst is possible: restoring a session with 500 finished downloads puts 500
// gids in front of the diff on the first tick, and an unbounded queue would
// carry all of them into one tick response forever after.
pub const max_notices = 100

// NoticeQueue is the hand-off between the engine's state and the next tick.
pub struct NoticeQueue {
pub mut:
	items   []Notice
	limit   int = max_notices
	dropped int
}

// push adds one notice, dropping the OLDEST when full.
//
// Oldest first because a full queue means something went wrong in a hurry, and
// what just happened is more useful than what happened before the flood. The
// count is kept so the UI can say so rather than silently losing events.
pub fn (mut q NoticeQueue) push(n Notice) {
	q.items << n
	for q.items.len > q.limit {
		q.items.delete(0)
		q.dropped++
	}
}

// extend adds several, in order.
pub fn (mut q NoticeQueue) extend(ns []Notice) {
	for n in ns {
		q.push(n)
	}
}

// drain hands over everything queued and empties the queue.
//
// Oldest first, which is the opposite of aria2ctl.Ring.lines (newest first).
// Not an inconsistency: a log is read backwards from a failure, and a queue of
// events is read forwards. A user who sees "Failed a" then "Failed b" in that
// order is reading the order things happened.
//
// The emptying is the point. A Notice is delivered exactly once: a notice left
// in the queue would be re-sent on every tick forever, and a user watching a
// window would see "Finished x" appear again each second. If a tick fails
// midway the notices are still gone, which is the correct trade - the next
// diff will notice the state change again if it is still relevant.
pub fn (mut q NoticeQueue) drain() []Notice {
	out := q.items
	q.items = []Notice{}
	return out
}

// count is how many are waiting.
pub fn (q NoticeQueue) count() int {
	return q.items.len
}

// how_many_dropped is how many were discarded for space.
pub fn (q NoticeQueue) how_many_dropped() int {
	return q.dropped
}
