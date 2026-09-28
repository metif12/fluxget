// types.v - the aria2 wire shapes, as Fluxget sees them.
//
// Naming follows the WIRE FORMAT RULE in platform/commands.v: field names are
// the JSON keys, snake_case, and must be written the same way in the
// TypeScript the frontend reads. That is also what aria2 itself uses, so
// nothing is renamed in translation and nothing is lost.
//
// Decoding is tolerant on purpose. aria2 has shipped with inconsistent names
// across versions (getGlobalStat answers "downloadSpeed" in practice and the
// manual documents "downloadSpeedOverall"), so a field that moved is read from
// either name rather than silently becoming zero. Zero is a valid value for
// every one of these, which is exactly why a wrong key is so easy to miss.
//
// Comments in this project are ASCII only. V 0.5.2's scanner does not
// reliably terminate a comment line that carries a multi-byte character, and
// the failure it reports ("unexpected eof, expecting }") points at the end of
// the file rather than at the actual line. scripts/test.ps1 enforces it.
module rpc

// Status is one download, as aria2.tellStatus / tellActive / tellWaiting /
// tellStopped return it.
pub struct Status {
pub mut:
	gid                      string
	status                   string
	total_length             i64
	completed_length         i64
	upload_length            i64
	download_speed           i64
	upload_speed             i64
	connections              int
	num_seeders              int
	num_leechers             int
	num_pieces               int
	piece_length             i64
	seeder                   bool
	info_hash                string
	dir                      string
	error                    string
	error_code               string
	followed_by              string
	following_gid            string
	belongs_to               string
	available_peer_count     int
	verified_length          i64
	verify_integrity_pending bool
	// `removed` was a boolean on older aria2 and a string on newer ones. Both
	// decode into string, a missing key leaves it empty, so callers ask
	// is_removed() rather than comparing against a literal.
	removed string
	// file_path is the first entry of aria2's `files` array: the full path of the
	// payload. It is the ONLY place a plain file's real name appears - `dir` is
	// the folder, which is why a row used to be labelled with the name of the
	// directory it was downloading into.
	//
	// Decoded from the status rather than fetched with getFiles(), because a
	// second call per row per tick would be one round trip per download to learn
	// something the snapshot already contains.
	file_path string
}

// is_removed reports whether aria2 marked this result as removed from disk.
pub fn (s Status) is_removed() bool {
	return s.removed != ''
}

// is_torrent reports a swarm download. Decides which detail panel the UI shows,
// and whether the global upload cap is ours to manage.
pub fn (s Status) is_torrent() bool {
	return s.info_hash != ''
}

// is_finished reports the states where no more bytes are coming.
pub fn (s Status) is_finished() bool {
	return s.status == 'complete' || s.status == 'error' || s.status == 'removed'
}

// is_seeding reports a finished torrent that is still serving. Not the same as
// "active": aria2 keeps a seeding item active, and the UI shows a different
// progress treatment for it.
pub fn (s Status) is_seeding() bool {
	return s.status == 'complete' && s.seeder && s.is_torrent()
}

// percent is 0..100, guarded so an unknown size reads as 0 rather than a NaN
// that would render as garbage in a row.
pub fn (s Status) percent() f64 {
	if s.total_length <= 0 {
		return 0.0
	}
	p := f64(s.completed_length) / f64(s.total_length) * 100.0
	if p < 0.0 {
		return 0.0
	}
	if p > 100.0 {
		return 100.0
	}
	return p
}

// eta_seconds is the remaining time at the current rate, or -1 when it cannot
// be known (no rate yet, or a torrent that may never finish).
pub fn (s Status) eta_seconds() i64 {
	if s.download_speed <= 0 || s.total_length <= 0 {
		return -1
	}
	remaining := s.total_length - s.completed_length
	if remaining <= 0 {
		return 0
	}
	return remaining / s.download_speed
}

// display_name is the most human name aria2 gives us: the file's own path, then
// the torrent's directory, then the uri, and finally the gid, so a row is never
// blank.
//
// The order starts with file_path because `dir` alone is not a name. A plain
// HTTP download into /downloads/linux-image/foo.iso reports dir as the DIRECTORY,
// so a row labelled from `dir` reads "linux-image" - the name of a folder, shown
// as if it were the file. That was not a hypothetical: the first end-to-end run
// rendered a 100 MB file as "downloads".
//
// For a torrent there is no single payload path worth showing, so the torrent's
// own directory is the right answer and stays second.
pub fn (s Status) display_name(uri string) string {
	if s.file_path != '' {
		base := last_segment(s.file_path)
		if base != '' {
			return base
		}
	}
	if s.info_hash != '' {
		return first_segment(s.dir)
	}
	if s.dir != '' {
		base := last_segment(s.dir)
		if base != '' {
			return base
		}
	}
	if uri != '' {
		return last_segment(uri.split('?')[0])
	}
	return s.gid
}

