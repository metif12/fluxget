// ring.v - the bounded log buffer behind the Logs tab.
//
// aria2's stderr is a stream of bytes with no line discipline, and a download
// that is retrying writes a line per attempt. Two things follow, and they are
// the whole reason this is a type instead of a []string:
//
//   * Chunks do not align to lines. pipe_read returns whatever is in the pipe
//     buffer, so a "line" is really a line plus a fragment of the next one. The
//     buffer has to hold the partial tail until the rest arrives, or the Logs
//     tab shows half a line followed by the other half.
//   * The buffer has to be bounded. A long session with a chatty engine would
//     otherwise grow without limit, and this is process memory on a machine
//     that also holds a webview.
//
// Pure, so it is tested. It is the one part of the supervisor that can be.
module aria2ctl

// default_capacity is how many lines the Logs tab keeps.
//
// 200 is a screen or two of scrollback: enough to see what happened around a
// failure, small enough that the memory is noise next to the webview.
pub const default_capacity = 200

// Ring is a fixed-capacity, newest-last line buffer.
//
// Not a channel and not a mutex-guarded queue: in Phase 1 the only writer is
// the tick handler on the webview main thread (see ADR-0002), so concurrency
// would be a claim rather than a requirement.
pub struct Ring {
pub mut:
	// buf holds the retained lines, oldest first, at most `limit` of them.
	buf []string
	// limit is the capacity. Fixed at construction so the bound cannot be
	// changed underneath a reader mid-session.
	limit int
	// dropped counts lines that fell off the front. The Logs tab shows it, so a
	// user can tell "nothing happened" from "we threw it away".
	dropped int
	// partial is an unterminated trailing fragment, kept until its newline
	// arrives.
	partial string
}

// new_ring returns an empty ring. Capacity is clamped to at least 1 so a
// zero-capacity ring (a caller passing 0) still accepts a line instead of
// dividing by zero in the eviction path.
pub fn new_ring(capacity int) &Ring {
	return &Ring{
		buf:   []string{cap: if capacity < 1 { 1 } else { capacity }}
		limit: if capacity < 1 { 1 } else { capacity }
	}
}

// feed accepts a raw chunk from the pipe and splits it into whole lines.
//
// String.index is the search primitive: it returns ?int, so "no newline in this
// chunk" is a value rather than a sentinel. (`index_of` does not exist in
// V 0.5.2, and the failure is nasty: it is an unknown-method error, and the
// `?int` it never produced then cascades into three unrelated-looking range
// errors on the next line.)
//
// \r is stripped rather than treated as a line ending. aria2 on Windows writes
// CRLF, and a Logs tab full of stray carriage returns renders as staircases in
// any element that does not treat them as whitespace.
//
// The trailing fragment is deliberately NOT emitted. Emitting it would put half
// a line in the tab every tick and then a second entry with the rest, which is
// worse to read than a line that appears a beat late.
pub fn (mut r Ring) feed(chunk string) {
	if chunk == '' {
		return
	}
	mut pending := r.partial + chunk
	for {
		at := pending.index('\n') or { -1 }
		if at < 0 {
			break
		}
		r.push_line(pending[..at].replace('\r', ''))
		pending = pending[at + 1..]
	}
	r.partial = pending
}

// push adds one already-complete line.
pub fn (mut r Ring) push(line string) {
	r.push_line(line)
}

// push_line is the eviction path, kept separate so feed stays readable.
//
// When the buffer is full the OLDEST line goes, not the newest: a log is read
// backwards from the failure, and dropping the newest line would hide the very
// error that is being diagnosed.
fn (mut r Ring) push_line(line string) {
	if r.limit <= 0 {
		return
	}
	// A blank line is not worth a slot. aria2 emits them around retries, and a
	// tab of empty rows reads as a rendering bug.
	if line.trim_space() == '' {
		return
	}
	r.buf << line
	if r.buf.len > r.limit {
		// The excess is almost always 1, but a limit that shrank under us (it
		// cannot today) would make this wrong, so it is written as a loop.
		for r.buf.len > r.limit {
			r.buf.delete(0)
			r.dropped++
		}
	}
}

// pending_fragment exposes the unterminated tail. The supervisor's shutdown path
// flushes it, so the last line of a session is not lost just because the daemon
// stopped mid-write.
pub fn (r Ring) pending_fragment() string {
	return r.partial
}

// flush emits any unterminated tail as a final line. Pure, and idempotent: the
// partial is cleared, so a second flush adds nothing.
pub fn (mut r Ring) flush() {
	if r.partial == '' {
		return
	}
	line := r.partial.replace('\r', '')
	r.partial = ''
	r.push_line(line)
}

// lines returns the retained lines newest first, which is the order the Logs tab
// renders. Newest first because the line a user wants after a failure is the
// last one, and it should not be below the fold.
//
// A copy, not the backing array: the caller is a handler handing the slice to
// json2.encode on the same thread, and returning the live array would let a
// later feed mutate a slice that has already been encoded.
pub fn (r Ring) lines() []string {
	// `len` not `cap`: V 0.5.2 refuses `init` without it, and every slot is
	// assigned in the loop below anyway.
	mut out := []string{len: r.buf.len, init: ''}
	for i, line in r.buf {
		out[r.buf.len - 1 - i] = line
	}
	return out
}

// count is how many lines are retained.
pub fn (r Ring) count() int {
	return r.buf.len
}

// how_many_dropped is how many fell off the front.
pub fn (r Ring) how_many_dropped() int {
	return r.dropped
}

// clear empties the buffer. Used when the engine is (re)started, so a stale
// crash's log does not sit above the new process's first line.
pub fn (mut r Ring) clear() {
	r.buf.clear()
	r.partial = ''
}
