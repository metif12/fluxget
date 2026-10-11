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

	// log_line appends a diagnostic to the engine log - the one place in this app
	// that shows how Fluxget itself is behaving.
	//
	// The six status cards this replaces (engine phase, speed, queue count, aria2
	// path, transport, bridge) were all THIS. They were also a permanent quarter of
	// the window spent on facts a user looks at once, when something is wrong, and
	// a "ping -> pong" card is not a thing anyone needs to see every second. A log
	// line is the same information for someone who wants it and invisible to
	// everyone else.
	//
	// aria2's own lines arrive in the same pane through the tick, so the two are
	// interleaved in the order they happened, which is the order that makes a log
	// readable.
	function log_line(text) {
		var box = el("log");
		if (!box) { return; }
		box.textContent += (box.textContent ? "\n" : "") + text;
		// Keep the newest in view without stealing a scroll position the user chose:
		// if they have scrolled up to read a line, the log stops following.
		var atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 24;
		if (atBottom) { box.scrollTop = box.scrollHeight; }
	}

	// log_count is the badge on the developer disclosure: how many lines are
	// available. A collapsed disclosure with "0" on it is a mystery; with "137" it
	// is a promise.
	function log_count(n) {
		var node = el("log-count");
		if (!node) { return; }
		node.textContent = String(n);
		node.hidden = n <= 0;
	}

	// ---- locale and theme -------------------------------------------------

	// The locale button shows the language you would SWITCH TO, not the one you
	// are in. A button labelled with the current language is a toggle whose
	// meaning depends on the label, and nobody guesses that.
	function refresh_tool_labels() {
		// The locale button shows the language you would SWITCH TO, not the one you
		// are in. A button labelled with the current language is a toggle whose
		// meaning depends on the label, and nobody guesses that.
		var next = window.I18n.locale() === "fa" ? "en" : "fa";
		var names = { fa: "فارسی", en: "English" };
		el("localebtn").textContent = names[next];
		// The theme button carries no words at all - a glyph and an accessible name,
		// because the theme is a property of the whole window and not a thing it
		// makes sense to name twice.
		el("themebtn").setAttribute("aria-label", t("theme.toggle"));
		el("helpbody").textContent = t("shortcuts.body");
	}

	// ---- tabs -------------------------------------------------------------
	//
	// Below 900px the three panes are tabs; above it the tab bar is hidden and all
	// three are visible. The DOM is the same either way, so switching is a matter
	// of which pane carries .is-shown - a media query cannot remove a class, so
	// this runs on every tab click and is simply ignored when the panes are all
	// shown anyway.

	function show_tab(name) {
		var app = el("app");
		app.setAttribute("data-tab", name);
		var panes = document.querySelectorAll(".pane");
		for (var i = 0; i < panes.length; i++) {
			var on = panes[i].getAttribute("data-pane") === name;
			panes[i].classList.toggle("is-shown", on);
		}
		var tabs = document.querySelectorAll(".tab");
		for (var j = 0; j < tabs.length; j++) {
			tabs[j].setAttribute("aria-selected",
				tabs[j].getAttribute("data-tab") === name ? "true" : "false");
		}
		// The chart redraws when it becomes visible: a canvas in a display:none
		// pane has a zero-width box, so the size it measured while hidden is wrong
		// and the first visible frame is a squashed graph.
		if (name === "chart") {
			chart.resize();
			chart.draw();
		}
	}

	function wire_tabs() {
		var tabs = document.querySelectorAll(".tab");
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].addEventListener("click", function () {
				show_tab(this.getAttribute("data-tab"));
			});
		}
	}

	// set_badge keeps a tab's badge honest: how many downloads are live, and how
	// many rows are in error. It is the only chrome that changes on its own, and it
	// is how you know a download finished without switching tabs.
	function set_badge(id, n) {
		var node = el(id);
		if (!node) { return; }
		node.hidden = n <= 0;
		node.textContent = String(n);
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
		// A staggered entrance, so a queue assembles instead of arriving. Capped at
		// 12 rows' worth: past that the last row is over 300ms late, and a queue that
		// takes half a second to finish appearing is not a fast queue.
		row.style.animationDelay = Math.min(index, 12) * 22 + "ms";
		// Clicking the row itself opens its details. That is a delegation on the
		// list rather than a handler per row, so a re-render cannot leave a stale
		// listener pointing at a node that no longer exists.
		row.addEventListener("click", function (ev) {
			if (ev.target.closest(".act")) { return; }
			open_details(this.getAttribute("data-gid"));
		});

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

	// ---- categories -------------------------------------------------------
	//
	// Two kinds, and the difference is the whole point:
	//
	//  * BUILT-IN - "all", "downloading", "queued", "paused", "finished & failed" -
	//    derived from the row's own status. A user cannot delete these, because
	//    deleting "finished" would remove the queue's ability to show what is
	//    finished, and that is not a category, it is a view.
	//
	//  * NAMED - whatever the user creates. Stored in the settings document, so
	//    they survive a restart like every other preference.
	//
	// Mixing the two in one list is how a settings screen ends up offering to
	// delete "downloading".

	var BUILTIN = [
		{ id: "all", count: "count-all" },
		{ id: "active", count: "count-active" },
		{ id: "waiting", count: "count-waiting" },
		{ id: "paused", count: "count-paused" },
		{ id: "done", count: "count-done" }
	];

	var TERMINAL = ["complete", "error", "removed"];

	function category_of(status) {
		if (status === "active") { return "active"; }
		if (status === "waiting") { return "waiting"; }
		if (status === "paused") { return "paused"; }
		if (TERMINAL.indexOf(status) >= 0) { return "done"; }
		return "done";
	}

	// A NAMED category holds the gids a user put in it. The gids come from the
	// details dialog - "add to category" - rather than from a row button, because
	// a row button would compete with the pause/remove buttons already there.
	var current_detected = [];
	var named_categories = [];
	var active_category = "all";
	var row_category = {};

	function render_sidebar() {
		var list = el("category-list");
		var counts = { all: 0, active: 0, waiting: 0, paused: 0, done: 0 };
		var i;
		for (i = 0; i < last_downloads.length; i++) {
			var c = category_of(last_downloads[i].status);
			counts.all++;
			counts[c]++;
		}
		for (i = 0; i < BUILTIN.length; i++) {
			var node = el(BUILTIN[i].count);
			if (node) { node.textContent = String(counts[BUILTIN[i].id]); }
		}

		list.innerHTML = "";
		for (i = 0; i < named_categories.length; i++) {
			var c = named_categories[i];
			var in_it = 0;
			var j;
			for (j = 0; j < last_downloads.length; j++) {
				if (row_category[last_downloads[j].gid] === c.id) { in_it++; }
			}
			var item = document.createElement("button");
			item.className = "sidebar__item" + (active_category === c.id ? " is-on" : "");
			item.setAttribute("type", "button");
			item.setAttribute("data-cat", c.id);
			item.innerHTML = '<span class="sidebar__swatch" style="background:' +
				(c.colour || "var(--accent)") + '"></span><span></span>';
			item.children[1].textContent = c.name;
			var badge = document.createElement("span");
			badge.className = "sidebar__count";
			badge.textContent = String(in_it);
			item.appendChild(badge);
			item.addEventListener("click", function () {
				active_category = this.getAttribute("data-cat");
				render_sidebar();
				apply_filters();
			});
			list.appendChild(item);
		}
	}

	// apply_filters narrows the queue by the category and the search at once.
	//
	// Both are client-side and both read the tick that is already here, which is
	// the honest shape: there is no server to ask, the whole queue is in memory,
	// and a round trip per keystroke would be slower than the typing.
	function apply_filters() {
		var q = el("search").value.trim().toLowerCase();
		var visible = 0;
		var rows = el("rows").querySelectorAll(".row");
		var by_gid = {};
		var i;
		for (i = 0; i < last_downloads.length; i++) { by_gid[last_downloads[i].gid] = last_downloads[i]; }
		for (i = 0; i < rows.length; i++) {
			var gid = rows[i].getAttribute("data-gid");
			var d = by_gid[gid];
			if (!d) { continue; }
			var in_cat = active_category === "all" ||
				row_category[gid] === active_category ||
				(active_category !== "all" && row_category[gid] === undefined &&
					category_of(d.status) === active_category);
			var hit = q === "" || searchable(d).indexOf(q) >= 0;
			var show = in_cat && hit;
			rows[i].classList.toggle("is-hidden-by-search", !show);
			if (show) { visible++; }
		}
		el("empty").hidden = visible > 0;
		show_hits(q, visible);
	}

	// searchable is every field a search should reach, lowercased once per row.
	// It includes the error text, because "eof" is something a user searches for
	// after seeing a row go red and wanting to know why.
	function searchable(d) {
		return [d.name, d.status, d.dir, d.gid, d.error, d.total, d.done, d.speed]
			.join(" ").toLowerCase();
	}

	function show_hits(q, visible) {
		var box = el("search-hits");
		if (q === "") {
			box.hidden = true;
			return;
		}
		box.hidden = false;
		if (visible === 0) {
			box.textContent = window.I18n.fill(t("search.none"), { q: q });
			return;
		}
		box.innerHTML = window.I18n.fill(t("search.hits"),
			{ n: String(visible), total: String(last_downloads.length), q: q });
	}

	el("search").addEventListener("input", apply_filters);
	el("search").addEventListener("keydown", function (ev) {
		if (ev.key === "Escape") {
			this.value = "";
			apply_filters();
			this.blur();
		}
	});

	// The category list is rebuilt when a category is added or removed, and the
	// built-in counts come from render_sidebar, which the tick calls.
	el("category-add").addEventListener("click", function () {
		var name = window.prompt(t("category.new.prompt"), "");
		if (!name || !name.trim()) { return; }
		var c = { id: "cat-" + Date.now(), name: name.trim(), colour: "var(--accent)" };
		named_categories.push(c);
		render_sidebar();
		note({ kind: "info", text: window.I18n.fill(t("category.added"), { name: c.name }) });
	});


	// ---- dialogs ---------------------------------------------------------
	//
	// One helper for all of them, because they have the same three states (open,
	// close, dismiss on Escape and on a backdrop click) and writing that four times
	// is four chances to get the backdrop selector wrong. The Escape handler below
	// closes the TOP-most open dialog, not all of them, so a dialog opened from
	// inside a dialog closes only the inner one.

	function close_dialog(id) { el(id).hidden = true; }

	function open_dialog(id) { el(id).hidden = false; }

	// toggle_menu is the one place the menu's visibility is decided, and it is a
	// popover rather than a dialog so that a click outside closes it - "pause all"
	// is not worth a modal you have to dismiss to see its own effect.
	function toggle_menu(show) {
		var menu = el("menu");
		menu.hidden = (show === undefined) ? !menu.hidden : !show;
	}

	document.addEventListener("click", function (ev) {
		// Anything that is not the menu and not the button that opened it closes it.
		var menu = el("menu");
		if (!menu.hidden && !menu.contains(ev.target) &&
			ev.target !== el("menubtn") && !el("menubtn").contains(ev.target)) {
			menu.hidden = true;
		}
		// A click on an open dialog's backdrop dismisses it, and a click on the
		// panel does not - the target check is the whole difference.
		if (ev.target && ev.target.classList && ev.target.classList.contains("dialog")) {
			close_dialog(ev.target.id);
		}
	});

	// ---- the add dialog --------------------------------------------------

	function set_add_mode(mode) {
		var advanced = mode === "advanced";
		el("advanced-fields").hidden = !advanced;
		el("mode-simple").classList.toggle("tool--on", !advanced);
		el("mode-advanced").classList.toggle("tool--on", advanced);
	}

	// kind_of labels an address so the picker can show what will actually happen:
	// a .torrent path is added from bytes, a magnet from its own protocol, a url
	// from HTTP. Mixing them up is how the wrong thing gets downloaded.
	function kind_of(uri) {
		var lower = uri.toLowerCase();
		if (lower.indexOf("magnet:") === 0) { return "add.kind.magnet"; }
		if (lower.indexOf(".torrent") === lower.length - 8) { return "add.kind.torrent"; }
		return "add.kind.url";
	}

	function split_uris() {
		var lines = el("add-uris").value.split("\n");
		var out = [];
		var seen = {};
		for (var i = 0; i < lines.length; i++) {
			var v = lines[i].trim();
			if (v && !seen[v]) { seen[v] = true; out.push(v); }
		}
		return out;
	}

	function split_uris_text(text) {
		var lines = (text || "").split("\n");
		var out = [];
		var seen = {};
		for (var i = 0; i < lines.length; i++) {
			var v = lines[i].trim();
			// A pasted bare word is not an address, and adding it would produce a
			// download that fails in a way nobody can diagnose.
			if (v.length < 4 || seen[v]) { continue; }
			var lower = v.toLowerCase();
			if (lower.indexOf("http://") !== 0 && lower.indexOf("https://") !== 0 &&
				lower.indexOf("ftp://") !== 0 && lower.indexOf("magnet:") !== 0 &&
				lower.indexOf(".torrent") !== 4) { continue; }
			seen[v] = true;
			out.push(v);
		}
		return out;
	}

	// refresh_picker rebuilds the checkbox list, and hides it when there is only
	// one thing to add: a checkbox list of one is a control that does nothing.
	function refresh_picker() {
		current_detected = split_uris();
		var box = el("picker");
		if (current_detected.length < 2) { box.hidden = true; return; }
		box.hidden = false;

		var list = el("picker-list");
		list.innerHTML = "";
		for (var i = 0; i < current_detected.length; i++) {
			var uri = current_detected[i];
			var li = document.createElement("li");
			li.className = "picker__row";
			var cb = document.createElement("input");
			cb.type = "checkbox";
			cb.checked = true;
			cb.addEventListener("change", update_picker_count);
			li.appendChild(cb);
			var label = document.createElement("span");
			label.className = "picker__label";
			label.textContent = uri;
			label.title = uri;
			li.appendChild(label);
			var kind = document.createElement("span");
			kind.className = "picker__kind";
			kind.textContent = t(kind_of(uri));
			li.appendChild(kind);
			list.appendChild(li);
		}
		update_picker_count();
	}

	function update_picker_count() {
		var boxes = el("picker-list").querySelectorAll("input");
		var checked = 0;
		for (var i = 0; i < boxes.length; i++) { if (boxes[i].checked) { checked++; } }
		el("picker-count").textContent = window.I18n.fill(t("add.pick.count"),
			{ n: String(checked), total: String(boxes.length) });
	}

	// suggest_folder reads the URL's last path segment and offers a folder name.
	//
	// That is the honest extent of what can be guessed: the last segment is the
	// file, the one before it is what the file came from, and a guess that reaches
	// further than that is a guess the user has to undo. It is an OFFER - one click
	// puts it in the field - rather than a value the dialog sets on its own.
	function suggest_folder() {
		var text = el("add-uris").value.trim();
		var hint = el("folder-hint");
		var path = el("folder-path");
		if (!text) { hint.hidden = true; return; }
		var first = split_uris()[0] || "";
		var lower = first.toLowerCase();
		if (lower.indexOf("magnet:") === 0 || lower.indexOf(".torrent") === first.length - 8) {
			hint.hidden = true;
			return;
		}
		var parts = first.replace(/^[a-z]+:\/\/[^/]+/i, "").split("/");
		var guess = parts.length >= 2 ? parts[parts.length - 2] : "";
		if (!guess) { hint.hidden = true; return; }
		path.textContent = guess;
		hint.hidden = false;
	}

	el("add-uris").addEventListener("input", function () {
		refresh_picker();
		suggest_folder();
	});
	el("picker-all").addEventListener("click", function () {
		var boxes = el("picker-list").querySelectorAll("input");
		for (var i = 0; i < boxes.length; i++) { boxes[i].checked = true; }
		update_picker_count();
	});
	el("picker-none").addEventListener("click", function () {
		var boxes = el("picker-list").querySelectorAll("input");
		for (var i = 0; i < boxes.length; i++) { boxes[i].checked = false; }
		update_picker_count();
	});
	el("mode-simple").addEventListener("click", function () { set_add_mode("simple"); });
	el("mode-advanced").addEventListener("click", function () { set_add_mode("advanced"); });

	el("adddialog").addEventListener("click", function () {
		// The header box DRAFTS: whatever is in it seeds the dialog's textarea, so
		// a single address still reaches the advanced settings in one gesture.
		if (el("addurl").value.trim()) {
			el("add-uris").value = el("addurl").value.trim();
			el("addurl").value = "";
		}
		set_add_mode("simple");
		refresh_picker();
		suggest_folder();
		open_dialog("add-dialog");
		el("add-uris").focus();
	});

	// The clipboard button, and not an automatic read on open: a dialog that
	// silently reads the pasteboard is a dialog that gets closed in suspicion, and
	// the browser asks for a gesture anyway.
	el("clipboard-read").addEventListener("click", function () {
		function show(msg) { el("clipboard-hint").textContent = msg; }
		if (!navigator.clipboard || !navigator.clipboard.readText) {
			show(t("add.clipboard.failed", { detail: "no clipboard API" }));
			return;
		}
		navigator.clipboard.readText().then(function (text) {
			var lines = split_uris_text(text);
			if (lines.length === 0) { show(t("add.clipboard.empty")); return; }
			var existing = split_uris();
			var seen = {};
			var i;
			for (i = 0; i < existing.length; i++) { seen[existing[i]] = true; }
			var fresh = [];
			for (i = 0; i < lines.length; i++) {
				if (!seen[lines[i]]) { seen[lines[i]] = true; fresh.push(lines[i]); }
			}
			// Appended rather than replaced: the user may have typed into the box
			// already, and a clipboard read that threw that away would be a lie
			// about what "read" means.
			el("add-uris").value = existing.concat(fresh).join("\n");
			refresh_picker();
			suggest_folder();
			show(window.I18n.fill(t("add.clipboard.done"), { n: String(fresh.length) }));
		}).catch(function (e) {
			show(t("add.clipboard.failed", { detail: String(e) }));
		});
	});

	el("add-cancel").addEventListener("click", function () { close_dialog("add-dialog"); });

	// submit_add_batch adds every TICKED address, and tells the user what happened
	// rather than reporting the batch as a whole.
	function submit_add_batch() {
		var boxes = el("picker-list").querySelectorAll("input");
		var uris = [];
		if (el("picker").hidden || current_detected.length < 2) {
			uris = split_uris();
		} else {
			for (var i = 0; i < boxes.length; i++) {
				if (boxes[i].checked) { uris.push(boxes[i].getAttribute("data-uri")); }
			}
		}
		if (uris.length === 0) {
			note({ kind: "info", text: t("add.none") });
			return;
		}
		var payload = { uris: uris };
		if (el("advanced-fields").hidden === false) {
			if (el("add-dir").value.trim()) { payload.dir = el("add-dir").value.trim(); }
			if (el("add-out").value.trim()) { payload.out = el("add-out").value.trim(); }
			var n = parseInt(el("add-connections").value, 10);
			if (isFinite(n) && n > 0) { payload.max_connection = n; }
			payload.paused = el("add-paused").checked;
		}
		var button = el("add-submit");
		button.disabled = true;
		window.vails.call("fluxget.add", JSON.stringify(payload)).then(function (gid) {
			button.disabled = false;
			note({ kind: "added", gid: gid, name: uris[0],
				text: window.I18n.fill(t("add.added"), { name: uris[0] }) });
			el("add-uris").value = "";
			refresh_picker();
			suggest_folder();
			tick();
			close_dialog("add-dialog");
		}).catch(function (e) {
			button.disabled = false;
			note({ kind: "failed", name: uris[0], error: String(e), text: String(e) });
		});
	}

	el("addform-full").addEventListener("submit", function (ev) {
		ev.preventDefault();
		submit_add_batch();
	});

	// ---- the details dialog ----------------------------------------------
	//
	// A ROW's click opens the record. The row is a summary - eight fields - and
	// the dialog is everything else, fetched on demand because the file list and
	// the tracker list are separate aria2 calls that would otherwise run for every
	// row every second.

	var DETAIL_ROWS = [
		"details.status", "details.dir", "details.total", "details.done",
		"details.uploaded", "details.speed", "details.upload", "details.eta",
		"details.connections", "details.pieces", "details.piece_length",
		"details.verified_length", "details.info_hash", "details.seeders",
		"details.leechers"
	];

	function detail_value(d, key, i) {
		switch (key) {
			case "details.status": return d.status;
			case "details.dir": return d.dir;
			case "details.total": return d.total;
			case "details.done": return d.done;
			case "details.uploaded": return d.uploaded;
			case "details.speed": return d.speed;
			case "details.upload": return d.upload;
			case "details.eta": return d.eta;
			case "details.connections": return d.connections;
			case "details.pieces": return d.num_pieces ? String(d.num_pieces) : "";
			case "details.piece_length": return d.piece_length;
			case "details.verified_length": return d.verified_length;
			case "details.info_hash": return d.info_hash;
			case "details.seeders": return d.info_hash ? String(d.num_seeders) : "";
			case "details.leechers": return d.info_hash ? String(d.num_leechers) : "";
			default: return "";
		}
	}

	function open_details(gid) {
		if (!gid) { return; }
		var name = "";
		for (var i = 0; i < last_downloads.length; i++) {
			if (last_downloads[i].gid === gid) { name = last_downloads[i].name; }
		}
		el("details-name").textContent = name || gid;
		var list = el("detail-list");
		list.innerHTML = "";
		var row = document.createElement("div");
		row.className = "detail__row";
		var k = document.createElement("dt");
		k.className = "detail__k";
		k.textContent = t("details.gid");
		var v = document.createElement("dd");
		v.className = "detail__v";
		v.textContent = gid;
		row.appendChild(k);
		row.appendChild(v);
		list.appendChild(row);
		open_dialog("details");

		window.vails.call("fluxget.details", JSON.stringify({ gid: gid })).then(function (raw) {
			var d;
			try { d = JSON.parse(raw); } catch (e) { return; }
			fill_details(d);
		}).catch(function (e) {
			var failed = document.createElement("div");
			failed.className = "detail__row";
			failed.textContent = t("details.failed", { detail: String(e) });
			list.appendChild(failed);
		});
	}

	// fill_details shows what aria2 answered and HIDES nothing.
	//
	// An empty field is omitted rather than printed as "unknown": a torrent that
	// has not announced yet has no tracker, and "0 trackers" for a file that has
	// none of any kind is a false statement, not a missing one.
	function fill_details(d) {
		var list = el("detail-list");
		for (var i = 0; i < DETAIL_ROWS.length; i++) {
			var key = DETAIL_ROWS[i];
			var value = detail_value(d, key, i);
			if (!value) { continue; }
			list.appendChild(detail_row(t(key), value));
		}
		if (d.trackers && d.trackers.length) {
			list.appendChild(detail_row(t("details.trackers"), d.trackers.join("\n"), true));
		}
		if (d.files && d.files.length) {
			list.appendChild(detail_row(t("details.files"), d.files.join("\n"), true));
		}
		if (d.uris && d.uris.length) {
			var lines = [];
			for (var j = 0; j < d.uris.length; j++) {
				var live = d.live && d.live.indexOf(d.uris[j]) >= 0;
				lines.push((live ? "? " : "? ") + d.uris[j]);
			}
			list.appendChild(detail_row(t("details.uris"), lines.join("\n"), true));
		}
		// The actions button repeats the row's own buttons, so a dialog opened from
		// the keyboard can still act without going back to find the row.
		var actions = el("details-actions");
		actions.textContent = t("details.actions");
		actions.setAttribute("data-gid", d.gid);
	}

	function detail_row(label, value, is_list) {
		var row = document.createElement("div");
		row.className = "detail__row";
		var k = document.createElement("dt");
		k.className = "detail__k";
		k.textContent = label;
		var v = document.createElement("dd");
		v.className = "detail__v" + (is_list ? " detail__v--list" : "");
		v.textContent = value;
		row.appendChild(k);
		row.appendChild(v);
		return row;
	}

	el("details-close").addEventListener("click", function () { close_dialog("details"); });
	el("details-actions").addEventListener("click", function () {
		close_dialog("details");
		var gid = this.getAttribute("data-gid");
		if (gid) { move_selection(-9999); }
	});

	// ---- the settings pages ----------------------------------------------

	function show_settings_page(name) {
		var items = document.querySelectorAll(".settings__navitem");
		var pages = document.querySelectorAll(".settings-page");
		for (var i = 0; i < items.length; i++) {
			items[i].classList.toggle("is-on", items[i].getAttribute("data-page") === name);
		}
		for (var j = 0; j < pages.length; j++) {
			pages[j].classList.toggle("is-on", pages[j].getAttribute("data-page") === name);
		}
	}

	(function wire_settings_pages() {
		var items = document.querySelectorAll(".settings__navitem");
		for (var i = 0; i < items.length; i++) {
			items[i].addEventListener("click", function () {
				show_settings_page(this.getAttribute("data-page"));
			});
		}
	}());

	// ---- the menu --------------------------------------------------------

	el("menubtn").addEventListener("click", function (ev) {
		ev.stopPropagation();
		toggle_menu();
	});
	// The queue actions are routed through the same run_command the row buttons
	// use, so the menu, the keyboard and a future CLI all reach one place.
	el("menu-pauseall").addEventListener("click", function () {
		toggle_menu(false);
		run_command(el("menu-pauseall"), "fluxget.pause_all", {});
	});
	el("menu-resumeall").addEventListener("click", function () {
		toggle_menu(false);
		run_command(el("menu-resumeall"), "fluxget.resume_all", {});
	});
	el("menu-clearhistory").addEventListener("click", function () {
		toggle_menu(false);
		run_command(el("menu-clearhistory"), "fluxget.forget_all", {});
	});
	el("menu-settings").addEventListener("click", function () { toggle_menu(false); toggle_settings(true); });
	el("menu-developer").addEventListener("click", function () {
		toggle_menu(false);
		toggle_settings(true);
		show_settings_page("developer");
	});
	el("menu-theme").addEventListener("click", function () { window.I18n.toggle_theme(); });
	el("menu-locale").addEventListener("click", function () { window.I18n.toggle_locale(); });
	el("menu-help").addEventListener("click", function () { toggle_menu(false); toggle_help(true); });
	// ---- the log ----------------------------------------------------------

	function render_log(lines, dropped) {
		el("log").textContent = (lines || []).join("\n");
		el("log-count").textContent = String((lines || []).length) +
			(dropped > 0 ? " (+" + dropped + ")" : "");
	}

	// ---- one tick ---------------------------------------------------------

	function apply_tick(tick) {
		consecutiveErrors = 0;

		// The engine's phase goes to the log, not to a card. It is the one fact a
		// developer asks for and no user needs on screen every second - and the
		// six status cards that used to hold it were a permanent quarter of the
		// window. A missing aria2c is the exception and still gets the full-page
		// Setup screen, because that IS the user-facing state.
		log_line("engine: " + tick.phase + (tick.version ? " (aria2 " + tick.version + ")" : ""));
		if (tick.aria2_path) {
			log_line("aria2c: " + short_path(tick.aria2_path) + " [" + tick.aria2_source + "]");
		}

		el("setup").hidden = tick.phase !== "missing";
		if (tick.phase === "missing") {
			el("setup-detail").textContent = tick.detail || t("setup.body");
		}

		last_downloads = tick.downloads || [];
		render_rows(last_downloads, false);
		render_log(tick.logs, tick.logs_dropped);
		drain_notices(tick.notices);
		update_badges(tick);
		render_sidebar();
		apply_filters();

		if (chart) {
			chart.push(tick.stat.download_speed_b || 0, tick.stat.upload_speed_b || 0);
			chart.draw();
		}
	}

	// update_badges fills the two tab badges: how many downloads are live, and how
	// many rows are in error.
	//
	// It is in apply_tick and not in render_rows because it reads the SAME tick the
	// rows came from. A badge computed from a second, later read would be a number
	// the rest of the window disagrees with, and a count that disagrees with the
	// thing it counts is worse than no count.
	function update_badges(tick) {
		var list = tick.downloads || [];
		var live = 0;
		var failed = 0;
		for (var i = 0; i < list.length; i++) {
			var s = list[i].status;
			if (s === "active" || s === "waiting" || s === "paused") { live++; }
			if (s === "error") { failed++; }
		}
		set_badge("badge-active", live);
		set_badge("badge-errors", failed);
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
				log_line("tick: bad payload (" + e + "): " + String(raw).slice(0, 160));
				return;
			}
			try {
				apply_tick(frame);
			} catch (e) {
				log_line("tick: cannot render: " + e);
				return;
			}
		}).catch(function (e) {
			consecutiveErrors++;
			// The tick itself failing is worth saying out loud: it is the case
			// where the UI is showing stale numbers and the user needs to know.
			log_line("tick failed (" + consecutiveErrors + "): " + e);
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

	// ---- the folder hint and the settings dialog's button ---------------

	// The add dialog's folder suggestion is an OFFER: clicking it fills the folder
	// field with what the URL implied, rather than setting it. A folder picked by
	// the app is a folder the user has to discover and undo.
	el("folder-use").addEventListener("click", function () {
		el("add-dir").value = el("folder-path").textContent;
		el("folder-hint").hidden = true;
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
	el("settings").addEventListener("click", function (ev) {
		if (ev.target === el("settings")) { toggle_settings(false); }
	});
	el("helpbtn").addEventListener("click", function () { toggle_help(true); });
	el("themebtn").addEventListener("click", function () { window.I18n.toggle_theme(); });
	el("localebtn").addEventListener("click", function () { window.I18n.toggle_locale(); });
	wire_tabs();
	el("settings-cancel").addEventListener("click", function () { toggle_settings(false); });
	el("settings").addEventListener("click", function (ev) {
		if (ev.target === el("settings")) { toggle_settings(false); }
	});
	el("help").addEventListener("click", function (ev) {
		// Clicking the backdrop closes, clicking the panel does not.
		if (ev.target === el("help")) { toggle_help(false); }
	});
	el("settingsform").addEventListener("submit", save_settings);

	// ---- go ---------------------------------------------------------------

	function start() {
		window.I18n.init();
		refresh_tool_labels();
		chart = window.FluxChart.create(el("chart"));
		chart.resize();

		var is_dev = location.protocol === "http:";
		// Which of the two frontends is running. It used to be a status card, which
		// is a permanent row of the window spent on a fact that matters exactly
		// once - and it ellipsised, because it was too long for the card anyway.
		log_line("transport: " + (is_dev
			? window.I18n.fill(t("transport.dev"), { port: location.port })
			: t("transport.packed")));

		if (!window.vails || typeof window.vails.call !== "function") {
			// The one failure that is not a log line: with no runtime there is no
			// tick to read a log from, and a page that shows an empty queue with no
			// explanation is the blank window this whole transport layer exists to
			// avoid.
			log_line("bridge: no window.vails runtime");
			el("setup-detail").textContent = t("setup.body");
			el("setup").hidden = false;
			return;
		}
		log_line("bridge: window.vails.call");

		// The proof that a command with no grant is refused, re-checked on every
		// load. A command the capability does not grant must come back as a
		// REJECTION saying `forbidden:`, not a silent success and not
		// `unknown method:` - that difference is the security property the whole
		// design rests on.
		window.vails.call("fluxget.not_granted", "").then(function () {
			note({ kind: "failed", text: "UNEXPECTED: an ungranted command resolved" });
		}).catch(function (e) {
			log_line("capability gate: " + e);
		});

		window.vails.call("fluxget.ping", "").then(function (r) {
			log_line("bridge: ping → " + r);
		}).catch(function (e) {
			log_line("bridge: ping rejected: " + e);
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