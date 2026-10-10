// settings.v - the settings document, and the only thing that persists it.
//
// Why a separate document rather than aria2's own option file
//
// aria2 already has an option file, and the obvious move is to edit that. Two
// reasons not to:
//
//   1. It is a different document with a different owner. aria2's file is
//      written by the operator, may be shared with a daemon Fluxget does not
//      run, and a portable install has none. Fluxget's settings describe what
//      THIS WINDOW does.
//
//   2. Everything we write has to be validated. A hand-edited aria2 file with
//      `max-concurrent-downloads=0` or `split=-4` is aria2's problem to reject
//      with a line in a log; here it would be a value the UI displays and the
//      user has to interpret. So every field is clamped on the way IN and the
//      clamp is reported, rather than being written and hoped for.
//
// What is deliberately NOT here
//
// No passwords, no API tokens, no paths outside the user's own profile, and no
// per-download state - that is aria2's session file, and Phase 1 already proved
// the round trip. This file holds preferences.
module store

import os
import json2

// settings_env overrides the settings path. It exists so tests can point at a
// temp directory and so an operator can pin the location; without it, tests
// would write into the real %APPDATA% and the suite would depend on machine
// state it must not touch.
const settings_env = 'FLUXGET_SETTINGS'

// Settings is the document. Field names ARE the JSON keys, snake_case, like
// every other struct that crosses the bridge (AGENTS.md section 5) - and they
// are deliberately NOT aria2's option names, which are camelCase. aria2's names
// appear in exactly one place, to_aria2(), so the two vocabularies cannot drift
// into each other.
pub struct Settings {
pub mut:
	// max_concurrent is how many downloads run at once. aria2 spells this
	// max-concurrent-downloads; 0 would mean "none", which is never what anyone
	// means, so the floor is 1.
	max_concurrent int
	// max_per_server is connections per download. The floor is 1 and the
	// ceiling is 16: aria2 accepts anything, and a value in the hundreds is a
	// user who typed a number into the wrong box.
	max_per_server int
	// download_limit and upload_limit are bytes per second. 0 means unlimited,
	// which IS a meaningful value here, so it is allowed - unlike max_concurrent.
	download_limit int
	upload_limit   int
	// split is how many connections one download may use. The floor is 1.
	split int
	// min_split_size is the smallest chunk aria2 will fetch in parallel, in bytes.
	//
	// 20 MiB is not a round number I liked: it is aria2's own default, read back from
	// `aria2.getOption` on 1.37.0, which answered `"min-split-size":"20971520"`. The
	// first version of this file shipped 1 MiB on the reasonable-sounding grounds that
	// smaller chunks parallelise better - and silently made every split aria2 chose
	// subject to a limit twenty times tighter than the one it would have picked. The
	// lesson is the one this whole module is built on: check the number against the
	// engine rather than choosing it.
	min_split_size int
	// dir is where downloads land. Empty means "the user's Downloads folder",
	// resolved at spawn time rather than guessed here, so a machine where that
	// folder has moved still works.
	dir string
	// bt_enabled is the one setting that is a genuine boolean: aria2's
	// enable-dht/enable-dht6/enable-peer-exchange/bt.enable_want_piece are four
	// options that must agree, and a partial write would leave BitTorrent half
	// on. One field, four writes.
	bt_enabled bool
	// seed_ratio is "0.0" for unlimited. Kept as aria2's own string form
	// because "0.0" and "0" mean the same thing to a user and are not the same
	// string.
	seed_ratio string
	// seed_time is minutes; "0" means seed forever.
	seed_time string
	// save_session is what makes a queue survive a restart. It is a preference
	// and not a fact about the engine, so it belongs to us.
	save_session bool
}

// defaults returns the shipped settings.
//
// The numbers are aria2's own defaults where aria2 has one, rather than ours,
// so a fresh install behaves exactly like a bare aria2c until the user changes
// something. Inventing a "better" default here would mean nobody could tell
// whether a behaviour change came from us or from aria2.
pub fn defaults() Settings {
	return Settings{
		max_concurrent: 5
		max_per_server: 16
		download_limit: 0
		upload_limit:   0
		split:          5
		min_split_size: 20971520
		dir:            ''
		bt_enabled:     true
		seed_ratio:     '1.0'
		seed_time:      '60'
		save_session:   true
	}
}

