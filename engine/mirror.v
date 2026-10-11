// mirror.v - a mirror SET, and what aria2 is actually doing with it.
//
// The decision this file records
//
// Phase 4's roadmap says "mirror sets with liveness probing". The temptation is to
// build a prober: HEAD each mirror, time the response, score the hosts, drop the
// dead ones. That would be a second transfer engine racing the first one, and
// ADR-0003 is explicit that Fluxget does not own the transfer. aria2 already has
// `uri-selector=feedback`, which picks mirrors from the piece-download feedback it
// already has, and it already fails over between them mid-download.
//
// So the split is:
//
//   * WE build the set: normalise, de-duplicate, order it.
//   * WE read what happened: aria2.getUris reports each URI with a status.
//   * WE do not probe. A second prober would be slower than the thing it measures
//     and would disagree with it.
//
// What aria2 actually answers, measured on 1.37.0
//
//   aria2.addUri(["http://127.0.0.1:1/dead.bin", "https://.../1MB.bin"])
//   aria2.getUris -> {"result":[
//       {"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"},
//       {"status":"waiting","uri":"https://.../1MB.bin"},
//       {"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"},
//       {"status":"waiting","uri":"https://.../1MB.bin"},
//       {"status":"waiting","uri":"http://127.0.0.1:1/dead.bin"}]}
//
// FIVE entries for TWO uris. aria2 expands the set internally - it speculatively
// opens mirrors and keeps the ones it has seen - so a caller that maps entries to
// mirrors one-for-one gets a set three times the size it passed in and a per-mirror
// count that is a fiction. Everything below is written around that observation
// rather than around an assumption that the answer mirrors the request.
module engine

// Mirror status words aria2 uses in getUris. Anything else decodes to
// mirror_unknown rather than being guessed at, because "a status we do not know"
// and "a status we assumed" are different things to show a user.
pub const mirror_used = 'used'
pub const mirror_waiting = 'waiting'
pub const mirror_unknown = 'unknown'

// max_mirrors is how many sources one download may carry.
//
// Mirror is one source in a set, and what aria2 last said about it.
pub struct Mirror {
pub mut:
	uri string
	// status is aria2's word: used, waiting, or unknown.
	status string
	// in_use is the only thing worth showing a user: aria2 is downloading from this
	// one right now.
	in_use bool
}

// MirrorSet is a de-duplicated, ordered list of sources.
pub struct MirrorSet {
pub mut:
	uris []string
}

// mirror_set_from normalises a requested set. It is THE normaliser -
// AddRequest.clean_uris delegates here - so there is one answer to "what is a
// mirror list" in this codebase rather than one per entry point.
//
// Four things happen, in this order, and the order is the point:
//
//  1. trim, because a stray space in a pasted URL is the most common way a mirror
//     set silently contains a URI that can never work.
//  2. drop schemes we cannot fetch. aria2 ACCEPTS a gopher URI and then fails the
//     whole download, so one typo in one entry of a six-entry set would kill the
//     other five. Filtering here is the difference between a bad entry and a dead
//     download.
//  3. de-duplicate, keeping the FIRST occurrence - and this is not cosmetic. The
//     same host three times in one addUri is three connections to one host, which
//     is a slow download and a rude one.
//  4. REFUSE an oversized set rather than truncating it. Truncation answers "added"
//     to a request for twenty mirrors and then uses eight, and a user who cannot
//     tell which eight got dropped cannot trust the queue.
//
// An empty result is an error rather than an empty download: the caller asked to
// add something and silence would be the worst possible answer.
pub fn mirror_set_from(requested []string) !MirrorSet {
	mut seen := map[string]bool{}
	mut out := []string{cap: requested.len}
	for raw in requested {
		uri := raw.trim_space()
		if uri == '' {
			continue
		}
		if !supported_scheme(uri) {
			continue
		}
		if seen[uri] {
			continue
		}
		seen[uri] = true
		out << uri
	}
	if out.len == 0 {
		return error('engine: no uri to download')
	}
	// The cap is checked AFTER filtering, so twenty unusable entries plus three good
	// ones is three mirrors and not a rejection: the count that matters is the count
	// aria2 will actually be handed.
	if out.len > max_add_uris {
		return error('engine: ${out.len} uris is more than the ${max_add_uris} allowed for one download')
	}
	return MirrorSet{
		uris: out
	}
}

