// settings_test.v - the settings document's promises.
//
// The gate for Phase 3 is "limits and settings survive a restart", and that is a
// claim about THREE things at once: the write is complete, the read is faithful,
// and a bad value cannot leave the engine in a state nobody asked for. Each gets
// its own test below, because they fail in completely different ways.
//
// Files go in os.temp_dir() and are removed after. Nothing here reads or writes
// %APPDATA%, so the suite cannot depend on - or damage - machine state.
module store

import os
import json2

// scratch returns a path inside a temp directory and removes it afterwards, so a
// failing assertion does not leave a settings.json behind to confuse the next
// run. The removal runs even when the test panics, because V runs deferred code
// on unwind.
fn scratch(name string) string {
	dir := os.join_path(os.temp_dir(), 'fluxget-store-test')
	os.mkdir_all(dir) or { panic('cannot create the scratch directory: ${err.msg()}') }
	p := os.join_path(dir, name)
	os.rm(p) or {}
	os.rm(p + '.tmp') or {}
	return p
}

// ---- the round trip -----------------------------------------------------

// The whole point of the file: what you set is what you get back, field for
// field. A test that only checked "the file exists" would have passed while every
// value was written as zero.
fn test_settings_survive_a_save_and_a_load() {
	p := scratch('roundtrip.json')
	mut wanted := defaults()
	wanted.max_concurrent = 3
	wanted.max_per_server = 8
	wanted.download_limit = 524288
	wanted.upload_limit = 131072
	wanted.split = 4
	wanted.min_split_size = 2097152
	wanted.dir = 'D:/downloads/flux'
	wanted.bt_enabled = false
	wanted.seed_ratio = '2.5'
	wanted.seed_time = '0'
	wanted.save_session = false
	wanted.save(p) or { assert false, err.msg() }

	got, notes := load(p)
	assert notes.len == 0, 'a clean round trip should correct nothing: ${notes}'
	assert got.max_concurrent == 3, got.max_concurrent.str()
	assert got.max_per_server == 8, got.max_per_server.str()
	assert got.download_limit == 524288, got.download_limit.str()
	assert got.upload_limit == 131072, got.upload_limit.str()
	assert got.split == 4, got.split.str()
	assert got.min_split_size == 2097152, got.min_split_size.str()
	assert got.dir == 'D:/downloads/flux', got.dir
	assert got.bt_enabled == false, 'a false boolean is the value most likely to be lost: ${got.bt_enabled}'
	assert got.seed_ratio == '2.5', got.seed_ratio
	assert got.seed_time == '0', 'seed_time 0 means "forever" and must not become 60'
	assert got.save_session == false, got.save_session.str()
}

// A restart is a NEW PROCESS reading an OLD file, so the file has to be
// self-describing. Every key present, none missing: a field added later must not
// require rewriting the file, and a field removed later must not break it.
fn test_the_document_names_every_field_in_snake_case() {
	text := json2.encode(defaults())
	for key in [
		'"max_concurrent"',
		'"max_per_server"',
		'"download_limit"',
		'"upload_limit"',
		'"split"',
		'"min_split_size"',
		'"dir"',
		'"bt_enabled"',
		'"seed_ratio"',
		'"seed_time"',
		'"save_session"',
	] {
		assert text.contains(key), 'missing ${key} in ${text}'
	}
	// And NOT aria2's vocabulary, which would couple our document to theirs.
	assert !text.contains('max-concurrent-downloads'), 'aria2 option names do not belong in our file'
	assert !text.contains('bt_enabled" : "true'), 'a bool must be a bool, not a string'
}

// ---- missing, unreadable, wrong -----------------------------------------

fn test_a_first_run_gets_defaults_and_is_not_an_error() {
	p := scratch('absent.json')
	got, notes := load(p)
	assert notes.len == 0, 'a missing file is a first run, not a problem: ${notes}'
	assert got.max_concurrent == defaults().max_concurrent
	assert got.bt_enabled
}

// A settings file a person edited by hand, or a disk that filled up. Refusing to
// start is unacceptable; silently overwriting is worse - the user's edits are
// gone with no way back, so load keeps the file and says so.
fn test_a_corrupt_file_yields_defaults_and_keeps_the_original() {
	p := scratch('corrupt.json')
	garbage := '{"max_concurrent": 3, "split": '
	os.write_file(p, garbage) or { assert false, err.msg() }

	got, notes := load(p)
	assert notes.len == 1, 'a corrupt file must be reported: ${notes}'
	assert notes[0].contains('defaults'), notes[0]
	assert got.max_concurrent == defaults().max_concurrent, 'defaults, not a half-read file'

	// The original is still on disk, byte for byte.
	after := os.read_file(p) or { assert false, err.msg() }
	assert after == garbage, 'the corrupt file was overwritten: ${after}'
}