// last_segment is the file name at the end of a path. Both separators are
// handled: aria2 reports Windows paths with backslashes and torrent metadata
// with forward slashes.
//
// One-character string slices, not char literals. V rejects Go-style backtick
// char literals, and a char literal is easy to get wrong for a backslash.
fn last_segment(path string) string {
	p := trim_separators(path, true)
	for i := p.len - 1; i >= 0; i-- {
		if is_separator(p[i..i + 1]) {
			return p[i + 1..]
		}
	}
	return p
}

// first_segment is the top-level directory name, which is how a torrent's own
// name is read out of the path aria2 reports.
fn first_segment(path string) string {
	p := trim_separators(path, false)
	for i := 0; i < p.len; i++ {
		if is_separator(p[i..i + 1]) {
			return p[..i]
		}
	}
	return p
}

fn is_separator(ch string) bool {
	return ch == '/' || ch == backslash
}

fn trim_separators(path string, right bool) string {
	mut out := path
	if right {
		for out.len > 0 && is_separator(out[out.len - 1..out.len]) {
			out = out[..out.len - 1]
		}
		return out
	}
	for out.len > 0 && is_separator(out[0..1]) {
		out = out[1..]
	}
	return out
}

// backslash is spelled this way because the obvious literals do not both work:
// V rejects Go-style backtick char literals, and mixing a double-quoted
// backslash with a single-quoted forward slash in one expression reads as if it
// should be symmetric when it is not.
const backslash = '\\'

// GlobalStat is aria2.getGlobalStat. The manual calls the speed fields
// downloadSpeedOverall / uploadSpeedOverall; every released build answers
// downloadSpeed / uploadSpeed. Both are read.
pub struct GlobalStat {
pub mut:
	download_speed    i64
	upload_speed      i64
	num_active        int
	num_waiting       int
	num_stopped       int
	num_stopped_total int
}

// FileEntry is one file inside a download, from aria2.getFiles. `selected` is
// aria2's view of --select-file, which is how the torrent file picker shows
// what is actually going to be fetched.
pub struct FileEntry {
pub mut:
	index            int
	path             string
	length           i64
	completed_length i64
	selected         bool
}

// Peer is one swarm connection, from aria2.getPeers.
pub struct Peer {
pub mut:
	peer_id        string
	ip             string
	port           int
	am_choking     bool
	peer_choking   bool
	download_speed i64
	upload_speed   i64
	seeder         bool
	bitfield       string
}

// is_usable reports a peer that is neither choking us nor choked by us. This is
// the count the peer panel leads with, since it is the number that explains
// why a torrent is going nowhere.
pub fn (p Peer) is_usable() bool {
	return !p.peer_choking && !p.am_choking
}

// Tracker is one announce endpoint, from aria2.getServers. A download's peers
// come from its trackers *plus* DHT *plus* PEX, so this list is never the whole
// story and the UI should not imply otherwise.
pub struct Tracker {
pub mut:
	index          int
	uri            string
	current_uri    string
	download_speed i64
}

// Version is aria2.getVersion. enabled_features is how Fluxget refuses to
// pretend: a build without "BitTorrent" cannot do torrents, and the setup
// screen should say so instead of failing later on the first magnet.
pub struct Version {
pub mut:
	version          string
	enabled_features []string
}

// has_feature reports whether aria2 was built with a named protocol.
pub fn (v Version) has_feature(name string) bool {
	return name in v.enabled_features
}

// supports_torrents is the one capability check that matters at startup.
pub fn (v Version) supports_torrents() bool {
	return v.has_feature('BitTorrent')
}

// SessionInfo is aria2.getSessionInfo.
pub struct SessionInfo {
pub mut:
	session_id string
}

// Options is aria2's option bag (getOption / getGlobalOption). Values are
// strings on the wire, always: aria2 stores everything as text and parses it
// per option, so this is a string map and the caller does the conversion.
pub type Options = map[string]string
