// pack.v — the micro-packer: frontend/** into ONE index.html.
//
// Why this exists
//
// `webview_set_html` gives the document no real origin, so a relative
// <script src="js/boot.js"> cannot load in the production build. The window
// would be blank, and a blank window is the least explicable failure a desktop
// app has. So the production document has to be self-contained: every stylesheet
// and script inlined into one file that goes in through `html:`.
//
// In dev nothing is packed — the vails dev server serves frontend/ as real files
// so livereload works and a CSS edit is one refresh away. That is why the build
// warns when this file is absent rather than failing: the dev loop must never
// depend on the packer.
//
// Deliberately not a bundler
//
// No minification, no hashing, no dependency graph, no module resolution. Inlining
// a fixed list of files that index.html names is the whole job, and anything more
// would be a build step that can break in ways the dev loop never exercises.
//
// CSP
//
// The framework injects `script-src 'self' 'unsafe-inline'; style-src 'self'
// 'unsafe-inline'`, so an inlined <script> and <style> are both allowed. A
// webview with a stricter policy would need a nonce, and that is the one thing
// this packer would have to grow.
module main

import os

// rel_root is where the frontend lives, relative to the working directory.
const rel_root = 'frontend'

// out_rel is where the packed document goes. scripts/build.ps1 and
// platform/host.v's find_packed() agree on this path.
const out_rel = 'build/web/index.html'

// Asset is one inlinable file and how it is embedded.
//
// The capital A is V's rule, not a style choice: a private struct with a
// lower-case name is rejected outright in 0.5.2.
struct Asset {
	// kind is 'css' or 'js', which decides the element written.
	kind string
	// rel is the href/src as index.html spells it, e.g. 'css/tokens.css'.
	rel string
}

// locate_tag finds the element in html that references rel through attr, and
// returns its start index and length INCLUDING the angle brackets.
//
// Why not a regular expression
//
// The obvious spelling is `<link[^>]*href="css/app.css"[^>]*>`, and the first
// version of this file used exactly that - then looked for it with
// `String.index`, which is a plain substring search and never matches a pattern.
// The result was a packer that reported "0 of 6 assets inlined" for a document
// that named all six, and no amount of staring at the HTML would have shown why.
//
// So this scans instead, and it does not need to: the job is to find the attribute
// VALUE, which is exact, and then walk outwards to the enclosing tag. An
// attribute value cannot contain '<' or '>', so the two scans are bounded by the
// document and cannot run away.
//
// A regex would only be needed to tolerate an unquoted attribute, which is not
// HTML anyone writes.
fn locate_tag(html string, attr string, rel string) ?(int, int) {
	value := attr + '="' + rel + '"'
	at := html.index(value) or { return none }

	// Walk back to the '<' that opens the tag, starting from the attribute VALUE
	// and decrementing BEFORE testing, so `start` ends on the bracket itself.
	// Two things are easy to get wrong here and both are silent: seeding `start`
	// at 0 instead of at `at` (the loop then never runs and every lookup misses),
	// and testing before decrementing (which leaves `start` one character too far
	// right and the slice begins mid-tag, dropping the '<').
	mut start := at
	mut found := false
	for start > 0 {
		start--
		if html[start] == `<` {
			found = true
			break
		}
	}
	if !found {
		return none
	}

	// And forward to the '>' that closes it.
	mut stop := at + value.len
	for stop < html.len && html[stop] != `>` {
		stop++
	}
	if stop >= html.len {
		return none
	}
	stop++

	// For a SCRIPT, the closing tag belongs to the span too. Replacing only the
	// opening `<script src=...>` would leave a stray `</script>` behind the code
	// that was just inlined - harmless to a parser, and exactly the sort of thing
	// that survives review because it renders identically. A stylesheet has no
	// closing tag, so this only fires where there is one.
	if stop + 8 <= html.len && html[stop..stop + 8] == '</script' {
		mut close_end := stop + 8
		for close_end < html.len && html[close_end] != `>` {
			close_end++
		}
		if close_end < html.len {
			stop = close_end + 1
		}
	}
	return start, stop
}

// escape_for_script protects inlined JavaScript from ending the tag early.
//
// A literal "</script>" anywhere in the JS - inside a string, a comment, a regex -
// terminates the <script> element as far as the HTML parser is concerned, and the
// rest of the file is then parsed as markup. The document still loads and still
// works right up until that point and then breaks, which is the worst shape of
// bug to ship. The JS parser treats "\/" inside a string literal as "/", so this
// substitution is invisible to the code and invisible to the parser.
//
// It replaces every "</script", including "</scriptx", which the HTML spec does
// NOT treat as a tag end. That is deliberate and it is asymmetric on purpose: the
// cost of escaping one is zero (a backslash in a string, a comment or a regex
// literal, all of which cannot contain a bare "\/"), and the cost of missing a
// real one is a document that silently stops being JavaScript. The framework's own
// example test does the same thing, which is where it came from.
fn escape_for_script(js string) string {
	return js.replace('</script', '<\\/script')
}

