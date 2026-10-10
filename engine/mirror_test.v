// mirror_test.v - the mirror set, written against what aria2 1.37.0 answers.
//
// The fixtures here are COPIED from a real aria2c, including the part that is
// inconvenient: an addUri of two URIs comes back as five rows. Testing against a
// tidied-up three-row answer would have produced a decoder that reports two
// mirrors when the engine is working on five.
module engine

import rpc

// get_uris_two_expanded_to_five, verbatim from aria2c 1.37.0 after
// addUri(["http://127.0.0.1:1/dead.bin", "https://ash-speed.hetzner.com/1MB.bin"]).
// One dead mirror, one live, both reported as `waiting` because the download was
// added paused.
const get_uris_two_expanded_to_five = '[{"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"},{"status":"waiting","uri":"https://ash-speed.hetzner.com/1MB.bin"},{"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"},{"status":"waiting","uri":"https://ash-speed.hetzner.com/1MB.bin"},{"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"}]'

// The same set once aria2 has picked one and started pulling from it.
const get_uris_one_in_use = '[{"status":"used","uri":"https://ash-speed.hetzner.com/1MB.bin"},{"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"}]'

// ---- building a set -----------------------------------------------------

// The same host twice is two connections to one host, which is a slow download
// and a rude one. This is the most common mistake in a mirror list and the reason
// the set is de-duplicated before aria2 ever sees it.
fn test_a_repeated_mirror_is_added_once() {
	s := mirror_set_from(['https://a.example/f.bin', 'https://a.example/f.bin']) or {
		assert false, err.msg()
		return
	}
	assert s.uris.len == 1, '${s.uris}'
	assert s.uris[0] == 'https://a.example/f.bin', s.uris[0]
}

// A pasted URL with a trailing space is the most common way a set silently
// contains a URI that can never work.
fn test_mirrors_are_trimmed() {
	s := mirror_set_from(['  https://a.example/f.bin  ']) or {
		assert false, err.msg()
		return
	}
	assert s.uris[0] == 'https://a.example/f.bin', s.uris[0]
}

// Order is preserved: the first entry is the one the user listed first, and
// aria2's own feedback selector will usually start there.
fn test_the_order_the_user_gave_is_the_order_aria2_gets() {
	s := mirror_set_from(['https://a/1', 'https://b/1', 'https://c/1']) or {
		assert false, err.msg()
		return
	}
	assert s.uris.len == 3, '${s.uris}'
	assert s.uris[0] == 'https://a/1', s.uris[0]
	assert s.uris[2] == 'https://c/1', s.uris[2]
}

// A scheme aria2 will fail the WHOLE download over. One typo in one entry of a
// six-entry set must not kill the other five.
fn test_a_scheme_aria2_cannot_fetch_is_dropped_rather_than_fatal() {
	s := mirror_set_from(['gopher://old.example/f', 'https://a.example/f']) or {
		assert false, err.msg()
		return
	}
	assert s.uris.len == 1, '${s.uris}'
	assert s.uris[0] == 'https://a.example/f', s.uris[0]
}

// ftp still works in aria2 and users expect it to.
fn test_ftp_is_kept() {
	s := mirror_set_from(['ftp://a.example/f.bin', 'http://b.example/f.bin']) or {
		assert false, err.msg()
		return
	}
	assert s.uris.len == 2, '${s.uris}'
}

// A set is a socket-opening surface: aria2 is handed whatever we send, and a
// runaway list from a malformed loop is refused rather than truncated. Truncating
// would answer "added" to a request for 220 mirrors and then use 200, and a user
// who cannot tell which twenty got dropped cannot trust the queue.
fn test_an_oversized_set_is_refused_not_truncated() {
	mut many := []string{}
	for i in 0 .. max_add_uris + 20 {
		many << 'https://m${i}.example/f.bin'
	}
	assert set_fails(many), 'an oversized mirror set must be refused'
}

// The cap is on the count aria2 will actually be handed, so unusable entries do
// not consume the allowance.
fn test_the_cap_counts_usable_uris_only() {
	mut mixed := []string{}
	for i in 0 .. max_add_uris + 20 {
		mixed << 'gopher://old${i}.example/f'
	}
	mixed << 'https://good.example/f.bin'
	s := mirror_set_from(mixed) or {
		assert false, err.msg()
		return
	}
	assert s.uris.len == 1, 'twenty unusable entries must not cost the one good one its slot: ${s.uris}'
}

// An empty set is an error, not an empty download. The caller asked to add
// something and silence would be the worst possible answer.
fn test_a_set_with_nothing_usable_is_an_error() {
	// A helper, because `or { return }` on a function returning a struct is the
	// clean way to assert a failure without the `is` operator - which V only has
	// for sum types.
	assert set_fails([]string{}), 'an empty request must not produce a download'
	assert set_fails(['', '   ']), 'whitespace is not a uri'
	assert set_fails(['gopher://x/y']), 'a scheme aria2 cannot fetch is not a mirror'
	assert !set_fails(['https://a.example/f']), 'a usable uri must not be reported as an error'
}

fn set_fails(requested []string) bool {
	// `or { return true }` is the whole assertion: the only way to reach it is for
	// mirror_set_from to have failed.
	mirror_set_from(requested) or { return true }
	return false
}

// ---- reading what aria2 did ----------------------------------------------

