// main_test.v - tests for the micro-packer.
//
// The packer is the only piece of Fluxget that silently produces a WRONG window
// instead of an error: every failure it is supposed to catch is a missing
// stylesheet in the production document, which looks like a layout bug rather
// than a build bug. So its two decisions - which tag to replace, and what to do
// with a `</script>` hiding in the JavaScript - are worth pinning.
//
// These are pure string functions. inline_one is only exercised on the path that
// does not touch the filesystem, because the other path calls exit(1) and a
// test that kills the runner is not a test.
module main

import os

// A document shaped like the real one, with extra attributes and an odd
// attribute order. The old packer built a needle from a regex-shaped string and
// then searched for it literally, so it matched nothing here and reported "0 of 6
// assets inlined" against a document that named all six.
fn doc() string {
	return '<html><head>' +
		'<link rel="stylesheet" href="css/tokens.css" />' +
		'<link href="css/app.css" media="all" rel="stylesheet">' +
		'<script defer src="js/boot.js"></script>' +
		'</head><body></body></html>'
}

// The span has to cover the WHOLE tag including the angle brackets, because that
// is what gets sliced away. A span that stopped before '>' would leave
// `<link rel="stylesheet" >` behind, which is invalid markup and looks fine in a
// diff.
fn test_locating_a_link_covers_the_whole_tag() {
	html := doc()
	start, stop := locate_tag(html, attr_for('css'), 'css/tokens.css') or {
		assert false, 'the link was not found'
		return
	}
	assert html[start..stop] == '<link rel="stylesheet" href="css/tokens.css" />', html[start..stop]
}

// This is the regression test for the bug that shipped: attributes after the
// href, and href before rel. A needle built from a fixed attribute order misses
// both, and the failure is silent.
fn test_locating_a_tag_does_not_care_which_attribute_comes_first() {
	html := doc()
	start, stop := locate_tag(html, attr_for('css'), 'css/app.css') or {
		assert false, 'the second link was not found'
		return
	}
	assert html[start..stop] == '<link href="css/app.css" media="all" rel="stylesheet">', html[start..stop]
}

// A script's span has to include its CLOSING tag as well. Replacing only the
// opening `<script src=...>` leaves a stray `</script>` sitting after the code
// that was just inlined: harmless to a parser, and precisely the sort of thing
// that survives review because it renders identically.
fn test_locating_a_script_covers_the_whole_element() {
	html := doc()
	start, stop := locate_tag(html, attr_for('js'), 'js/boot.js') or {
		assert false, 'the script was not found'
		return
	}
	assert html[start..stop] == '<script defer src="js/boot.js"></script>', html[start..stop]
}

// Not finding something is the normal case for the LAST asset already inlined, so
// it has to be an Option and not a panic or a zero-length slice.
fn test_locating_a_tag_that_is_absent_is_not_an_error() {
	assert locate_tag(doc(), 'href', 'css/nowhere.css') == none
	assert locate_tag('<html>', 'src', 'js/boot.js') == none
}

// A tag with no closing '>' is malformed, and returning a span that runs off the
// end of the document would panic on the slice in inline_one. Not returning
// anything turns it into "asset missing", which the count check then reports.
fn test_locating_an_unterminated_tag_returns_nothing_rather_than_overrunning() {
	assert locate_tag('<link rel="stylesheet" href="css/app.css"', 'href', 'css/app.css') == none
}

// An attribute value cannot contain an angle bracket, so the outward scan cannot
// run away - but only because the scan is bounded by the document. Prove it on a
// document with no '<' before the value at all.
fn test_locating_a_tag_at_the_very_start_of_a_document_is_bounded() {
	start, stop := locate_tag('<link href="a.css">', 'href', 'a.css') or {
		assert false, 'not found'
		return
	}
	assert start == 0, 'start ${start}'
	assert stop == 19, 'stop ${stop}'
}

fn test_the_attribute_depends_on_the_kind() {
	assert attr_for('css') == 'href'
	assert attr_for('js') == 'src'
}

// The one that is invisible until it matters: a literal "</script>" inside the
// JavaScript ends the element as far as the HTML parser is concerned, the rest of
// the file is parsed as markup, and the document still works right up until that
// point.
fn test_closing_script_tags_in_javascript_are_escaped() {
	got := escape_for_script('var s = "</script>";')
	assert got == 'var s = "<\\/script>";', got
	assert !got.contains('</script'), got
}

// The escape is deliberately BROADER than the HTML rule. "</scriptx" is not a
// tag end, so escaping it is unnecessary - but harmless, in a way that missing a
// real one would not be. The test records the real behaviour rather than the
// behaviour I assumed when writing it, because a test that asserts an
// implementation's wish is worse than no test.
fn test_a_near_miss_is_escaped_too_because_the_rule_is_coarse() {
	got := escape_for_script('if (a </scriptx) { }')
	assert got == 'if (a <\\/scriptx) { }', got
}

// The escape is only safe because the JavaScript parser treats "\/" inside a
// string literal as "/". V cannot demonstrate that - it has the same "a backslash
// needs escaping in a literal" property JS has, but its '\/' stays two
// characters - so asserting it here would be a test of V, not of the packer.
//
// What IS checkable, and what actually matters, is that the transformation inserts
// "\/" and touches NOTHING ELSE: no other character is rewritten, no other byte
// moves. That is the invariant a future "optimisation" of this function would
// break.
fn test_the_escape_only_inserts_a_backslash() {
	src := 'var s = "</script>"; var t = 1;'
	got := escape_for_script(src)
	// Undoing the inserted backslashes must give the original back, byte for byte.
	back := got.replace('<\\/script', '</script')
	assert back == src, back
	// And it must have changed exactly one thing: the length grew by one backslash.
	assert got.len == src.len + 1, '${got.len} vs ${src.len}'
}