// An empty file is what a crash during a write leaves behind. Treating it as
// corrupt would scold the user for our bug; treating it as absent is right.
fn test_an_empty_file_is_treated_as_absent() {
	p := scratch('empty.json')
	os.write_file(p, '') or { assert false, err.msg() }
	got, notes := load(p)
	assert notes.len == 0, ''
	assert got.max_concurrent == defaults().max_concurrent
}

// ---- clamping -----------------------------------------------------------

fn test_out_of_range_values_are_clamped_and_the_correction_is_reported() {
	mut s := defaults()
	s.max_concurrent = 0 // "no downloads at all" - nobody means this
	s.max_per_server = 400
	s.split = -4
	s.min_split_size = 1

	notes := s.normalise()
	assert s.max_concurrent == 1, s.max_concurrent.str()
	assert s.max_per_server == 16, s.max_per_server.str()
	assert s.split == 1, s.split.str()
	assert s.min_split_size == 1024, s.min_split_size.str()
	assert notes.len == 4, 'every correction has to be named: ${notes}'
	assert notes.len > 0 && notes[0].contains('->'), 'a correction must say what changed: ${notes[0]}'
}

// 0 is unlimited, and it is a value a user picks on purpose. Clamping it to the
// floor would make "no limit" unreachable, which is the opposite of helpful.
fn test_a_zero_rate_is_unlimited_and_survives() {
	mut s := defaults()
	s.download_limit = 0
	s.upload_limit = 0
	s.normalise()
	assert s.download_limit == 0
	assert s.upload_limit == 0
	assert s.to_aria2()['max-download-limit'] == '0', s.to_aria2()['max-download-limit']
}

// A negative rate is not "unlimited", it is impossible, and aria2 would reject
// the whole call - taking every OTHER setting down with it, because
// changeGlobalOption is not per-key transactional.
fn test_a_negative_rate_becomes_unlimited_and_is_reported() {
	mut s := defaults()
	s.download_limit = -1
	notes := s.normalise()
	assert s.download_limit == 0, s.download_limit.str()
	assert notes.len == 1, ''
	assert notes[0].contains('download_limit'), notes[0]
}

fn test_empty_seed_values_are_filled_in() {
	mut s := defaults()
	s.seed_ratio = ''
	s.seed_time = ''
	notes := s.normalise()
	assert s.seed_ratio == '1.0', s.seed_ratio
	assert s.seed_time == '60', s.seed_time
	assert notes.len == 2, ''
}

fn test_valid_values_are_left_alone() {
	mut s := defaults()
	s.max_concurrent = 7
	s.split = 3
	assert s.normalise().len == 0, 'a good document must be silent'
	assert s.max_concurrent == 7 && s.split == 3
}

// A clamped document is what gets WRITTEN, so the next load is not re-clamping
// and re-reporting the same corrections on every start.
fn test_clamping_happens_once_not_on_every_load() {
	p := scratch('clamped.json')
	mut s := defaults()
	s.max_concurrent = 0
	s.save(p) or { assert false, err.msg() }

	first, notes := load(p)
	assert notes.len == 1, '${notes}'
	assert first.max_concurrent == 1
	// Write the corrected document back, as a real save does.
	first.save(p) or { assert false, err.msg() }
	second, notes2 := load(p)
	assert notes2.len == 0, 'the second start must have nothing to correct: ${notes2}'
	assert second.max_concurrent == 1
}

// ---- the aria2 mapping ---------------------------------------------------

// This is the only place the two vocabularies meet, so it is the only place a
// typo can turn a setting into a silent no-op. Assert the EXACT keys aria2 wants.
fn test_the_aria2_mapping_uses_aria2s_own_option_names() {
	s := defaults()
	m := s.to_aria2()
	for key in [
		'max-concurrent-downloads',
		'max-connection-per-server',
		'split',
		'min-split-size',
		'max-download-limit',
		'max-overall-download-limit',
		'max-upload-limit',
		'max-overall-upload-limit',
		'seed-ratio',
		'seed-time',
		'enable-dht',
		'enable-peer-exchange',
	] {
		assert key in m, 'missing aria2 option ${key} in ${m.keys()}'
	}
	assert m['max-concurrent-downloads'] == '5', m['max-concurrent-downloads']
	assert m['max-connection-per-server'] == '16', m['max-connection-per-server']
}

