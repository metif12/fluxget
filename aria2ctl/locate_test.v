// locate_test.v - the search order, tested on a machine with no aria2c.
//
// Every test here drives `candidates` with a Search struct the test fills in, so
// none of them touch the disk, the environment, or the network. That is the
// point of splitting the policy (candidates) from the probe (find): the policy
// is the part that can be wrong, and it is now a value instead of a side effect.
module aria2ctl

import os

// pathsep is the platform PATH separator, so the fixtures read the same on every
// OS without a $if in the middle of a test.
//
// A function, not a const: this file is compiled INTO module aria2ctl, not
// alongside it, so every top-level name here shares a namespace with locate.v.
// A top-level `const sep` in this file collided with a local `sep` in path_dirs,
// and V only warned ("duplicate of a const name") before failing on something
// unrelated. Test-file top-level names have to be chosen as carefully as the
// module's own.
fn pathsep() string {
	return path_separator()
}

// exists_in reports whether a path is in the fake filesystem. `os.exists` is
// NOT used: a test that passes because the machine happens to have something
// installed is worse than no test.
fn exists_in(have []string) fn (path string) bool {
	return fn [have] (path string) bool {
		return path in have
	}
}

fn test_the_search_order_is_exe_then_runtime_then_path_then_settings() {
	// The order IS the feature. A reorder here is a behaviour change, so it is
	// asserted positionally rather than by "contains".
	c := candidates(Search{
		exe_dir:       'C:\\fluxget'
		root:          'C:\\fluxget'
		path_env:      'C:\\tools' + pathsep() + 'C:\\bin'
		settings_path: 'D:\\aria2\\aria2c.exe'
	})
	assert c.len == 5, 'got ${c.len} candidates'
	assert c[0].source == source_beside
	assert c[0].path == os.join_path('C:\\fluxget', binary_name())
	assert c[1].source == source_runtime
	assert c[1].path == os.join_path('C:\\fluxget', 'runtime', binary_name())
	assert c[2].source == source_path
	assert c[2].path == os.join_path('C:\\tools', binary_name())
	assert c[3].source == source_path
	assert c[4].source == source_settings
	assert c[4].path == 'D:\\aria2\\aria2c.exe'
}

fn test_a_custom_path_is_a_fallback_and_not_an_override() {
	// The decision worth defending: a user who typed a path before installing
	// aria2 must still get a working app from runtime/. If this ever flips, the
	// only way out of a broken custom path is the very page that is broken.
	c := candidates(Search{
		exe_dir:       '/opt/fluxget'
		root:          '/opt/fluxget'
		path_env:      ''
		settings_path: '/elsewhere/aria2c'
	})
	vendored := os.join_path('/opt/fluxget', 'runtime', binary_name())
	res := find(c, exists_in([vendored]))
	assert res.found
	assert res.path == vendored, 'runtime/ must win over a custom path: got ${res.path}'
	assert res.source == source_runtime
}

fn test_the_first_hit_wins_and_reports_its_source() {
	c := candidates(Search{
		exe_dir:  '/opt/fluxget'
		root:     '/opt/fluxget'
		path_env: '/usr/bin' + pathsep() + '/usr/local/bin'
	})
	// Two hits: the portable one and a PATH one. The earlier rule must win even
	// though the PATH hit is "more official".
	beside := os.join_path('/opt/fluxget', binary_name())
	from_path := os.join_path('/usr/local/bin', binary_name())
	res := find(c, exists_in([from_path, beside]))
	assert res.found
	assert res.path == beside, 'got ${res.path}'
	assert res.source == source_beside
}

fn test_a_searched_list_names_every_place_we_looked() {
	// The Setup page shows this list, so a user can see that the app really did
	// look in runtime/ rather than guessing.
	c := candidates(Search{
		exe_dir:  '/opt/fluxget'
		root:     '/opt/fluxget'
		path_env: '/usr/bin'
	})
	res := find(c, exists_in([]))
	assert !res.found
	assert res.path == '', 'a miss must not invent a path'
	assert res.source == ''
	assert res.searched.len == c.len, 'tried ${res.searched.len} of ${c.len}'
	assert res.searched[1].contains('runtime')
	assert res.hint.contains('fetch-aria2.ps1'), 'the hint has to name the fix: ${res.hint}'
}

fn test_an_empty_search_is_a_clean_miss_rather_than_an_error() {
	// Every argument empty is the shape of "the app is misconfigured", and it
	// still has to produce something the Setup page can render.
	res := find(candidates(Search{}), exists_in([]))
	assert !res.found
	assert res.searched.len == 0
	assert res.hint != '', 'a miss always explains itself'
}

fn test_path_dirs_strips_quotes_and_skips_empty_entries() {
	// Both details are bugs otherwise:
	//   * `"C:\Program Files\aria2"` keeps its quotes and probes a path that
	//     does not exist, so a perfectly good install goes unnoticed;
	//   * an empty entry means "the current directory" to the Windows loader,
	//     so keeping it turns a PATH probe into a probe of the cwd.
	got := path_dirs('  "C:\\Program Files\\aria2"  ' + pathsep() + pathsep() + 'C:\\bin' + pathsep())
	assert got.len == 2, 'got ${got}'
	assert got[0] == 'C:\\Program Files\\aria2'
	assert got[1] == 'C:\\bin'
}

fn test_path_dirs_of_nothing_is_nothing() {
	assert path_dirs('').len == 0
	assert path_dirs(pathsep()).len == 0
	assert path_dirs(pathsep() + pathsep()).len == 0
}

fn test_the_binary_name_is_the_one_the_platform_actually_looks_for() {
	$if windows {
		assert binary_name() == 'aria2c.exe'
		assert pathsep() == ';'
	} $else {
		assert binary_name() == 'aria2c'
		assert pathsep() == ':'
	}
}

fn test_the_source_names_are_the_words_the_setup_page_uses() {
	// These strings cross the bridge in the health payload, so a rename is a
	// wire change and not a local cleanup. Pinning them here makes that visible.
	assert source_beside == 'beside-exe'
	assert source_runtime == 'runtime'
	assert source_path == 'path'
	assert source_settings == 'settings'
	assert runtime_dir == 'runtime', 'scripts/fetch-aria2.ps1 unpacks into this'
}
