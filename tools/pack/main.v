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
import encoding.base64

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

// inline_fonts rewrites every `url(relative/path.woff2)` in a CSS body into a
// data: URI.
//
// WHY THIS EXISTS AND WHY IT IS NOT OPTIONAL
//
// webview_set_html gives the document no origin, so a relative request from it
// resolves to nothing. That is the whole reason tools/pack exists for stylesheets
// and scripts, and a font is the same problem with a WORSE symptom: a missing
// <script src> gives a dead UI, while a missing font gives the system face, which
// looks fine and ships. The Persian font is the one that matters - a Persian
// session that silently falls back to Segoe UI has the wrong ی and ک, and reads
// as slightly wrong in a way nobody can name or report.
//
// The CSP allows it: the framework's default policy is `font-src 'self' data:`.
//
// Only URLs that resolve to a real file under the frontend root are rewritten.
// Anything else is left exactly as it was - a `url(#id)` SVG reference, an
// absolute http URL, a data: URI already there - because guessing at a URL the
// packer has never seen is how a build step starts breaking working documents.
//
// Paths are resolved relative to the CSS file's own directory, so a stylesheet in
// css/ reaches fonts/ with ../fonts/.
// resolve_upwards joins a base directory and a relative path, resolving `.` and
// `..` segments by hand.
//
// WHY BY HAND, when os.norm_path exists
//
// os.norm_path QUOTES a `..` segment. Given `css/../fonts/x.woff2` it returns
// `css\"..\fonts\x.woff2` — a path with a stray quote in it that cannot exist, and
// that read_bytes reports as "failed to open file" with nothing about why. Every
// font reference in this project is `../fonts/`, so the first version of
// inline_fonts silently disabled all of them while reporting success.
//
// os.join_path is out for the same reason, and os.read_bytes will not open a path
// containing `..` at all. So the three stdlib functions this would normally be one
// call to all mishandle the case, and doing it here is the honest answer: the
// rules are five lines and they are testable.
//
// A pure function, so a test can check the awkward cases without a filesystem.
fn resolve_upwards(base string, rel string) string {
	mut segments := []string{}
	for raw in (base + '/' + rel).split('/') {
		for part in raw.split('\\') {
			if part == '' || part == '.' {
				continue
			}
			if part == '..' {
				if segments.len > 0 {
					segments.delete_last()
				}
				continue
			}
			segments << part
		}
	}
	return segments.join('/')
}

fn inline_fonts(css string, root string, rel string) string {
	// css_dir is the stylesheet's own directory, because a relative url() in a CSS
	// file is relative to THAT file and not to the frontend root. Getting it wrong
	// makes every reference a miss, and every miss is silent.
	css_dir := os.dir(os.join_path(root, rel))
	mut out := css
	mut i := 0
	for i < out.len {
		// `index_after` returns the index OF the match, not after it, so the start
		// of `url(` is what comes back and `url('.len` positions us at the first
		// character inside the parens. (Verified rather than assumed: a scratch
		// program, because the name reads the other way round.)
		start := out.index_after('url(', i) or { break }
		open := start + 'url('.len
		mut close := open
		// The opening quote has to be skipped on BOTH ends. The first version of
		// this advanced `close` past it and left `open` where it was, so every
		// extracted path was `"../fonts/x.woff2` with a stray quote on the front —
		// which is a path nothing can open, and which read_bytes reported as
		// "failed to open file" with no hint about the quote. The symptom was
		// identical to the resolve_upwards bug that came with it, and it took a
		// debug print of the path itself to see it.
		mut path_start := open
		mut quote := u8(`"`)

		if close < out.len && (out[close] == `"` || out[close] == `'`) {
			quote = out[close]
			path_start = close + 1
			close++
		}
		for close < out.len && out[close] != quote && out[close] != `)` {
			close++
		}
		if close >= out.len {
			break
		}
		path := out[path_start..close]
		mut after := close
		if close < out.len && out[close] == quote {
			after++
		}
		if path.starts_with('data:') || path.starts_with('#')
			|| path.starts_with('http://') || path.starts_with('https://') {
			i = after
			continue
		}
		// The path is resolved by resolve_upwards and NOT by os.norm_path or
		// os.join_path, both of which quote a `..` segment into a path that cannot
		// exist. See resolve_upwards for the full story.
		disk := if os.is_abs_path(path) {
			path
		} else {
			resolve_upwards(css_dir, path)
		}
		bytes := os.read_bytes(disk) or {
			i = after
			continue
		}
		mime := if path.ends_with('.woff2') {
			'font/woff2'
		} else if path.ends_with('.woff') {
			'font/woff'
		} else if path.ends_with('.ttf') {
			'font/ttf'
		} else {
			'application/octet-stream'
		}
		// Base64, because woff2 is binary and percent-escaping it would triple its
		// size. 33% overhead on 120 KB is the price of having no origin to fetch
		// from, and it is smaller than the alternative of shipping a second
		// transport for the release build.
		repl := 'url("data:${mime};base64,${base64.encode(bytes)}")'
		out = out[..start] + repl + out[after..]
		i = start + repl.len
	}
	return out
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
	// A stylesheet is also the entry point for the fonts it references, so the
	// fonts go with it or they will not load at all.
	body := if a.kind == 'css' {
		inline_fonts(raw, root, a.rel)
	} else {
		escape_for_script(raw)
	}
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
		// The fonts, AFTER base and app, because `url(../fonts/x.woff2)` only
		// appears once fonts.css is inlined and its own references need rewriting -
		// fonts.css carries no @font-face of its own to lose, but it is the file
		// index.html names, so it has to be in the list to be inlined at all.
		Asset{
			kind: 'css'
			rel:  'css/fonts.css'
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
			rel:  'js/byte-slider.js'
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