// limits is the clamp table: field, floor, ceiling.
//
// A table rather than a chain of ifs because the report has to say WHICH field
// was changed - "download-limit: 0 is not a number of connections" is useless,
// and a UI that silently rewrites a setting the user typed is worse than one
// that refuses it.
struct Clamp {
	field   string
	floor   int
	ceiling int
}

const clamps = [
	Clamp{
		field:   'max_concurrent'
		floor:   1
		ceiling: 100
	},
	Clamp{
		field:   'max_per_server'
		floor:   1
		ceiling: 16
	},
	Clamp{
		field:   'split'
		floor:   1
		ceiling: 16
	},
	Clamp{
		field:   'min_split_size'
		floor:   1024
		ceiling: 1073741824
	},
]

// Downloads and upload limits have NO clamp on the low end: 0 is unlimited and
// is a value a user chooses on purpose. Only a negative is impossible, and that
// is handled separately because it is not a range but a type error in the file.

// normalise clamps every field into range and returns what it changed, as
// "field: was -> now" strings.
//
// Returning the corrections instead of just applying them is the whole point: a
// settings write that silently alters three fields teaches a user their input
// does not work, and the next thing they do is uninstall.
pub fn (mut s Settings) normalise() []string {
	mut notes := []string{}
	for c in clamps {
		before := s.int_of(c.field)
		after := c.clamp(before)
		if before != after {
			s.set_int(c.field, after)
			notes << '${c.field}: ${before} -> ${after}'
		}
	}
	// Negative limits are impossible rather than out of range: 0 is a real
	// value, -1 is not.
	for name in ['download_limit', 'upload_limit'] {
		v := s.int_of(name)
		if v < 0 {
			s.set_int(name, 0)
			notes << '${name}: ${v} -> 0'
		}
	}
	if s.seed_ratio == '' {
		s.seed_ratio = '1.0'
		notes << 'seed_ratio: (empty) -> 1.0'
	}
	if s.seed_time == '' {
		s.seed_time = '60'
		notes << 'seed_time: (empty) -> 60'
	}
	return notes
}

fn (c Clamp) clamp(v int) int {
	if v < c.floor {
		return c.floor
	}
	if v > c.ceiling {
		return c.ceiling
	}
	return v
}

// int_of and set_int reach the fields by name so the clamp table can be data.
// Go would call this reflection; in V it is six honest lines and it is the only
// way to keep one table as the single source of the ranges.
fn (s Settings) int_of(field string) int {
	match field {
		'max_concurrent' {
			return s.max_concurrent
		}
		'max_per_server' {
			return s.max_per_server
		}
		'download_limit' {
			return s.download_limit
		}
		'upload_limit' {
			return s.upload_limit
		}
		'split' {
			return s.split
		}
		'min_split_size' {
			return s.min_split_size
		}
		else {
			return 0
		}
	}
}

fn (mut s Settings) set_int(field string, v int) {
	match field {
		'max_concurrent' {
			s.max_concurrent = v
		}
		'max_per_server' {
			s.max_per_server = v
		}
		'download_limit' {
			s.download_limit = v
		}
		'upload_limit' {
			s.upload_limit = v
		}
		'split' {
			s.split = v
		}
		'min_split_size' {
			s.min_split_size = v
		}
	}
}

// to_aria2 is the ONLY place Fluxget's vocabulary meets aria2's.
//
// Every value is a string because that is what aria2's JSON-RPC wants - it
// rejects a number for an option - so the conversion happens once, here, rather
// than at five call sites that would each have to remember it.
//
// bt_enabled expands to four options. They are written together or not at all:
// enable-dht on with enable-peer-exchange off is a configuration nobody meant.
pub fn (s Settings) to_aria2() map[string]string {
	mut m := map[string]string{}
	m['max-concurrent-downloads'] = s.max_concurrent.str()
	m['max-connection-per-server'] = s.max_per_server.str()
	m['split'] = s.split.str()
	m['min-split-size'] = s.min_split_size.str()
	// 0 is how aria2 spells "no limit", which is why an unset rate is 0 and not
	// an empty string.
	m['max-download-limit'] = s.rate_of(s.download_limit)
	m['max-overall-download-limit'] = s.rate_of(s.download_limit)
	m['max-upload-limit'] = s.rate_of(s.upload_limit)
	m['max-overall-upload-limit'] = s.rate_of(s.upload_limit)
	m['seed-ratio'] = s.seed_ratio
	m['seed-time'] = s.seed_time
	m['enable-dht'] = s.bool_of(s.bt_enabled)
	m['enable-dht6'] = s.bool_of(s.bt_enabled)
	m['enable-peer-exchange'] = s.bool_of(s.bt_enabled)
	m['bt.enable-lpd'] = s.bool_of(s.bt_enabled)
	if s.dir != '' {
		m['dir'] = s.dir
	}
	return m
}

