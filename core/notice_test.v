// notice_test.v - the transition table, tested exhaustively.
//
// Every case here is a pair of ticks: "the world looked like this, now it looks
// like that, what should the user be told". Nothing here opens a socket or
// starts a process, which is the point of keeping the diffing pure.
module core

import rpc

// st builds a Status with only the fields the diffing reads. Everything else is
// zero, and a test that does not care about completedLength should not have to
// invent one.
fn st(gid string, status string) rpc.Status {
	return rpc.Status{
		gid:    gid
		status: status
		dir:    '/downloads/' + gid
	}
}

// st_err is a failed download carrying aria2's own message.
fn st_err(gid string, reason string) rpc.Status {
	return rpc.Status{
		gid:    gid
		status: 'error'
		dir:    '/downloads/' + gid
		error:  reason
	}
}

// kinds is the shortcut for asserting which events a transition produced.
fn kinds(ns []Notice) []string {
	mut out := []string{len: ns.len, init: ''}
	for i, n in ns {
		out[i] = n.kind
	}
	return out
}

// run diffs two ticks and returns the notices, discarding the new baseline.
fn run(before []rpc.Status, after []rpc.Status) []Notice {
	mut prev := map[string]Seen{}
	for s in before {
		prev[s.gid] = Seen{
			status: s.status
		}
	}
	mut now := []rpc.Status{cap: after.len}
	now << after
	ns, _ := diff(prev, now, 1000)
	return ns
}

fn test_a_download_that_appears_is_announced() {
	// The browser extension's Grab lands here: the user pressed "download" in
	// Chrome and something has to say so, or the row just appears.
	ns := run([], [st('aa01', 'active')])
	assert kinds(ns) == [notice_added], '${kinds(ns)}'
	assert ns[0].gid == 'aa01'
}

fn test_a_download_that_finishes_announces_a_finish() {
	// The event a user is actually waiting for.
	ns := run([st('aa01', 'active')], [st('aa01', 'complete')])
	assert kinds(ns) == [notice_finished], '${kinds(ns)}'
	assert ns[0].text.contains('aa01'), ns[0].text
}

fn test_a_download_that_fails_carries_aria2s_own_reason() {
	// "Download failed" is not something anyone can act on. "Connection
	// refused" is.
	ns := run([st('aa01', 'active')], [st_err('aa01', 'Connection refused')])
	assert kinds(ns) == [notice_failed], '${kinds(ns)}'
	assert ns[0].text.contains('Connection refused'), ns[0].text
}

fn test_a_failure_with_no_message_says_so_rather_than_nothing() {
	// An empty reason must not produce a sentence that ends in a colon.
	ns := run([st('aa01', 'active')], [st_err('aa01', '')])
	assert kinds(ns) == [notice_failed]
	assert ns[0].text.contains('no reason given'), ns[0].text
}

fn test_nothing_changes_and_nothing_is_announced() {
	// The common case, and the one that would be a bug if it produced events: an
	// active download that is still active on the next tick.
	ns := run([st('aa01', 'active')], [st('aa01', 'active')])
	assert ns.len == 0, 'a still-active download is not news: ${kinds(ns)}'
}

fn test_a_retry_announces_the_new_failure_but_not_the_retry_itself() {
	// The rule this file exists for. aria2 moves an item error -> waiting ->
	// error when it retries. The middle step must be silent (the item is merely
	// waiting, nothing happened), and the second failure must be announced
	// because something did change: a user watching a queue wants to know the
	// retry failed too.
	ns := run([st('aa01', 'error')], [st('aa01', 'waiting')])
	assert ns.len == 0, 'leaving a terminal state is not an event: ${kinds(ns)}'
	ns2 := run([st('aa01', 'error'), st('aa01', 'waiting')], [st('aa01', 'error')])
	assert kinds(ns2) == [notice_failed], '${kinds(ns2)}'
}

fn test_a_removed_download_is_announced_separately_from_a_finished_one() {
	// aria2 discarding a result is not a completion, and a user who deleted a row
	// should not be told it finished.
	ns := run([st('aa01', 'complete')], [st('aa01', 'removed')])
	assert kinds(ns) == [notice_removed], '${kinds(ns)}'
}

fn test_a_download_already_finished_at_the_first_tick_is_reported() {
	// A resumed session: the first tick sees 500 completed gids. Announcing them
	// is more honest than showing a populated list as if it had always been
	// there, and the bounded queue means it cannot run away.
	ns := run([], [st('aa01', 'complete')])
	assert kinds(ns) == [notice_finished], '${kinds(ns)}'
}

fn test_a_torrent_that_finishes_says_it_finished_seeding() {
	// A seeded torrent is still active in aria2's terms. Telling the user
	// "Finished x" while it is uploading is the kind of small lie a download
	// manager tells.
	//
	// The dir here is deliberately relative. rpc.Status.display_name takes a
	// torrent's name from the FIRST segment of dir, which is only right when dir
	// is not absolute - and aria2's absolute form is ambiguous (a multi-file
	// torrent's dir ends with the torrent's own name, a single-file one does
	// not). That is a known rough edge in rpc/types.v, revisited in Phase 4 with
	// a real .torrent; the Notice wording is what is under test here.
	mut s := st('aa01', 'complete')
	s.info_hash = '0123456789abcdef0123456789abcdef01234567'
	s.seeder = true
	s.dir = 'linux-image'
	ns := run([st('aa01', 'active')], [s])
	assert kinds(ns) == [notice_finished]
	assert ns[0].text.contains('seeding'), ns[0].text
	assert ns[0].text.contains('linux-image'), 'and it names the torrent: ${ns[0].text}'
}

