// locate.v - finding aria2c, in an order a user can predict.
//
// aria2c is GPL, so it is never committed (see .gitignore and
// scripts/fetch-aria2.ps1). It can therefore be in four places, and "which one
// did the app pick?" is a question the Setup screen has to answer exactly,
// because the user's next move depends on it: install it, or point at it.
//
// The order is:
//
//   1. beside the executable   - a portable install, e.g. aria2c next to fluxget.exe
//   2. <root>/runtime/         - what scripts/fetch-aria2.ps1 unpacks
//   3. PATH                    - a system or package-manager install
//   4. the path in Settings    - a hand-picked build
//
// Settings is LAST on purpose, and this is the one part of the order worth
// arguing about. The intuitive rule is "an explicit user choice wins", but the
// explicit path is also the one that goes stale: a user who typed a path before
// installing aria2 would be left with a broken app by an override, and the only
// way to fix it is Settings, which is the page they are trying to reach. As
// long as a working engine exists, we use it. When Settings becomes a real
// feature (Phase 3, store/) it gets an explicit "use this path" toggle, and the
// question stops being implicit.
//
// Two properties the rest of the app depends on:
//
//   * No side effects. Nothing here creates, writes or runs anything, so it is
//     safe to call from a probe and from a test.
//   * The ORDER is computed separately from the filesystem probe
//     (candidates vs find). That split is what makes the search order testable
//     on a machine where aria2c exists nowhere, which is most CI machines and
//     was this one until scripts/fetch-aria2.ps1 ran.
//
// V note: os has no find_executable() and no which(), so the PATH walk is ours.
// Splitting the PATH string is pure and therefore tested directly.
module aria2ctl

import os

// The four sources, in the vocabulary the Setup page and the health payload
// use. Constants rather than bare strings so a typo is a compile error.
pub const source_beside = 'beside-exe'
pub const source_runtime = 'runtime'
pub const source_path = 'path'
pub const source_settings = 'settings'

// runtime_dir is where scripts/fetch-aria2.ps1 puts the binary, relative to the
// project root.
pub const runtime_dir = 'runtime'

// binary_name is the executable's file name on this platform. `.exe` is not
// something to be clever about: on Windows the file without the extension is a
// different file, and a portable install is expected to ship aria2c.exe.
pub fn binary_name() string {
	$if windows {
		return 'aria2c.exe'
	} $else {
		return 'aria2c'
	}
}

// path_separator is what splits PATH on this platform. A compile-time constant
// rather than a runtime read because it never varies within a process, and the
// alternative (os.get_path_separator) would be one more thing to test.
pub fn path_separator() string {
	$if windows {
		return ';'
	} $else {
		return ':'
	}
}

// Candidate is one place aria2c might be, and which rule put it there.
pub struct Candidate {
pub:
	// path is the absolute (or PATH-relative) file to probe.
	path string
	// source is one of the source_* constants.
	source string
}

// Result is the outcome of a search.
//
// A missing binary is a *result*, not an error and not an empty string: the UI
// has to distinguish "aria2c is not installed" from "aria2c is there but
// broken", and it can only do that from what is reported here.
pub struct Result {
pub:
	// found is the only question a caller has to branch on.
	found bool
	// path is the chosen executable; empty when nothing was found.
	path string
	// source is where it came from, for the Setup page to name.
	source string
	// searched is every path tried, in order, so the Setup page can show the
	// full list instead of a shrug.
	searched []string
	// hint is one sentence the Setup page can show verbatim. It is a sentence
	// rather than a code because the only reader is a human, and because a
	// machine-readable reason would be a second vocabulary to keep in step.
	hint string
}

// Search describes where to look.
//
// A struct rather than four positional strings: four same-typed arguments get
// swapped silently, and `candidates(exe_dir, root, settings_path, path_env)`
// would then probe PATH last while every comment in the file claimed it was
// third. The compiler catches a type error here; it cannot catch a swap.
pub struct Search {
pub mut:
	// exe_dir is the directory holding fluxget.exe. Empty skips rule 1.
	exe_dir string
	// root is the project root; rule 2 looks in <root>/runtime. Empty skips it.
	root string
	// path_env is a PATH environment value, not a resolved path list, so a test
	// can drive rule 3 without touching the machine's environment.
	path_env string
	// settings_path is the user's hand-picked executable. Empty skips rule 4.
	settings_path string
}

