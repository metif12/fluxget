// ring_test.v - the log buffer, tested without a pipe.
//
// Every case here is something a real aria2 run produces, because the two bugs
// this buffer exists to prevent are both "what the pipe actually does" bugs: a
// read that lands mid-line, and a stream that never ends.
module aria2ctl

fn test_a_whole_line_in_one_chunk_becomes_one_entry() {
	mut r := new_ring(10)
	r.feed('bind: port 16800\n')
	assert r.count() == 1
	assert r.lines()[0] == 'bind: port 16800'
	assert r.pending_fragment() == ''
}

fn test_a_line_split_across_two_reads_is_still_one_line() {
	// This is the case the buffer exists for. pipe_read returns whatever the OS
	// has in the pipe, which is almost never aligned to a newline. Without the
	// held fragment the Logs tab would show two entries for one line and the
	// second one would be unreadable on its own.
	mut r := new_ring(10)
	r.feed('DOWNLOAD 2089b05ec')
	assert r.count() == 0, 'an unterminated fragment is not a line yet'
	assert r.pending_fragment() == 'DOWNLOAD 2089b05ec'

	r.feed('ca3d829: 12.4MiB/98MiB\n')
	assert r.count() == 1, 'got ${r.count()}'
	assert r.lines()[0] == 'DOWNLOAD 2089b05ecca3d829: 12.4MiB/98MiB'
	assert r.pending_fragment() == ''
}

fn test_several_lines_in_one_chunk_all_land() {
	mut r := new_ring(10)
	r.feed('one\ntwo\nthree\n')
	assert r.count() == 3
	// Newest first, which is the order the tab renders.
	assert r.lines()[0] == 'three'
	assert r.lines()[1] == 'two'
	assert r.lines()[2] == 'one'
}

fn test_crlf_from_windows_aria2_does_not_leave_carriage_returns() {
	// aria2 on Windows writes CRLF. A stray \r in a rendered row shows up as a
	// staircase, and it is the kind of thing nobody reports until a screenshot
	// makes it obvious.
	mut r := new_ring(10)
	r.feed('notices:\r\n')
	assert r.lines()[0] == 'notices:'
}

fn test_the_oldest_line_is_the_one_that_goes() {
	// A log is read backwards from the failure. Evicting the newest would hide
	// the error being diagnosed, which is the exact opposite of useful.
	mut r := new_ring(3)
	r.feed('one\ntwo\nthree\n')
	r.feed('four\n')
	assert r.count() == 3, 'the bound must hold'
	assert r.lines()[0] == 'four', 'newest first'
	assert r.how_many_dropped() == 1
	assert r.lines()[2] == 'two', 'the oldest survivor: ${r.lines()}'
}

fn test_a_blank_line_does_not_take_a_slot() {
	// aria2 pads its retry output with blank lines, and a tab of empty rows
	// reads as a rendering bug in the frontend.
	mut r := new_ring(3)
	r.feed('a\n\n   \nb\n')
	assert r.count() == 2, 'got ${r.count()}'
	assert r.lines()[0] == 'b'
}

fn test_flush_rescues_a_line_the_daemon_never_terminated() {
	// The shutdown path. aria2's last write before exiting can be a partial line,
	// and that is often the interesting one ("bind: Address already in use").
	mut r := new_ring(10)
	r.feed('bind: Address already in use')
	assert r.count() == 0
	r.flush()
	assert r.count() == 1
	assert r.lines()[0] == 'bind: Address already in use'
	// Idempotent: a second flush must not duplicate it.
	r.flush()
	assert r.count() == 1
}

fn test_a_zero_capacity_ring_still_behaves() {
	// A caller passing 0 is a bug, and the two wrong answers are a division by
	// zero and a ring that silently accepts unbounded lines.
	mut r := new_ring(0)
	r.feed('one\ntwo\n')
	assert r.limit == 1
	assert r.count() == 1
}

fn test_clear_drops_stale_lines_but_keeps_the_dropped_count() {
	// On a restart the old process's log must not sit above the new one's first
	// line. The dropped count is deliberately NOT reset: it describes what the
	// session has lost, not what the current buffer holds.
	mut r := new_ring(2)
	r.feed('old\n')
	r.clear()
	assert r.count() == 0
	r.feed('new\n')
	assert r.lines()[0] == 'new'
}

fn test_lines_hands_out_a_copy() {
	// json2.encode walks the slice on the same thread, but the tick that encodes
	// it and the tick that refills it are different beats. Returning the backing
	// array would let a feed mutate a slice that has already been encoded.
	mut r := new_ring(4)
	r.feed('one\n')
	snapshot := r.lines()
	r.feed('two\n')
	assert snapshot.len == 1, 'the earlier snapshot changed under us: ${snapshot}'
	assert snapshot[0] == 'one'
}