// THE regression test. Five rows come back for two URIs, and a decoder that
// reports five mirrors has a per-mirror count that is a fiction.
fn test_repeated_rows_collapse_to_the_set_we_asked_for() {
	requested := ['http://127.0.0.1:1/dead.bin', 'https://ash-speed.hetzner.com/1MB.bin']
	entries := decode_entries(get_uris_two_expanded_to_five)
	got := mirrors_from(requested, entries)
	assert got.len == 2, 'two URIs in, so two mirrors out: ${got.len}'
	assert got[0].uri == 'http://127.0.0.1:1/dead.bin', got[0].uri
	assert got[1].uri == 'https://ash-speed.hetzner.com/1MB.bin', got[1].uri
}

// aria2 speculates and reports rows for URIs we never sent. Showing a mirror the
// user did not add, under a number they can count, is worse than not showing it.
fn test_rows_for_uris_we_never_sent_are_dropped() {
	requested := ['https://a.example/f.bin']
	entries := decode_entries('[{"status":"used","uri":"https://a.example/f.bin"},{"status":"used","uri":"https://surprise.example/f.bin"}]')
	got := mirrors_from(requested, entries)
	assert got.len == 1, '${got}'
	assert got[0].uri == 'https://a.example/f.bin', got[0].uri
}

// aria2's own word decides whether a mirror is in use, and nothing here guesses.
// Looked up by URI, because aria2's row order is incidental - see mir() below.
fn test_a_used_mirror_is_the_one_aria2_is_pulling_from() {
	requested := ['http://127.0.0.1:1/dead.bin', 'https://ash-speed.hetzner.com/1MB.bin']
	entries := decode_entries(get_uris_one_in_use)
	got := mirrors_from(requested, entries)

	assert has_live(got), 'aria2 is downloading from one of them'
	live := live_mirrors(got)
	assert live.len == 1, '${live}'
	assert live[0] == 'https://ash-speed.hetzner.com/1MB.bin', live[0]
	assert mir(got, 'http://127.0.0.1:1/dead.bin').in_use == false, 'the waiting mirror is not in use'
	assert mir(got, 'https://ash-speed.hetzner.com/1MB.bin').in_use == true, 'the used mirror is'
}

// The dead mirror is the one aria2 is NOT using, and the set continues from the
// one it is. That is the phase's gate: a dead mirror does not stop the download.
//
// Looked up by URI rather than by index, because aria2's row order is incidental -
// it reports them in the order it is thinking about them and that will change. An
// assertion that depends on it passes today and fails tomorrow for a reason that
// has nothing to do with this test.
fn test_a_dead_mirror_is_dropped_and_the_set_continues() {
	requested := ['http://127.0.0.1:1/dead.bin', 'https://ash-speed.hetzner.com/1MB.bin']
	got := mirrors_from(requested, decode_entries(get_uris_one_in_use))

	assert mir(got, 'http://127.0.0.1:1/dead.bin').in_use == false, 'the dead mirror is not in use'
	assert mir(got, 'https://ash-speed.hetzner.com/1MB.bin').in_use == true, 'the live one is'

	idle := idle_mirrors(got)
	assert idle.len == 1, '${idle}'
	assert idle[0] == 'http://127.0.0.1:1/dead.bin', idle[0]

	// And what remains is a set that still works: one live mirror, so the
	// download has somewhere to pull from.
	assert live_mirrors(got).len == 1, 'dropping the idle mirror must leave a usable set'
}

// mir looks a mirror up by URI, and fails the test rather than guessing if it is
// not there.
fn mir(ms []Mirror, uri string) Mirror {
	for m in ms {
		if m.uri == uri {
			return m
		}
	}
	panic('no mirror for ${uri} in ${ms}')
}

// A fresh download has no live mirror yet and a finished one has none any more.
// Both are legitimate and neither means the set failed.
fn test_a_set_with_nothing_in_use_is_not_a_failure() {
	requested := ['https://a.example/f.bin']
	// Paused, never started.
	assert !has_live(mirrors_from(requested, decode_entries(get_uris_two_expanded_to_five)))
}

// An unrecognised status is reported as unknown, never guessed at. "A status we
// do not know" and "a status we assumed" are different things to show a user.
fn test_an_unknown_status_is_not_mistaken_for_used() {
	got := mirrors_from(['https://a.example/f.bin'],
		decode_entries('[{"status":"something-new","uri":"https://a.example/f.bin"}]'))
	assert got[0].status == 'something-new', got[0].status
	assert got[0].in_use == false, 'an unknown status is not "used"'
	assert !has_live(got), 'and it is certainly not live'
}

// An entry with no uri is dropped rather than becoming an empty mirror the UI
// would render as a blank row.
fn test_an_entry_with_no_uri_is_dropped() {
	got := mirrors_from(['https://a.example/f.bin'],
		decode_entries('[{"status":"used"},{"status":"used","uri":"https://a.example/f.bin"}]'))
	assert got.len == 1, '${got}'
}

// ---- the shared decoder --------------------------------------------------

// decode_entries is the one place a getUris string becomes rows, going through
// rpc's pure parser exactly as Engine.mirror_state does - so a test cannot pass
// against a decoder the engine does not use.
fn decode_entries(raw string) []Mirror {
	entries := rpc.parse_mirror_entries(raw)
	mut rows := []Mirror{len: entries.len}
	for i, e in entries {
		rows[i] = Mirror{
			uri:    e.uri
			status: if e.status == '' { mirror_unknown } else { e.status }
			in_use: e.status == mirror_used
		}
	}
	return rows
}