fn test_several_transitions_at_once_are_all_reported() {
	// One tick, three downloads, three different events: the case a per-gid
	// callback design would need three wakeups for.
	ns := run([st('a1', 'active'), st('b2', 'active'), st('c3', 'waiting')], [
		st('a1', 'complete'),
		st_err('b2', 'name resolution failed'),
		st('c3', 'waiting'),
		st('d4', 'active'),
	])
	assert ns.len == 3, '${kinds(ns)}'
	assert kinds(ns) == [notice_finished, notice_failed, notice_added], '${kinds(ns)}'
}

fn test_the_baseline_moves_forward_so_the_next_tick_compares_against_it() {
	// The bug this guards: diffing against the tick before last would re-announce
	// a finish on every subsequent tick.
	mut prev := map[string]Seen{}
	mut first := []rpc.Status{cap: 1}
	first << st('aa01', 'active')
	ns1, next := diff(prev, first, 1000)
	assert kinds(ns1) == [notice_added]
	mut second := []rpc.Status{cap: 1}
	second << st('aa01', 'complete')
	ns2, next2 := diff(next, second, 1500)
	assert kinds(ns2) == [notice_finished]
	mut third := []rpc.Status{cap: 1}
	third << st('aa01', 'complete')
	ns3, _ := diff(next2, third, 2000)
	assert ns3.len == 0, 'and then it is quiet: ${kinds(ns3)}'
}

fn test_a_notice_is_delivered_exactly_once() {
	// The queue's contract. A notice left behind would be re-sent on every tick
	// and a user watching the window would see it appear again each second.
	mut q := NoticeQueue{}
	q.push(Notice{
		kind: notice_finished
		gid:  'aa01'
	})
	assert q.count() == 1
	drained := q.drain()
	assert drained.len == 1
	assert q.count() == 0, 'drain must empty the queue'
	assert q.drain().len == 0, 'a second drain must deliver nothing'
}

fn test_the_queue_is_bounded_and_says_what_it_dropped() {
	// A burst is real: a resumed session puts every finished gid in front of the
	// first diff. An unbounded queue would carry all of them into every tick
	// response forever after.
	mut q := NoticeQueue{ limit: 3 }
	for i in 0 .. 10 {
		q.push(Notice{
			kind: notice_info
			text: i.str()
		})
	}
	assert q.count() == 3, 'the bound must hold: ${q.count()}'
	assert q.how_many_dropped() == 7
	// drain is OLDEST first - a queue of events is read forwards, unlike a log.
	// So the survivors are 7, 8, 9 and the newest is last.
	drained := q.drain()
	assert drained[0].text == '7', 'the oldest survivor: ${drained}'
	assert drained[2].text == '9', 'and the newest is still there: ${drained}'
}

fn test_the_default_notice_limit_is_the_documented_one() {
	// 100 is quoted in ADR-0002. Changing it silently would make the ADR wrong.
	assert max_notices == 100
	assert NoticeQueue{}.limit == max_notices
}

// A notice carries the FACTS as well as the English sentence, because a Persian
// or Chinese UI cannot use a pre-composed English string and a Logs tab with no
// locale cannot compose one. Both are shipped.
fn test_a_notice_carries_both_the_facts_and_an_english_sentence() {
	// This is what the frontend's i18n layer composes from. `name` is the subject
	// and `error` is aria2's own wording, which is NOT translated: a server's error
	// text is more useful verbatim than a generic translation of it.
	ns := run([st('aa01', 'active')], [st_err('aa01', 'Connection refused')])
	assert kinds(ns) == [notice_failed], '${kinds(ns)}'
	assert ns[0].name != '', 'a localised toast needs a subject: ${ns[0]}'
	assert ns[0].name == ns[0].gid || ns[0].name.contains('aa01'), ns[0].name
	assert ns[0].error == 'Connection refused', ns[0].error
	// And the English sentence is still whole, for the Logs tab / CLI / MCP server.
	assert ns[0].text.contains('Connection refused'), ns[0].text
	assert ns[0].text.starts_with('Failed'), ns[0].text
}

fn test_a_successful_notice_has_no_error_to_translate() {
	ns := run([st('aa01', 'active')], [st('aa01', 'complete')])
	assert kinds(ns) == [notice_finished]
	assert ns[0].error == '', 'a finish has no error, and an empty one must not be invented'
	assert ns[0].text.contains('Finished'), ns[0].text
}

fn test_an_engine_notice_carries_text_and_no_download() {
	// Notices about the engine itself have no gid and no name, which is why
	// `text` cannot be optional: it is all such a notice has.
	mut q := NoticeQueue{}
	q.push(Notice{
		kind: notice_info
		text: 'aria2c was not found. Run .\\scripts\\fetch-aria2.ps1, or set a path in Settings.'
	})
	got := q.drain()
	assert got.len == 1
	assert got[0].gid == '' && got[0].name == ''
	assert got[0].text.contains('fetch-aria2.ps1')
}

fn test_the_notice_kind_words_are_the_ones_the_frontend_switches_on() {
	// These cross the bridge. A rename is a wire change.
	assert notice_added == 'added'
	assert notice_finished == 'finished'
	assert notice_failed == 'failed'
	assert notice_removed == 'removed'
	assert notice_info == 'info'
}

fn test_extend_keeps_order() {
	mut q := NoticeQueue{}
	q.extend([Notice{
		kind: notice_added
	}, Notice{
		kind: notice_finished
	}])
	assert kinds(q.drain()) == [notice_added, notice_finished]
}