// search_from_env fills everything except the three paths from the live
// environment. The one impure step of the search, and it is a read.
pub fn search_from_env(exe_dir string, root string, settings_path string) Search {
	return Search{
		exe_dir:       exe_dir
		root:          root
		path_env:      os.getenv('PATH')
		settings_path: settings_path
	}
}

// candidates builds the ordered search list. Pure: no filesystem access, so the
// order is a testable value rather than an emergent property of a probe loop.
pub fn candidates(s Search) []Candidate {
	mut out := []Candidate{cap: 16}
	bin := binary_name()

	// 1. Beside the executable. A portable install keeps app and engine
	// together, and this is the only rule that works from a USB stick.
	if s.exe_dir != '' {
		out << Candidate{
			path:   os.join_path(s.exe_dir, bin)
			source: source_beside
		}
	}

	// 2. The vendored runtime/ directory: what fetch-aria2.ps1 unpacks, and
	// what a git clone gets after one documented command.
	if s.root != '' {
		out << Candidate{
			path:   os.join_path(s.root, runtime_dir, bin)
			source: source_runtime
		}
	}

	// 3. PATH, from the value the caller supplied rather than a cached one, so
	// a Settings change cannot go stale within a session.
	for dir in path_dirs(s.path_env) {
		out << Candidate{
			path:   os.join_path(dir, bin)
			source: source_path
		}
	}

	// 4. Settings, last. See the header for why an explicit user path is not
	// allowed to override a working engine.
	if s.settings_path != '' {
		out << Candidate{
			path:   s.settings_path
			source: source_settings
		}
	}
	return out
}

// find runs the search. The only impure function in this file: `exists` is
// injected so the *policy* above is testable without touching a disk, and the
// policy is the part that can be wrong.
pub fn find(cands []Candidate, exists fn (path string) bool) Result {
	mut searched := []string{cap: cands.len}
	for c in cands {
		searched << c.path
		if !exists(c.path) {
			continue
		}
		return Result{
			found:    true
			path:     c.path
			source:   c.source
			searched: searched
		}
	}
	return Result{
		found:    false
		searched: searched
		hint:     not_found_hint(searched)
	}
}

// find_on_disk is find with the real filesystem predicate. Split out so the
// policy stays free of `os`, and so a test never has to fake a directory.
pub fn find_on_disk(cands []Candidate) Result {
	return find(cands, os.exists)
}

// locate is the whole thing: build the candidates for this process and probe
// them. This is the call a handler makes; everything above it is testable.
pub fn locate(s Search) Result {
	return find_on_disk(candidates(s))
}

// path_dirs splits a PATH environment value into directories.
//
// Three details that are all real bugs otherwise:
//
//   * Windows PATH entries are frequently quoted (`"C:\Program Files\..."`),
//     and the quotes have to come off or the probe tests a path that does not
//     exist.
//   * Empty entries are skipped. An empty entry in PATH means "the current
//     directory" to the Windows loader, which would turn a PATH probe into a
//     probe of wherever the app happens to be running from.
//   * The separator is platform-specific: `;` on Windows, `:` everywhere else.
//     On Windows a drive letter's own colon is not a separator, which is one
//     more reason this cannot be a naive split on ':'.
pub fn path_dirs(path_env string) []string {
	mut out := []string{}
	if path_env == '' {
		return out
	}
	separator := path_separator()
	for raw in path_env.split(separator) {
		d := unquote_trim(raw)
		if d == '' {
			continue
		}
		out << d
	}
	return out
}

// unquote_trim removes the whitespace and the double quotes that can surround a
// PATH entry.
//
// Hand-rolled because V 0.5.2's string.trim_space() takes no cutset and there is
// no trim(cutset) to reach for. The set stripped is exactly the characters that
// can surround a PATH entry and change what it means: space, tab, and one pair
// of quotes.
//
// Only one pair of quotes, and only when they are both present at the two ends.
// A Windows path may legitimately *contain* a quote-free backslash run, and a
// path that merely starts with a quote is not a quoted path.
fn unquote_trim(s string) string {
	mut out := s.trim_space()
	if out.len >= 2 && out.starts_with('"') && out.ends_with('"') {
		out = out[1..out.len - 1].trim_space()
	}
	return out
}

// not_found_hint is the sentence the Setup page shows. It names the fetch
// script because that is the action that actually resolves it, and it never
// claims the list is exhaustive beyond what was really probed.
fn not_found_hint(searched []string) string {
	mut h := 'aria2c was not found in ' + searched.len.str() +
		' location(s). Run .\\scripts\\fetch-aria2.ps1, or set a custom path in Settings.'
	return h
}