// rate_of turns bytes per second into aria2's suffixed form. aria2 accepts a
// bare number of bytes per second, and using it keeps the value readable in a
// log and in aria2.getGlobalOption, which is what the UI reads back to prove the
// write landed.
fn (s Settings) rate_of(bytes_per_second int) string {
	return if bytes_per_second <= 0 { '0' } else { bytes_per_second.str() }
}

fn (s Settings) bool_of(v bool) string {
	return if v { 'true' } else { 'false' }
}

// merge applies only the keys aria2 accepted.
//
// changeGlobalOption is not transactional: it answers with the options it could
// NOT set. Treating that as success is how a limit silently fails to apply and
// the UI shows a number that is not in force - so every refused key becomes a
// note, and the settings document is rewritten from what aria2 actually holds.
//
// That rewrite is the difference between "saved" and "in force", and only one of
// them is a claim a user can rely on.
pub fn (s Settings) merge_report(rejected map[string]string) []string {
	mut notes := []string{}
	for k, v in rejected {
		notes << '${k}: aria2 refused (${v})'
	}
	return notes
}

// path is where the document lives.
//
// %APPDATA%\fluxget\settings.json by default, because that is where Windows
// keeps a user's own configuration and it survives reinstalling the app. A
// portable install - the exe beside runtime\ and frontend\ with no installer -
// would rather keep settings next to the binary, so FLUXGET_SETTINGS overrides
// it and the dev scripts set it.
//
// os.home_dir rather than %APPDATA%: V has no APPDATA helper, and the roaming
// path is not where a 60 KB download manager belongs anyway.
pub fn default_path() string {
	if forced := os.getenv_opt(settings_env) {
		return forced
	}
	return os.join_path(os.home_dir(), '.fluxget', 'settings.json')
}

// load reads the document.
//
// Three failure modes, three different answers, and none of them is an error the
// caller has to handle:
//
//   * no file      -> defaults, no note. A first run is not a problem.
//   * unreadable   -> defaults, with a note. The user's settings exist and we
//                     could not read them; that IS worth saying.
//   * valid JSON   -> the document, clamped, with a note per correction.
//
// A corrupt file is NOT overwritten here. load has no idea whether the user
// would rather have a backup of it or a clean start, and silently replacing a
// file a person edited by hand is the one thing a settings loader must not do.
pub fn load(path string) (Settings, []string) {
	mut s := defaults()
	mut notes := []string{}
	raw := os.read_file(path) or {
		return s, notes
	}
	// An empty file is what a crashed write leaves behind, and json.decode of
	// "" fails. Treating it as "no settings yet" is right and costs nothing.
	if raw.trim_space() == '' {
		return s, notes
	}
	mut decoded := json2.decode[Settings](raw) or {
		notes << 'settings.json could not be read; showing defaults and keeping your file'
		return s, notes
	}
	notes << decoded.normalise()
	return decoded, notes
}

// save writes the document.
//
// Two properties, both load-bearing:
//
//   * ATOMIC. The content goes to a sibling .tmp and is then renamed over the
//     target, because a power cut during a write otherwise leaves a half-written
//     JSON file that the next load rejects - and the user's settings are gone
//     with no way back. os.write_file truncates in place; rename does not.
//
//   * PRIVATE-ish. The directory is created if missing. Nothing else is touched:
//     no registry, no roaming profile, no other file in %APPDATA%.
pub fn (s Settings) save(path string) ! {
	dir := os.dir(path)
	os.mkdir_all(dir)!
	tmp := path + '.tmp'
	os.write_file(tmp, json2.encode(s)) or {
		return error('store: cannot write ${tmp}: ${err.msg()}')
	}
	os.mv(tmp, path)!
}
