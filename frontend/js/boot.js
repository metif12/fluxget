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
	// selectedIndex starts at -1 and is set to 0 by the first render that has rows.
	//
	// Not a detail: the row actions are revealed by `.row.is-selected`, so with no
	// selection a queue shows no buttons AND space does nothing. A download manager
	// whose keyboard path needs one arrow press before it can pause anything is a
	// keyboard path nobody uses. The first render selects the first row, and the
	// selection is by GID afterwards so it survives a row completing.
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

	// seen is every notice we have been handed, newest last, and `nodes` holds one
	// DOM node per entry still on screen. Holding the notices instead of just the
	// DOM is what lets a locale switch re-word a toast that is still visible.
	var seen = [];
	var nodes = [];
	var VISIBLE_TOASTS = 3;

	function make_toast_node(n) {
		var node = document.createElement("div");
		node.className = "toast";
		node.setAttribute("data-kind", n.kind);
		node.textContent = window.I18n.compose_notice(n);
		return node;
	}

	// note appends ONE toast.
	//
	// The first version rebuilt the whole list on every notice, and that turned out
	// to be a real bug rather than a style choice: rebuilding re-creates the nodes,
	// which restarts the toast-in animation, so the older toasts fade out and back
	// in whenever a new one arrives - and when notices arrive as fast as the tick
	// (a download retrying, say) they sit at opacity 0 permanently and are invisible.
	// Caught by driving the page with a tick that always carries a notice.
	//
	// Appending one node and dropping one old node is O(1) and leaves the existing
	// animations alone.
	function note(n) {
		seen.push(n);
		nodes.push(make_toast_node(n));
		el("toasts").appendChild(nodes[nodes.length - 1]);
		// An unbounded toast stack is a second queue, and it covers the queue it is
		// reporting on. Forgetting is safe because a notice is history, not state:
		// the queue and the log both still know what happened.
		while (nodes.length > VISIBLE_TOASTS) {
			var old = nodes.shift();
			seen.shift();
			if (old && old.parentNode) { old.parentNode.removeChild(old); }
		}
	}

	// render_toasts re-composes the SAME notices in place, for a locale switch. It
	// does not re-fetch and it does not re-create, because re-creating would restart
	// the animation for the same reason note() avoids it.
	function render_toasts() {
		for (var i = 0; i < nodes.length && i < seen.length; i++) {
			nodes[i].textContent = window.I18n.compose_notice(seen[i]);
		}
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
		if (selectedIndex < 0) {
			// First render with rows: select the top one, so the actions are
			// reachable without a prior keypress. (See the note on selectedIndex.)
			selectedIndex = list.length > 0 ? 0 : -1;
		} else {
			var gid = list[selectedIndex] ? list[selectedIndex].gid : null;
			if (gid) {
				var found = false;
				for (var k = 0; k < list.length; k++) {
					if (list[k].gid === gid) {
						selectedIndex = k;
						found = true;
						break;
					}
				}
				if (!found) { selectedIndex = Math.min(selectedIndex, list.length - 1); }
			} else {
				selectedIndex = list.length > 0 ? 0 : -1;
			}
		}
		apply_selection();
	}

	function row_node(d, index) {
		var row = document.createElement("article");
		row.className = "row " + status_class(d.status);
		row.setAttribute("data-gid", d.gid);
		row.setAttribute("role", "listitem");
		// Not focusable: the list manages focus with a single tab stop on the
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
		if (d.seeder) { badges.appendChild(badge(t("row.seeding"), "seed")); }
		if (d.error) { badges.appendChild(badge(d.error, "err")); }
		head.appendChild(badges);

		// The buttons live between the badges and the status word, and they are
		// per-row rather than in the pane header on purpose: a header button acts
		// on "the selection", which is a concept this UI does not otherwise have.
		// A row that is operable by its own buttons is operable by a keyboard user
		// who never touched the mouse.
		head.appendChild(actions_for(d));

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

	// actions_for builds the buttons a download's CURRENT STATE supports.
	//
	// Which buttons exist is a function of the status, and that is the whole
	// design: offering "pause" on a finished download invites a refusal from aria2
	// that arrives as an error toast and looks like the app being broken.
	//
	// The first version excluded `pause` on an ACTIVE download, on the theory that
	// aria2 refuses it. It does not - `aria2.pause` on an active download is the
	// single most common thing anyone does to a download manager, and
	// `aria2.forcePause` is the different call I was thinking of. That mistake
	// removed the app's most-used button from its most common row state.
	//
	// So: terminal states get retry, everything live gets pause or resume, and
	// every row gets remove. There is deliberately no second "forget" button -
	// remove already discards the record, and two buttons that differ only in
	// whether a row disappears from the history is a distinction with no user.
	function actions_for(d) {
		var box = document.createElement("span");
		box.className = "row__actions";
		var terminal = d.status === "complete" || d.status === "error" || d.status === "removed";
		if (terminal) {
			box.appendChild(action_button("retry", t("row.retry"), "fluxget.retry", { gid: d.gid }));
		} else if (d.status === "paused") {
			box.appendChild(action_button("resume", t("row.resume"), "fluxget.resume", { gid: d.gid }));
		} else {
			box.appendChild(action_button("pause", t("row.pause"), "fluxget.pause", { gid: d.gid }));
		}
		// keep_record:false is the explicit form of what remove means to a user:
		// the row leaves the list and the history, not just the queue.
		box.appendChild(action_button("remove", t("row.remove"), "fluxget.remove",
			{ gid: d.gid, keep_record: false }));
		return box;
	}

	function action_button(kind, label, command, params) {
		var b = document.createElement("button");
		b.className = "act";
		b.setAttribute("type", "button");
		b.setAttribute("data-kind", kind);
		b.textContent = label;
		b.title = label;
		// One handler for every button rather than one per kind: the command and
		// the payload are data on the element, so adding an action is a line in
		// actions_for and nowhere else.
		b.addEventListener("click", function (ev) {
			ev.stopPropagation();
			run_command(b, command, params);
		});
		return b;
	}

	// run_command is the one path from a button to the bridge, and it owns the two
	// things every action needs:
	//
	//   * the button is disabled for the duration, so a double click cannot queue
	//     two removes of the same gid;
	//   * a refusal is shown, not swallowed. aria2's own sentence arrives as the
	//     rejection text, and a UI that discards it is a UI where a button press
	//     that failed looks exactly like one that worked.
	//
	// There is deliberately no optimistic update here. The next tick is at most a
	// second away and it is the only thing that knows the truth, so guessing would
	// mean showing a state the engine may never reach.
	function run_command(button, command, params) {
		if (button.disabled) { return; }
		button.disabled = true;
		window.vails.call(command, JSON.stringify(params)).then(function (result) {
			button.disabled = false;
			// set_item_options answers with the options aria2 REFUSED, so a payload
			// that is not "ok" is a problem even though the call succeeded. Anything
			// else is reported the same way, because "it said no to this option" is
			// exactly what a user needs to see.
			if (command === "fluxget.set_item_options" && result !== "ok") {
				note({ kind: "failed", name: params.gid || "", error: result, text: result });
			}
			tick();
		}).catch(function (e) {
			button.disabled = false;
			note({ kind: "failed", name: params.gid || "", error: String(e), text: String(e) });
		});
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
		if (ev.key === "Escape") {
			if (!el("help").hidden) { toggle_help(false); ev.preventDefault(); }
			if (!el("settings").hidden) { toggle_settings(false); ev.preventDefault(); }
			return;
		}
		if (typing_in(ev.target)) {
			// Enter submits the add box (the form's own handler), and nothing else
			// is stolen while someone is typing a URL.
			return;
		}
		// A list is read top to bottom in both directions, so up and down stay up
		// and down. What IS mirrored is "move the selection in the queue", because
		// that is an operation on a LOGICAL order and a logical order reverses.
		// Getting this wrong in an RTL UI means ctrl+up moves a row the opposite
		// way from what the arrow points at.
		if (ev.ctrlKey && (ev.key === "ArrowUp" || ev.key === "ArrowDown")) {
			ev.preventDefault();
			move_selection_in_queue(ev.key === "ArrowUp" ? -1 : 1);
			return;
		}
		if (ev.ctrlKey) {
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
				// Space is "toggle the selection's run state", which is pause on a
				// live download and resume on a paused one. It clicks the button
				// that exists, so the key cannot offer an action the buttons do not.
				press_selected(is_selected_paused() ? "resume" : "pause");
				break;
			case "Delete":
			case "Backspace":
				ev.preventDefault();
				press_selected("remove");
				break;
			case "r":
				ev.preventDefault();
				press_selected("retry");
				break;
			case "a":
				ev.preventDefault();
				submit_add();
				break;
			case "s":
				ev.preventDefault();
				toggle_settings(true);
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

	function is_selected_paused() {
		if (selectedIndex < 0 || selectedIndex >= last_downloads.length) { return false; }
		return last_downloads[selectedIndex].status === "paused";
	}

	// move_selection_in_queue reorders aria2's queue, which is a different thing
	// from moving the selection cursor and lives on the server: aria2 holds the
	// order, so a client-side shuffle would be undone by the next tick.
	function move_selection_in_queue(delta) {
		var gid = selected_gid();
		if (!gid) {
			note({ kind: "info", text: t("shortcuts.none-selected") });
			return;
		}
		window.vails.call("fluxget.move", JSON.stringify({ gid: gid, delta: delta })).then(function () {
			tick();
		}).catch(function (e) {
			note({ kind: "failed", name: gid, error: String(e), text: String(e) });
		});
	}

		// Phase 2 bound space to a message saying pause was not implemented yet. It is
	// implemented, so the key now does the thing it always promised - and it picks
	// between pause and resume from the selection's status, which is why it reads
	// the row rather than sending a fixed command.
	//
	// The buttons are found through the row's own DOM instead of rebuilding the
	// command from the download object, so the keyboard and the mouse can never
	// disagree about what an action is: there is one set of buttons, and this
	// clicks the right one.
	function press_selected(action) {
		var rows = el("rows").querySelectorAll(".row");
		if (selectedIndex < 0 || selectedIndex >= rows.length) {
			note({ kind: "info", text: t("shortcuts.none-selected") });
			return;
		}
		var button = rows[selectedIndex].querySelector('.act[data-kind="' + action + '"]');
		if (!button) {
			// A finished download has no pause button, and pretending the key is
			// broken is better than silently doing nothing.
			note({ kind: "info", text: t("shortcuts.not-applicable", { action: action }) });
			return;
		}
		button.click();
	}

	function toggle_help(show) {
		el("help").hidden = !show;
	}

	// ---- settings --------------------------------------------------------

	// open_settings reads the document BEFORE showing the dialog, because the
	// dialog is an editor of the file, not of whatever the fields happen to hold
	// from last time. Getting that backwards is how a dialog ends up saving the
	// stale values it was initialised with.
	function toggle_settings(show) {
		if (!show) {
			el("settings").hidden = true;
			return;
		}
		window.vails.call("fluxget.get_settings", "").then(function (raw) {
			fill_settings(raw);
			el("settings").hidden = false;
		}).catch(function (e) {
			note({ kind: "failed", text: "fluxget.get_settings: " + String(e) });
			el("settings").hidden = false;
		});
	}

	// fill_settings paints the form from the SettingsView.
	//
	// The numbers go in as the RAW integers aria2 holds, not as "1.0 MiB/s". The
	// document stores bytes per second, so a value shown pre-formatted would have
	// to be parsed back on save - and that parse is a second formatter disagreeing
	// with the first at exactly the rounding boundary that matters.
	function fill_settings(raw) {
		var view;
		try {
			view = JSON.parse(raw);
		} catch (e) {
			show_settings_notes([t("settings.bad-payload", { detail: String(raw).slice(0, 120) })]);
			return;
		}
		var s = view.settings || {};
		set_number("max_concurrent", s.max_concurrent);
		set_number("max_per_server", s.max_per_server);
		set_number("split", s.split);
		set_number("min_split_size", s.min_split_size);
		set_number("download_limit", s.download_limit);
		set_number("upload_limit", s.upload_limit);
		set_text("dir", s.dir);
		set_text("seed_ratio", s.seed_ratio);
		set_text("seed_time", s.seed_time);
		el("set-bt_enabled").checked = s.bt_enabled === true;
		el("set-save_session").checked = s.save_session === true;
		el("settings-path").textContent = view.path || "";
		show_settings_notes(view.notes || []);
	}

	function set_number(field, value) {
		var node = el("set-" + field);
		node.value = (typeof value === "number") ? String(value) : "";
	}

	function set_text(field, value) {
		el("set-" + field).value = typeof value === "string" ? value : "";
	}

	// show_settings_notes surfaces what the last save actually did.
	//
	// This is the visible half of the rule in platform/settings_cmd.v: "saved" and
	// "in force" are different claims. A refused limit comes back in `notes`, and a
	// dialog that dropped them would be reporting a setting the engine never
	// accepted.
	function show_settings_notes(notes) {
		var box = el("settings-notes");
		box.innerHTML = "";
		if (!notes || !notes.length) {
			box.hidden = true;
			return;
		}
		box.hidden = false;
		box.textContent = notes.join(" · ");
	}

	// save_settings sends the whole document.
	//
	// The WHOLE document rather than a patch, because that is what the command
	// means and what the file holds: a partial update would need a merge rule on
	// both sides, and the one field both sides have to agree on is which document
	// is current. An empty number field is sent as 0 rather than omitted, so
	// clearing a limit means "no limit" and not "leave it alone".
	function save_settings(ev) {
		if (ev) { ev.preventDefault(); }
		var payload = {
			max_concurrent: number_or_zero("max_concurrent"),
			max_per_server: number_or_zero("max_per_server"),
			download_limit: number_or_zero("download_limit"),
			upload_limit: number_or_zero("upload_limit"),
			split: number_or_zero("split"),
			min_split_size: number_or_zero("min_split_size"),
			dir: el("set-dir").value.trim(),
			bt_enabled: el("set-bt_enabled").checked,
			seed_ratio: el("set-seed_ratio").value.trim(),
			seed_time: el("set-seed_time").value.trim(),
			save_session: el("set-save_session").checked
		};
		var button = el("settings-save");
		button.disabled = true;
		window.vails.call("fluxget.set_settings", JSON.stringify(payload)).then(function (raw) {
			button.disabled = false;
			fill_settings(raw);
			note({ kind: "info", text: t("settings.saved") });
			tick();
		}).catch(function (e) {
			button.disabled = false;
			show_settings_notes([t("settings.refused", { detail: String(e) })]);
			note({ kind: "failed", text: String(e) });
		});
	}

	function number_or_zero(field) {
		var raw = el("set-" + field).value;
		var n = parseInt(raw, 10);
		return isFinite(n) ? n : 0;
	}

	el("helpclose").addEventListener("click", function () { toggle_help(false); });
	el("help").addEventListener("click", function (ev) {
		// Clicking the backdrop closes, clicking the panel does not.
		if (ev.target === el("help")) { toggle_help(false); }
	});
	el("helpbtn").addEventListener("click", function () { toggle_help(true); });
	el("themebtn").addEventListener("click", function () { window.I18n.toggle_theme(); });
	el("localebtn").addEventListener("click", function () { window.I18n.toggle_locale(); });
	el("settingsbtn").addEventListener("click", function () { toggle_settings(true); });
	el("settings-cancel").addEventListener("click", function () { toggle_settings(false); });
	el("settings").addEventListener("click", function (ev) {
		if (ev.target === el("settings")) { toggle_settings(false); }
	});
	el("settingsform").addEventListener("submit", save_settings);

	// The two global switches live in the queue pane's header, because they act on
	// everything rather than on a row - and putting them there keeps the row
	// buttons meaning "this download".
	function wire_global_button(id, command) {
		el(id).addEventListener("click", function () {
			run_command(el(id), command, {});
		});
	}
	wire_global_button("pauseall", "fluxget.pause_all");
	wire_global_button("resumeall", "fluxget.resume_all");
	wire_global_button("clearhistory", "fluxget.forget_all");

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