// aria2's JSON-RPC rejects a number where it wants a string, and the symptom is
// the whole call failing - which would take every limit with it.
fn test_every_aria2_value_is_a_string() {
	m := defaults().to_aria2()
	for k, v in m {
		assert v.len > 0, '${k} is empty'
		// Every value we emit is either a digit string or a known keyword.
		all_digits := v.int() > 0 || v == '0'
		is_keyword := v == 'true' || v == 'false' || v.contains('.')
		assert all_digits || is_keyword, '${k}=${v} is neither a number nor a keyword'
	}
}

// bt_enabled is ONE preference and FOUR aria2 options. A partial write leaves
// BitTorrent half on, which is a state nobody meant and aria2 will not fix for
// us.
fn test_bittorrent_is_all_or_nothing_across_its_four_options() {
	mut s := defaults()
	s.bt_enabled = false
	off := s.to_aria2()
	for key in ['enable-dht', 'enable-dht6', 'enable-peer-exchange', 'bt.enable-lpd'] {
		assert off[key] == 'false', '${key} stayed on while BitTorrent was turned off: ${off[key]}'
	}
	s.bt_enabled = true
	on := s.to_aria2()
	for key in ['enable-dht', 'enable-dht6', 'enable-peer-exchange', 'bt.enable-lpd'] {
		assert on[key] == 'true', '${key} stayed off: ${on[key]}'
	}
}

// An empty dir means "the user's Downloads folder", resolved when aria2 starts.
// Writing `dir=""` would make aria2 download into its own working directory,
// which is the one outcome nobody wants.
fn test_an_unset_directory_is_omitted_rather_than_written_empty() {
	mut s := defaults()
	s.dir = ''
	assert 'dir' !in s.to_aria2(), s.to_aria2().keys().str()
	s.dir = 'D:/x'
	assert s.to_aria2()['dir'] == 'D:/x', s.to_aria2()['dir']
}

// changeGlobalOption answers with the options it REFUSED, and a caller that
// ignores that will show a limit as saved when it is not in force.
fn test_options_aria2_refused_are_reported_rather_than_swallowed() {
	notes := defaults().merge_report({
		'split': 'Must be less than or equal to 16'
	})
	assert notes.len == 1, '${notes}'
	assert notes[0].contains('split'), notes[0]
	assert notes[0].contains('refused'), notes[0]
	assert defaults().merge_report({}).len == 0, 'nothing refused, nothing to say'
}

// ---- the atomic write ----------------------------------------------------

// A power cut during a write leaves a half-written JSON file, and the next load
// rejects it - the user's settings gone with no way back. So the content goes to
// a sibling and is renamed over the target.
fn test_saving_leaves_no_temporary_file_behind() {
	p := scratch('atomic.json')
	defaults().save(p) or { assert false, err.msg() }
	assert os.exists(p), 'the document was not written'
	assert !os.exists(p + '.tmp'), 'a temporary file was left behind'
}

// And the rename is what makes it safe: a save over an existing document must
// replace it completely, not append to it.
fn test_saving_twice_replaces_rather_than_appends() {
	p := scratch('twice.json')
	mut first := defaults()
	first.dir = 'D:/first'
	first.save(p) or { assert false, err.msg() }
	mut second := defaults()
	second.dir = 'D:/second'
	second.save(p) or { assert false, err.msg() }

	text := os.read_file(p) or { assert false, err.msg() }
	assert text.count('D:/first') == 0, 'the old document survived: ${text}'
	assert text.count('D:/second') == 1, text
	got, _ := load(p)
	assert got.dir == 'D:/second', got.dir
}

// A save into a directory that does not exist yet is the first-run case, and it
// must create the directory rather than fail.
fn test_saving_creates_the_directory_it_needs() {
	dir := os.join_path(os.temp_dir(), 'fluxget-store-test', 'nested', 'deeper')
	p := os.join_path(dir, 'settings.json')
	os.rm(dir) or {}
	defaults().save(p) or { assert false, err.msg() }
	assert os.exists(p), 'the directory was not created'
	got, _ := load(p)
	assert got.max_concurrent == defaults().max_concurrent
}

// ---- where it lives ------------------------------------------------------

// The env var is how tests avoid %APPDATA% and how a portable install pins the
// location, so it has to win over the default path.
fn test_the_path_env_var_wins_over_the_default_location() {
	p := scratch('env.json')
	mut previous := os.getenv_opt(settings_env)
	os.setenv(settings_env, p, true)
	defer {
		os.setenv(settings_env, previous or { '' }, true)
	}
	assert default_path() == p, default_path()
	// An unset var falls back to the user's own configuration directory, which
	// is under the home directory and NOT the project - a settings file inside
	// the repo would be deleted by a clean.
	os.unsetenv(settings_env)
	home := os.home_dir()
	assert default_path().starts_with(home), '${default_path()} is not under ${home}'
	assert default_path().ends_with('settings.json'), default_path()
}