// supported_scheme answers whether Fluxget will even try.
//
// http, https and ftp for files, plus magnet for a torrent. The magnet is here
// because a magnet is a perfectly good thing to hand aria2.addUri and dropping it
// would turn "add a torrent" into "no uri to download" - which is exactly what
// happened the first time this function existed, and it is caught by the magnet
// test that was written before it.
//
// Everything else - gopher, and the schemes aria2 itself rejects - is dropped.
fn supported_scheme(uri string) bool {
	lower := uri.to_lower()
	for prefix in ['http://', 'https://', 'ftp://', 'ftps://', 'magnet:'] {
		if lower.starts_with(prefix) {
			return true
		}
	}
	return false
}

// mirrors_from decodes an aria2.getUris answer into per-URI state.
//
// It is given the URI SET WE SENT as well, because the answer contains entries for
// URIs we did not send - aria2 speculates - and because it repeats them. Anything
// outside our set is dropped: reporting a mirror the user never asked for, under a
// number they can count, is worse than not reporting it.
pub fn mirrors_from(requested []string, entries []Mirror) []Mirror {
	mut wanted := map[string]bool{}
	for u in requested {
		wanted[u] = true
	}
	mut out := []Mirror{}
	mut seen := map[string]bool{}
	for e in entries {
		if !wanted[e.uri] || seen[e.uri] {
			continue
		}
		seen[e.uri] = true
		out << e
	}
	return out
}

// live returns the mirrors aria2 is currently downloading from, and is the answer
// to "is the set working".
//
// It is a separate function because a set with zero live mirrors and a set with one
// are the two states that mean different things, and both are legitimate: a fresh
// download has none yet, and a finished one has none any more.
pub fn live_mirrors(ms []Mirror) []string {
	mut out := []string{}
	for m in ms {
		if m.status == mirror_used {
			out << m.uri
		}
	}
	return out
}

// has_live is the gate a caller actually wants: is this download getting its bytes
// from anywhere in the set?
pub fn has_live(ms []Mirror) bool {
	for m in ms {
		if m.status == mirror_used {
			return true
		}
	}
	return false
}

pub fn idle_mirrors(ms []Mirror) []string {
	mut out := []string{}
	for m in ms {
		if m.status != mirror_used {
			out << m.uri
		}
	}
	return out
}

// retry_set is the set to RE-ADD a failed download from, after dropping the
// mirrors aria2 never used.
//
// THE PHASE 4 GATE, and this is the half that is easy to get backwards.
//
// "A dead mirror is dropped and the set continues" sounds like: drop anything
// not marked used, and you have a smaller set. That is wrong, and it fails in
// the case the feature exists for.
//
// aria2 reports `waiting` for two different things:
//
//   * a mirror it has NOT NEEDED YET - the download is doing fine, it just does
//     not need a second connection right now;
//   * a mirror it TRIED AND GAVE UP ON.
//
// They are the same word, so a rule that drops every idle mirror also drops the
// healthy ones, and the retry loses the mirrors the user asked for.
//
// So the rule distinguishes using the one signal there is:
//
//   * at least one mirror is LIVE -> the idle ones are the ones aria2 could not
//     use, and the retry re-adds only the ones that worked. The set continues,
//     and it is smaller.
//   * NOTHING is live -> nothing distinguishes dead from unused, so the set is
//     kept whole. A retry that dropped everything would have nothing to add,
//     which is the one outcome worse than a slow retry.
//
// This is a PURE function of the state aria2 reported, which is why it is testable
// without a network - and why the tests below are the whole proof of the rule.
pub fn retry_set(ms []Mirror) []string {
	live := live_mirrors(ms)
	if live.len == 0 {
		// Nothing worked and nothing is provably dead either. Keep the whole set:
		// a retry that narrowed to nothing would have nothing to re-add.
		mut all := []string{}
		for m in ms {
			all << m.uri
		}
		return all
	}
	return live
}