// attr_for is the attribute that references an asset of this kind.
fn attr_for(kind string) string {
	return if kind == 'css' { 'href' } else { 'src' }
}

// inline_one replaces one tag with its file contents.
fn inline_one(html string, a Asset, root string) string {
	start, stop := locate_tag(html, attr_for(a.kind), a.rel) or { return html }
	path := os.join_path(root, a.rel)
	// A tag that exists in index.html but not on disk is a build error, not a
	// silent skip: the dev server would 404 it too, and a missing pane in
	// production is the symptom everybody notices last.
	raw := os.read_file(path) or {
		eprintln('pack: cannot read ' + path + ': ' + err.msg())
		exit(1)
	}
	body := if a.kind == 'js' { escape_for_script(raw) } else { raw }
	repl := if a.kind == 'css' {
		'<style>\n' + body + '\n</style>'
	} else {
		'<script>\n' + body + '\n</script>'
	}
	return html[..start] + repl + html[stop..]
}

fn main() {
	// build.ps1 runs this from the repo root with no arguments; an explicit root
	// is accepted so the tool can be run by hand from anywhere. `os.args[0]` is a
	// C string, not a V one: `os.args.len > 1` and `os.args[1].str()`. The slice
	// form `os.args[1..]` is a trap here - it compiles to an Array of pointers
	// whose `.str()` resolves to `string.u8_str`, so the failure surfaces as a C
	// type error hundreds of lines into generated code rather than as V.
	mut root := '.'
	if os.args.len > 1 {
		root = os.args[1].str()
	}
	frontend := os.join_path(root, rel_root)
	entry := os.join_path(frontend, 'index.html')
	html := os.read_file(entry) or {
		eprintln('pack: cannot read ' + entry + ': ' + err.msg())
		exit(1)
	}

	// Explicit, and in this order, rather than discovered by walking frontend/:
	// an asset that is not referenced by index.html has no business being inlined,
	// and the list is the contract between this file and index.html.
	assets := [
		Asset{
			kind: 'css'
			rel:  'css/tokens.css'
		},
		Asset{
			kind: 'css'
			rel:  'css/base.css'
		},
		Asset{
			kind: 'css'
			rel:  'css/app.css'
		},
		Asset{
			kind: 'js'
			rel:  'js/i18n.js'
		},
		Asset{
			kind: 'js'
			rel:  'js/chart.js'
		},
		Asset{
			kind: 'js'
			rel:  'js/boot.js'
		},
	]

	mut out := html
	mut inlined := 0
	for a in assets {
		next := inline_one(out, a, frontend)
		if next != out {
			inlined++
			// The tag is gone once inlined, so `out` shrinks and the next asset is
			// matched against the already-rewritten document. Fine: each replacement
			// is on its own unique href/src.
			out = next
		}
	}

	// Every listed asset must have been inlined, and no reference may be left behind.
	// The count check matters more than the leftover check: an asset index.html
	// does not mention leaves no reference to find, so "nothing left over" passes
	// while a stylesheet silently vanished. In dev the file loads over HTTP and
	// nobody notices; packed, the window is just missing a pane.
	if inlined != assets.len {
		eprintln('pack: ${inlined} of ${assets.len} asset(s) inlined - check that index.html references every listed file')
		exit(1)
	}
	for a in assets {
		if out.contains(attr_for(a.kind) + '="' + a.rel + '"') {
			eprintln('pack: ' + a.rel + ' is still referenced after inlining')
			exit(1)
		}
	}
	if out.contains('<link rel="stylesheet"') {
		eprintln('pack: an unlisted stylesheet is still referenced')
		exit(1)
	}
	if out.contains('<script src=') {
		eprintln('pack: an unlisted script is still referenced')
		exit(1)
	}

	target := os.join_path(root, out_rel)
	os.mkdir_all(os.dir(target))!
	// `s.len` is a property on a string, not a method. `s.len()` is an unknown
	// function and the cascade hides that fact behind two unrelated errors.
	before := html.len
	os.write_file(target, out) or {
		eprintln('pack: cannot write ' + target + ': ' + err.msg())
		exit(1)
	}

	// V's inlined `</script>` guard is worth restating in the output, because the
	// failure it prevents is invisible until a particular string appears in a
	// particular file.
	ratio := if before > 0 { (out.len * 100) / before } else { 0 }
	println('pack: ${inlined} asset(s) inlined into one document')
	println('pack: ${entry} ${before} B + assets  ->  ${target} ${out.len} B  (${ratio}% of the source html)')
}