// Every file gets inlined at least once, and any JavaScript comment mentioning
// </script> would have broken the build only on the day that comment was written.
fn test_a_comment_mentioning_a_closing_tag_is_escaped_too() {
	got := escape_for_script('// do not write </script> here')
	assert !got.contains('</script'), got
}

fn test_ordinary_javascript_is_untouched() {
	src := 'function f() { return "<div class=\\"x\\">"; }'
	assert escape_for_script(src) == src
}

// inline_one returns the document untouched when the tag is absent, which is the
// path it takes for the final asset in the list. That path must not touch the
// filesystem, and this is how that is proved without running a build.
fn test_inlining_an_absent_asset_leaves_the_document_alone() {
	html := doc()
	got := inline_one(html, Asset{
		kind: 'css'
		rel:  'css/not-here.css'
	}, '.')
	assert got == html
}

// ---- fonts ---------------------------------------------------------------

// The fonts are the reason the packer needs a step a stylesheet inliner normally
// would not: set_html gives the document no origin, so `url(../fonts/x.woff2)`
// resolves to nothing, and the failure is a SILENT fallback to the system face.
// A missing <script src> is a dead UI; a missing font looks fine and ships.

// write_fake_frontend lays a frontend/ tree out exactly as the real one is, so the
// path the packer resolves is the path the CSS actually uses: a stylesheet in css/
// reaches fonts/ with ../.
fn write_fake_frontend(root string) !string {
	frontend := os.join_path(root, 'frontend')
	os.mkdir_all(os.join_path(frontend, 'css'))!
	os.mkdir_all(os.join_path(frontend, 'fonts'))!
	// Four bytes that are recognisably not text, so a base64 of them is checkable.
	os.write_bytes(os.join_path(frontend, 'fonts', 'x.woff2'), [u8(0x77), 0x4f, 0x46, 0x32])!
	return frontend
}

const css_with_one_font = '@font-face { font-family: "X"; src: url("../fonts/x.woff2") format("woff2"); }'

fn scratch_dir(name string) string {
	d := os.join_path(os.temp_dir(), name)
	os.rmdir_all(d) or {}
	return d
}

fn test_a_font_url_becomes_a_data_uri() {
	frontend := write_fake_frontend(scratch_dir('fluxget-pack-fonts-a')) or {
		assert false, err.msg()
		return
	}
	got := inline_fonts(css_with_one_font, frontend, 'css/fonts.css')
	assert got.contains('url("data:font/woff2;base64,'), 'the url was not rewritten: ${got}'
	assert !got.contains('url("../fonts/'), 'a relative url survived: ${got}'
}

// Every quoting style a stylesheet actually uses, because the CSS that gets packed
// one day will not be the CSS I wrote today.
fn test_all_three_url_quotings_are_rewritten() {
	frontend := write_fake_frontend(scratch_dir('fluxget-pack-fonts-b')) or {
		assert false, err.msg()
		return
	}
	for quoted in ['url("../fonts/x.woff2")', "url('../fonts/x.woff2')", 'url(../fonts/x.woff2)'] {
		got := inline_fonts(quoted, frontend, 'css/fonts.css')
		assert got.contains('data:font/woff2'), '${quoted} was not rewritten: ${got}'
		assert !got.contains('../fonts/x.woff2'), '${quoted} left the original behind: ${got}'
	}
}

// A URL the packer has never seen is left exactly as it is. Guessing at one is how
// a build step starts breaking working documents.
fn test_urls_the_packer_does_not_own_are_left_alone() {
	frontend := write_fake_frontend(scratch_dir('fluxget-pack-fonts-c')) or {
		assert false, err.msg()
		return
	}
	for kept in [
		'url(data:font/woff2;base64,AAAA)',
		'url(#theGradient)',
		'url(https://example.com/x.woff2)',
		'url(../fonts/missing.woff2)',
	] {
		got := inline_fonts(kept, frontend, 'css/fonts.css')
		assert got == kept, '${kept} was changed to ${got}'
	}
}

// The relative path is from the CSS file's own directory, which is how fonts.css in
// css/ reaches fonts/. Resolving from the frontend root instead would make every
// font reference a miss, and every miss is silent.
fn test_the_path_is_resolved_from_the_css_files_own_directory() {
	frontend := write_fake_frontend(scratch_dir('fluxget-pack-fonts-d')) or {
		assert false, err.msg()
		return
	}
	got := inline_fonts('url("fonts/x.woff2")', frontend, 'x.css')
	assert got.contains('data:font/woff2'), 'a stylesheet at the root should reach fonts/ directly: ${got}'
}

fn test_the_mime_type_follows_the_extension() {
	frontend := write_fake_frontend(scratch_dir('fluxget-pack-fonts-e')) or {
		assert false, err.msg()
		return
	}
	os.write_bytes(os.join_path(frontend, 'fonts', 'x.ttf'), [u8(1), 2, 3])!
	for pair in [['.woff2', 'font/woff2'], ['.ttf', 'font/ttf']] {
		got := inline_fonts('url("../fonts/x${pair[0]}")', frontend, 'css/fonts.css')
		assert got.contains('data:${pair[1]};base64,'), 'wrong mime for ${pair[0]}: ${got}'
	}
}
