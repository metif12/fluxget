// boot.js — the whole frontend, Phase 2.
//
// Three things here are load-bearing and all three come from the framework's
// rules:
//
//   1. The page POLLS. fluxget.tick is called on an interval and nothing is ever
//      pushed at us. vails ADR-0010 forbids V->JS eval from a spawned worker, and
//      aria2's completion hooks are a shell-out rather than a callback, so
//      polling is not a shortcut here - it is the only shape available. The
//      native side queues what changed (core/notice.v) and hands it over in the
//      next tick.
//
//   2. NO STRING IS COMPOSED HERE. Rows and cards render fields the native side
//      produced, and notice sentences come from I18n.compose_notice, which is the
//      single composer. This file decides where things sit, not how they read.
//
//   3. KEYBOARD FIRST. vails gives us a webview, and a webview is operated with
//      the keyboard. Shortcuts are not a power-user nicety here - a mouse-driven
//      UI with no focus order is not finished.
//
// Plain ES5 and no modules: the CSP is script-src 'self' 'unsafe-inline', and
// tools/pack inlines these three files into one document for production.
"use strict";

(function () {
	var TICK_MS = 1000;
	var inFlight = false;
	var consecutiveErrors = 0;
	var chart = null;
	var selectedIndex = -1;

	function el(id) {
		return document.getElementById(id);
	}

	function t(key) {
		return window.I18n.t(key);
	}

	function set(key, value, state) {
		var node = el("v-" + key);
		if (!node) { return; }
		node.textContent = value;
		node.setAttribute("data-state", state || "ok");
	}

	// ---- locale and theme -------------------------------------------------

	// The locale button shows the language you would SWITCH TO, not the one you
	// are in. A button labelled with the current language is a toggle whose
	// meaning depends on the label, and nobody guesses that.
	function refresh_tool_labels() {
		var next = window.I18n.locale() === "fa" ? "en" : "fa";
		var names = { fa: "فارسی", en: "English" };
		el("localebtn").textContent = names[next];
		el("localebtn").setAttribute("title", "l · " + t("locale.toggle"));
		el("themebtn").setAttribute("title", "t · " + t("theme.toggle"));
		el("helpbtn").setAttribute("title", "? · " + t("shortcuts.title"));
		el("helpbody").textContent = t("shortcuts.body");
	}

	// on_locale_changed is called by I18n after it has walked the document, so
	// the re-render happens with the new text already in place. The notice list is
	// re-composed here rather than on set_locale because a toast's sentence
	// depends on the locale that was active when it was created.
	window.on_locale_changed = function () {
		refresh_tool_labels();
		render_rows(last_downloads, true);
		render_toasts();
	};

	window.on_theme_changed = function () {
		// The chart reads its colours out of CSS custom properties at draw time,
		// so a repaint is the whole of the theme change here.
		if (chart) { chart.draw(); }
	};

	// ---- notices ---------------------------------------------------------

	// seen is every notice we have been handed, newest last, and a toast is
	// derived from it. Holding the notices instead of the DOM is what lets a
	// locale switch re-word a toast that is still on screen, and it is what makes
	// "delivered exactly once" checkable: the count is derived from the payload,
	// not from how many times a handler ran.
	var seen = [];
	var VISIBLE_TOASTS = 3;

	function note(n) {
		seen.push(n);
		trim_toasts();
	}

	// trim_toasts keeps the newest VISIBLE_TOASTS and forgets the rest. An
	// unbounded toast stack is a second queue, and it covers the queue it is
	// reporting on. Forgetting is safe because a notice is history, not state:
	// the log and the queue both still know what happened.
	function trim_toasts() {
		var start = Math.max(0, seen.length - VISIBLE_TOASTS);
		var box = el("toasts");
		box.innerHTML = "";
		for (var i = start; i < seen.length; i++) {
			var node = document.createElement("div");
			node.className = "toast";
			node.setAttribute("data-kind", seen[i].kind);
			node.textContent = window.I18n.compose_notice(seen[i]);
			box.appendChild(node);
		}
	}

	// render_toasts exists so a locale switch re-composes the SAME notices. It
	// does not re-fetch anything and it does not re-add them - compose_notice is
	// pure, which is the property that makes this possible.
	function render_toasts() {
		trim_toasts();
	}

	// drain_notices consumes a tick's notice array. The native side delivers each
	// notice exactly once, so this is a straight append: any dedup here would be
	// hiding a bug on the other side of the bridge, and the honest symptom of
	// that bug is a duplicated toast.
	function drain_notices(list) {
		if (!list || !list.length) { return; }
		for (var i = 0; i < list.length; i++) { note(list[i]); }
	}

	// ---- the queue --------------------------------------------------------

	var last_downloads = [];

	// aria2's Status vocabulary, passed through unchanged (CONTEXT.md), so the
	// class comes straight from the word. A status this app has never seen renders
	// as neutral instead of inheriting the last row's colour.
	function status_class(s) {
		if (s === "active") { return "is-active"; }
		if (s === "complete") { return "is-complete"; }
		if (s === "error") { return "is-error"; }
		if (s === "waiting") { return "is-waiting"; }
		if (s === "paused") { return "is-paused"; }
		return "is-other";
	}

	function percent_width(pct) {
		var n = Number(pct);
		if (!isFinite(n) || n < 0) { return "0%"; }
		if (n > 100) { return "100%"; }
		return n.toFixed(1) + "%";
	}

	function find_row_index(list, gid) {
		for (var i = 0; i < list.length; i++) {
			if (list[i].gid === gid) { return i; }
		}
		return -1;
	}

	function render_rows(downloads, force) {
		var box = el("rows");
		var list = downloads || [];
		el("queue-count").textContent = String(list.length);
		el("empty").hidden = list.length > 0;

		var signature = list.map(function (d) { return d.gid + ":" + d.status; }).join("|");
		var changed = force || box.dataset.signature !== signature;

		if (!changed) {
			// Same rows, same states: update only the numbers. At 1Hz, rebuilding
			// the list every tick would kill text selection mid-drag and flicker
			// every progress bar.
			var nodes = box.querySelectorAll("[data-gid]");
			for (var i = 0; i < nodes.length; i++) {
				var idx = find_row_index(list, nodes[i].getAttribute("data-gid"));
				if (idx < 0) { continue; }
				var d = list[idx];
				nodes[i].querySelector(".row__bar").style.width = percent_width(d.percent);
				nodes[i].querySelector(".row__pct").textContent = percent_width(d.percent);
				nodes[i].querySelector(".row__done").textContent = d.done + " / " + d.total;
				nodes[i].querySelector(".row__speed").textContent = d.speed;
				nodes[i].querySelector(".row__eta").textContent = d.eta;
			}
			apply_selection();
			return;
		}

		box.dataset.signature = signature;
		box.innerHTML = "";
		for (var j = 0; j < list.length; j++) {
			box.appendChild(row_node(list[j], j));
		}
		// Keep the selection on the same download across a rebuild rather than on
		// the same index: a completed item drops out of `active` and the queue
		// shifts, and a selection that jumps to a different file on completion is
		// how space gets pressed on the wrong download.
		if (selectedIndex >= 0) {
			var gid = list[selectedIndex] ? list[selectedIndex].gid : null;
			if (gid) {
				for (var k = 0; k < list.length; k++) {
					if (list[k].gid === gid) { selectedIndex = k; break; }
				}
			}
			if (selectedIndex >= list.length) { selectedIndex = list.length - 1; }
		}
		apply_selection();
	}

	function row_node(d, index) {
		var row = document.createElement("article");
		row.className = "row " + status_class(d.status);
		row.setAttribute("data-gid", d.gid);
		row.setAttribute("role", "listitem");
		// Not focusable: the list manages focus with a single tabindex on the
		// container, so one Tab reaches the queue and the arrows move within it.
		// Making every row a tab stop would make a 500-item queue unusable.
		row.setAttribute("data-index", String(index));

		var head = document.createElement("div");
		head.className = "row__head";

		var name = document.createElement("span");
		name.className = "row__name";
		name.textContent = d.name;
		name.title = d.dir || d.gid;
		head.appendChild(name);

		var badges = document.createElement("span");
		badges.className = "row__badges";
		if (d.is_torrent) { badges.appendChild(badge("BT", "torrent")); }
		// A finished torrent that is still uploading is NOT complete, and showing
		// it as done is the small lie a download manager tells.
		if (d.seeder) { badges.appendChild(badge("seeding", "seed")); }
		if (d.error) { badges.appendChild(badge(d.error, "err")); }
		head.appendChild(badges);

		var state = document.createElement("span");
		state.className = "row__state";
		state.textContent = d.status;
		head.appendChild(state);
		row.appendChild(head);

		var track = document.createElement("div");
		track.className = "row__track";
		var bar = document.createElement("div");
		bar.className = "row__bar";
		bar.style.width = percent_width(d.percent);
		track.appendChild(bar);
		row.appendChild(track);

		var foot = document.createElement("div");
		foot.className = "row__foot";
		foot.appendChild(span("row__done", d.done + " / " + d.total));
		foot.appendChild(span("row__pct", percent_width(d.percent)));
		foot.appendChild(span("row__speed", d.speed));
		foot.appendChild(span("row__eta", d.eta));
		row.appendChild(foot);

		return row;
	}

	function span(cls, text) {
		var s = document.createElement("span");
		s.className = cls;
		s.textContent = text;
		return s;
	}

	function badge(text, kind) {
		var b = document.createElement("span");
		b.className = "badge";
		b.setAttribute("data-kind", kind);
		b.textContent = text;
		return b;
	}

	// ---- selection --------------------------------------------------------

	function apply_selection() {
		var rows = el("rows").querySelectorAll(".row");
		for (var i = 0; i < rows.length; i++) {
			rows[i].classList.toggle("is-selected", i === selectedIndex);
		}
		if (selectedIndex >= 0 && rows[selectedIndex]) {
			rows[selectedIndex].scrollIntoView({ block: "nearest" });
		}
	}

	function move_selection(delta) {
		var n = last_downloads.length;
		if (n === 0) { return; }
		if (selectedIndex < 0) {
			selectedIndex = delta > 0 ? 0 : n - 1;
		} else {
			selectedIndex = Math.max(0, Math.min(n - 1, selectedIndex + delta));
		}
		apply_selection();
	}

	function selected_gid() {
		if (selectedIndex < 0 || selectedIndex >= last_downloads.length) { return ""; }
		return last_downloads[selectedIndex].gid;
	}

	// ---- the log ----------------------------------------------------------

	function render_log(lines, dropped) {
		el("log").textContent = (lines || []).join("\n");
		el("log-count").textContent = String((lines || []).length) +
			(dropped > 0 ? " (+" + dropped + ")" : "");
	}

	// ---- one tick ---------------------------------------------------------

	function apply_tick(tick) {
		consecutiveErrors = 0;

		// The engine card leads with the PHASE, because that is the word the UI
		// branches on. restart_in_ms is shown so a backoff reads as a wait rather
		// than as a hang.
		var phase_key = "engine." + tick.phase;
		var engine_text = tick.version || t(phase_key) || tick.phase;
		var state = "ok";
		if (!tick.ok) {
			state = tick.phase === "missing" ? "err" : "warn";
			engine_text = t(phase_key) || tick.phase;
			if (tick.detail) { engine_text += " — " + tick.detail; }
		} else if (tick.restart_in_ms > 0) {
			engine_text += "  " + window.I18n.fill(t("engine.retrying"), {
				n: String(Math.ceil(tick.restart_in_ms / 1000))
			});
		}
		set("engine", engine_text, state);

		set("speed", tick.ok
			? (tick.stat.download_speed + "  ↓  " + tick.stat.upload_speed + "  ↑")
			: "—", tick.ok ? "ok" : "warn");

		set("queue", tick.stat.num_active + " · " + tick.stat.num_waiting +
			" · " + tick.stat.num_stopped, "ok");

		// Which binary, and which of the four search rules found it. "aria2c" alone
		// leaves a user guessing which copy their downloads go through.
		set("aria2", tick.aria2_path
			? short_path(tick.aria2_path) + "  " +
				window.I18n.fill(t("engine.source"), { source: tick.aria2_source })
			: t("engine.missing"), tick.aria2_path ? "ok" : "err");

		el("setup").hidden = tick.phase !== "missing";
		if (tick.phase === "missing") {
			el("setup-detail").textContent = tick.detail || t("setup.body");
		}

		last_downloads = tick.downloads || [];
		render_rows(last_downloads, false);
		render_log(tick.logs, tick.logs_dropped);
		drain_notices(tick.notices);

		if (chart) {
			chart.push(tick.stat.download_speed_b || 0, tick.stat.upload_speed_b || 0);
			chart.draw();
		}
	}

	// The tick sends rates as rendered strings ("9.5 MiB/s") because that is what
	// every other surface shows and one formatter in one language is the whole
	// point. A chart needs numbers, so the numeric bytes ride alongside in
	// *_speed_b. Parsing the string back would be the second formatter and would
	// disagree with the first at the rounding boundary.
	function short_path(p) {
		var parts = p.split(/[\\\/]/);
		return parts.length > 2 ? "…\\" + parts[parts.length - 2] + "\\" + parts[parts.length - 1] : p;
	}

	function tick() {
		if (inFlight) { return; }
		inFlight = true;
		window.vails.call("fluxget.tick", "").then(function (raw) {
			var frame;
			// Parse and render are separated, and the two failures reported
			// differently, because they are different bugs. Wrapping both in one try
			// meant a crash inside render_rows was reported as "malformed JSON",
			// which sent the search to the native side for a fault in this file.
			try {
				frame = JSON.parse(raw);
			} catch (e) {
				set("engine", "bad payload (" + e + "): " + String(raw).slice(0, 160), "err");
				return;
			}
			try {
				apply_tick(frame);
			} catch (e) {
				set("engine", "cannot render tick: " + e, "err");
				return;
			}
		}).catch(function (e) {
			consecutiveErrors++;
			// The tick itself failing is worth saying out loud: it is the case where
			// the UI is showing stale numbers and the user needs to know.
			set("engine", "tick failed (" + consecutiveErrors + "): " + e, "err");
		}).then(function () {
			inFlight = false;
		});
	}

	// ---- the add box ------------------------------------------------------

	function submit_add() {
		var input = el("addurl");
		var value = input.value.trim();
		if (!value) { return; }
		var btn = el("addbtn");
		btn.disabled = true;
		window.vails.call("fluxget.add", JSON.stringify({
			uris: [value],
			dir: "",
			out: "",
			paused: false
		})).then(function (gid) {
			// The gid is the only handle the rest of Fluxget has, so it is worth
			// showing: it is what a bug report needs.
			note({ kind: "added", gid: gid, name: short_path(value), text: value });
			input.value = "";
			tick();
		}).catch(function (e) {
			// Refusals are the native side's own sentences (aria2's message, or why
			// the request was malformed). Shown verbatim rather than rephrased,
			// because "add failed" is not something anyone can act on.
			note({ kind: "failed", name: short_path(value), error: String(e), text: String(e) });
		}).then(function () {
			btn.disabled = false;
			input.focus();
		});
	}

	el("addform").addEventListener("submit", function (ev) {
		ev.preventDefault();
		submit_add();
	});

	// ---- keyboard ---------------------------------------------------------

	// Everything is bound on document, not on a focused element, because a
	// download queue is read with the hands on the home row and requiring focus
	// first would mean the shortcuts only worked when a row happened to be
	// selected. Keys that need text input are the exception and are checked
	// first.
	function typing_in(target) {
		if (!target) { return false; }
		var tag = (target.tagName || "").toLowerCase();
		return tag === "input" || tag === "textarea" || target.isContentEditable;
	}

	document.addEventListener("keydown", function (ev) {
		// In an RTL layout the LEFT arrow is the one that moves forward in a
		// logical order, but a LIST is read top to bottom, so up/down stay up/down
		// in both directions. Only the explicit "move in the queue" action is
		// mirrored, and it is not bound to an arrow at all until Phase 3 has the
		// move command.
		if (ev.key === "Escape") {
			if (!el("help").hidden) { toggle_help(false); ev.preventDefault(); }
			return;
		}
		if (typing_in(ev.target)) {
			// Enter submits the add box (the form's own handler), and nothing else
			// is stolen while someone is typing a URL.
			return;
		}
		switch (ev.key) {
			case "/":
				ev.preventDefault();
				el("addurl").focus();
				el("addurl").select();
				break;
			case "ArrowDown":
				ev.preventDefault();
				move_selection(1);
				break;
			case "ArrowUp":
				ev.preventDefault();
				move_selection(-1);
				break;
			case " ":
				ev.preventDefault();
				toast_selected_state();
				break;
			case "a":
				ev.preventDefault();
				submit_add();
				break;
			case "t":
				ev.preventDefault();
				window.I18n.toggle_theme();
				break;
			case "l":
				ev.preventDefault();
				window.I18n.toggle_locale();
				break;
			case "?":
				ev.preventDefault();
				toggle_help(true);
				break;
		}
	});

	// Phase 2 has no pause/resume command in the manifest yet - that is Phase 3's
	// "Control + settings". Until then space says what the selection IS rather than
	// silently doing nothing, and says where the real key is coming from.
	function toast_selected_state() {
		var gid = selected_gid();
		if (!gid) {
			note({ kind: "info", text: t("shortcuts.phase3") });
			return;
		}
		note({ kind: "info", gid: gid, name: gid, text: "pause " + gid + " → Phase 3" });
	}

	function toggle_help(show) {
		el("help").hidden = !show;
	}

	el("helpclose").addEventListener("click", function () { toggle_help(false); });
	el("help").addEventListener("click", function (ev) {
		// Clicking the backdrop closes, clicking the panel does not.
		if (ev.target === el("help")) { toggle_help(false); }
	});
	el("helpbtn").addEventListener("click", function () { toggle_help(true); });
	el("themebtn").addEventListener("click", function () { window.I18n.toggle_theme(); });
	el("localebtn").addEventListener("click", function () { window.I18n.toggle_locale(); });

	// ---- go ---------------------------------------------------------------

	function start() {
		window.I18n.init();
		refresh_tool_labels();
		chart = window.FluxChart.create(el("chart"));
		chart.resize();

		var is_dev = location.protocol === "http:";
		// Which of the two frontends is running, in a form that fits a card. The
		// card ellipsises, so "packed document (set_html)" rendered as
		// "packed document (set_ht…" - the useful part was the part cut off.
		set("transport", is_dev
			? window.I18n.fill(t("transport.dev"), { port: location.port })
			: t("transport.packed"), "ok");

		if (!window.vails || typeof window.vails.call !== "function") {
			set("bridge", "no window.vails runtime", "err");
			set("engine", t("engine.never-started"), "err");
			el("setup-detail").textContent = t("setup.body");
			el("setup").hidden = false;
			return;
		}
		set("bridge", "window.vails.call", "ok");

		// The proof that a command with no grant is refused, re-checked on every
		// load. A command the capability does not grant must come back as a
		// REJECTION saying `forbidden:`, not a silent success and not
		// `unknown method:` - that difference is the security property the whole
		// design rests on.
		window.vails.call("fluxget.not_granted", "").then(function () {
			note({ kind: "failed", text: "UNEXPECTED: an ungranted command resolved" });
		}).catch(function (e) {
			console.info("capability gate: " + e);
		});

		window.vails.call("fluxget.ping", "").then(function (r) {
			set("bridge", "ping → " + r, r === "pong" ? "ok" : "warn");
		}).catch(function (e) {
			set("bridge", "ping rejected: " + e, "err");
		});

		tick();
		window.setInterval(tick, TICK_MS);
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", start);
	} else {
		start();
	}
}());