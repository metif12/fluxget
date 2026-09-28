// boot.js — the whole frontend, Phase 1.
//
// Two things here are load-bearing and both come from the framework's rules:
//
//   1. The page POLLS. fluxget.tick is called on an interval and nothing is ever
//      pushed at us. vails ADR-0010 forbids V->JS eval from a spawned worker, and
//      aria2's completion hooks are a shell-out rather than a callback, so
//      polling is not a shortcut here - it is the only shape available. The
//      native side queues what changed (core/notice.v) and hands it over in the
//      next tick.
//
//   2. Every value rendered here is a string the native side formatted
//      (engine/limits.v). The page never rounds a byte count itself, because
//      "1.4 MiB/s" appearing two different ways in two panels is a bug nobody
//      reports.
//
// Plain ES5 and no modules: the vails CSP is default-src 'self', and the packed
// production document inlines everything anyway.
"use strict";

(function () {
	// ---- how often --------------------------------------------------------
	//
	// 1s. Each tick is ONE system.multicall on loopback, so the cost is a single
	// request; the limit is what the user sees, and a queue that updates twice a
	// second is harder to read than one that updates once.
	//
	// Not re-entrant: a tick that takes longer than the interval must not stack
	// up behind itself, or a wedged daemon turns into a growing pile of pending
	// calls. `inFlight` is the whole guard.
	var TICK_MS = 1000;
	var inFlight = false;
	var consecutiveErrors = 0;

	function el(id) {
		return document.getElementById(id);
	}

	function set(key, value, state) {
		var node = el("v-" + key);
		if (!node) { return; }
		node.textContent = value;
		node.setAttribute("data-state", state || "ok");
	}

	// ---- transport and the round trip -------------------------------------

	var isDev = location.protocol === "http:";
	set("transport", isDev ? "dev server  :" + location.port : "packed document (set_html)", "ok");

	if (!window.vails || typeof window.vails.call !== "function") {
		set("bridge", "no window.vails runtime", "err");
		set("engine", "opened outside a Vails window", "err");
		document.getElementById("setup-detail").textContent =
			"This page was opened in a plain browser. The bridge is only available inside a Vails window.";
		document.getElementById("setup").hidden = false;
		return;
	}
	set("bridge", "window.vails.call present", "ok");

	// ---- notices ---------------------------------------------------------
	//
	// The native side drains its queue into every tick, and a notice is delivered
	// exactly once. The last one we showed is remembered so a re-render does not
	// repeat it - which is what would happen if the same tick payload were
	// painted twice.
	var shownNotices = 0;
	var noticesSeen = 0;

	function toast(n) {
		var box = el("toasts");
		var node = document.createElement("div");
		node.className = "toast";
		node.setAttribute("data-kind", n.kind);
		node.textContent = n.text;
		box.appendChild(node);
		// Auto-dismiss, because a queue of permanent toasts is a second queue.
		window.setTimeout(function () {
			if (node.parentNode) { node.parentNode.removeChild(node); }
		}, 6000);
	}

	function drainNotices(list) {
		if (!list || !list.length) { return; }
		for (var i = 0; i < list.length; i++) {
			// Skip anything we have already shown, so a redraw is idempotent.
			if (noticesSeen + i < shownNotices) { continue; }
			toast(list[i]);
		}
		noticesSeen += list.length;
		shownNotices = noticesSeen;
	}

	// ---- the queue --------------------------------------------------------

	// aria2's Status vocabulary, passed through unchanged (CONTEXT.md). The class
	// is derived from the word so a new aria2 state renders as neutral rather
	// than inheriting the last row's colour.
	function statusClass(s) {
		if (s === "active") { return "is-active"; }
		if (s === "complete") { return "is-complete"; }
		if (s === "error") { return "is-error"; }
		if (s === "waiting") { return "is-waiting"; }
		if (s === "paused") { return "is-paused"; }
		return "is-other";
	}

	function percentWidth(pct) {
		var n = Number(pct);
		if (!isFinite(n) || n < 0) { return "0%"; }
		if (n > 100) { return "100%"; }
		return n.toFixed(1) + "%";
	}

	function renderRows(downloads) {
		var box = el("rows");
		var list = downloads || [];
		el("queue-count").textContent = String(list.length);
		el("empty").hidden = list.length > 0;

		// Rebuild only when the shape changed. At 1Hz, tearing down and rebuilding
		// the whole list every tick would kill text selection mid-drag and flicker
		// every progress bar.
		var signature = list.map(function (d) { return d.gid + ":" + d.status; }).join("|");
		if (box.dataset.signature === signature) {
			// Same rows, same states: update only the numbers.
			var bars = box.querySelectorAll("[data-gid]");
			for (var i = 0; i < bars.length; i++) {
				var gid = bars[i].getAttribute("data-gid");
				var d = findRow(list, gid);
				if (!d) { continue; }
				bars[i].querySelector(".row__bar").style.width = percentWidth(d.percent);
				bars[i].querySelector(".row__pct").textContent = percentWidth(d.percent);
				bars[i].querySelector(".row__done").textContent = d.done + " / " + d.total;
				bars[i].querySelector(".row__speed").textContent = d.speed;
				bars[i].querySelector(".row__eta").textContent = d.eta;
			}
			return;
		}

		box.dataset.signature = signature;
		box.innerHTML = "";
		for (var j = 0; j < list.length; j++) {
			box.appendChild(rowNode(list[j]));
		}
	}

	function findRow(list, gid) {
		for (var i = 0; i < list.length; i++) {
			if (list[i].gid === gid) { return list[i]; }
		}
		return null;
	}

	function rowNode(d) {
		var row = document.createElement("article");
		row.className = "row " + statusClass(d.status);
		row.setAttribute("data-gid", d.gid);

		var head = document.createElement("div");
		head.className = "row__head";

		var name = document.createElement("span");
		name.className = "row__name";
		// title carries the full path, because the name is derived by the native
		// side and a truncated torrent name is useless without it.
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
		bar.style.width = percentWidth(d.percent);
		track.appendChild(bar);
		row.appendChild(track);

		var foot = document.createElement("div");
		foot.className = "row__foot";
		foot.appendChild(span("row__done", d.done + " / " + d.total));
		foot.appendChild(span("row__pct", percentWidth(d.percent)));
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

	// ---- the log ----------------------------------------------------------

	function renderLog(lines, dropped) {
		var node = el("log");
		// Newest first, which is the order the native ring returns.
		node.textContent = (lines || []).join("\n");
		el("log-count").textContent = String((lines || []).length) +
			(dropped > 0 ? " (+" + dropped + " older)" : "");
	}

	// ---- one tick ---------------------------------------------------------

	function applyTick(t) {
		consecutiveErrors = 0;

		// The engine row leads with the PHASE, because that is the word the whole
		// UI branches on. `restart_in_ms` is included so a backoff reads as a wait
		// rather than as a hang.
		var engineText = t.version ? t.version : t.phase;
		if (!t.ok) {
			engineText = t.phase + (t.detail ? " — " + t.detail : "");
		} else if (t.restart_in_ms > 0) {
			engineText += "  (retry in " + Math.ceil(t.restart_in_ms / 1000) + "s)";
		}
		set("engine", engineText, t.ok ? "ok" : (t.phase === "missing" ? "err" : "warn"));

		set("speed", t.ok ? (t.stat.download_speed + "  down   " + t.stat.upload_speed + "  up") : "—",
			t.ok ? "ok" : "warn");

		set("queue", t.stat.num_active + " active · " + t.stat.num_waiting +
			" waiting · " + t.stat.num_stopped + " done", "ok");

		// Which binary, and which of the four search rules found it. "aria2c" alone
		// leaves a user guessing which copy their downloads go through.
		set("aria2", t.aria2_path
			? shortPath(t.aria2_path) + "  [" + t.aria2_source + "]"
			: "not found", t.aria2_path ? "ok" : "err");

		document.getElementById("setup").hidden = t.phase !== "missing";
		if (t.phase === "missing") {
			document.getElementById("setup-detail").textContent = t.detail ||
				"aria2c was not found in any of the usual places.";
		}

		renderRows(t.downloads);
		renderLog(t.logs, t.logs_dropped);
		drainNotices(t.notices);
	}

	function shortPath(p) {
		var parts = p.split(/[\\\/]/);
		return parts.length > 2 ? "…\\" + parts[parts.length - 2] + "\\" + parts[parts.length - 1] : p;
	}

	function tick() {
		if (inFlight) { return; }
		inFlight = true;
		window.vails.call("fluxget.tick", "").then(function (raw) {
			var frame;
			// Parse and render are separated, and the two failures are reported
			// differently, because they are different bugs. Wrapping both in one
			// try meant a crash inside renderRows was reported as "malformed JSON"
			// - which sent the search to the native side for a fault that was in
			// this file. An error message that misdirects is worse than none.
			try {
				frame = JSON.parse(raw);
			} catch (e) {
				set("engine", "tick payload is not JSON (" + e + "): " +
					String(raw).slice(0, 160), "err");
				return;
			}
			try {
				applyTick(frame);
			} catch (e) {
				set("engine", "tick could not be rendered: " + e, "err");
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

	document.getElementById("addform").addEventListener("submit", function (ev) {
		ev.preventDefault();
		var input = el("addurl");
		var value = input.value.trim();
		if (!value) { return; }
		var btn = el("addbtn");
		btn.disabled = true;

		// The payload is exactly AddParams from the manifest. An empty `dir` and
		// `out` are sent rather than omitted, because the struct is what the
		// .d.ts declares and the native side treats an absent key as an empty one
		// anyway - one shape is easier to keep honest than two.
		window.vails.call("fluxget.add", JSON.stringify({
			uris: [value],
			dir: "",
			out: "",
			paused: false
		})).then(function (gid) {
			// The gid is the only handle the rest of Fluxget has, so it is worth
			// showing: it is what a bug report needs.
			toast({ kind: "info", text: "Added — gid " + gid });
			input.value = "";
			tick();
		}).catch(function (e) {
			// Refusals are the native side's own sentences (aria2's message, or the
			// reason the request was malformed). Shown verbatim rather than
			// rephrased, because "add failed" is not something anyone can act on.
			toast({ kind: "failed", text: String(e) });
		}).then(function () {
			btn.disabled = false;
			input.focus();
		});
	});

	// ---- the proof that a command with no grant is refused ----------------

	// Kept from Phase 0 and still the most important line in this file: a command
	// the capability does not grant must come back as a REJECTION saying
	// `forbidden:`, not a silent success and not `unknown method:`. The
	// difference between "denied" and "does not exist" is the security property
	// the whole design rests on, so it is re-checked on every load.
	window.vails.call("fluxget.not_granted", "").then(function () {
		toast({ kind: "failed", text: "UNEXPECTED: an ungranted command resolved" });
	}).catch(function (e) {
		console.info("capability gate: " + e);
	});

	// ---- go ---------------------------------------------------------------

	window.vails.call("fluxget.ping", "").then(function (r) {
		set("bridge", "ping → " + r, r === "pong" ? "ok" : "warn");
	}).catch(function (e) {
		set("bridge", "ping rejected: " + e, "err");
	});

	tick();
	window.setInterval(tick, TICK_MS);
}());
