// boot.js — Phase 0 smoke page. Proves the chain works in both transports:
//   dev server + livereload  ->  window.vails.call  ->  capability grant
//   ->  platform handler     ->  JSON back to the page
//
// Plain ES5, no modules, no bundler: the vails CSP is default-src 'self'
// and the packed production document inlines everything anyway.
"use strict";

(function () {
	var out = document.getElementById("log");
	function say(line) {
		out.textContent += line + "\n";
	}

	function set(key, value, state) {
		var el = document.getElementById("v-" + key);
		if (!el) { return; }
		el.textContent = value;
		el.setAttribute("data-state", state || "ok");
	}

	var isDev = location.protocol === "http:";
	set("transport", isDev ? "dev server  " + location.port : "packed document (set_html)", "ok");

	if (!window.vails || typeof window.vails.call !== "function") {
		set("bridge", "no window.vails runtime", "err");
		say("no window.vails runtime — opened outside a Vails window");
		return;
	}
	set("bridge", "window.vails.call present", "ok");

	window.vails.call("fluxget.ping", "").then(function (r) {
		set("bridge", "ping -> " + r, r === "pong" ? "ok" : "warn");
		say("fluxget.ping -> " + r);
	}).catch(function (e) {
		set("bridge", "ping rejected: " + e, "err");
		say("ping rejected: " + e);
	});

	window.vails.call("fluxget.info", "").then(function (r) {
		say("info: " + r);
		var vails = document.getElementById("vails");
		if (vails) {
			vails.textContent = r;
			vails.setAttribute("data-state", "ok");
		}
	}).catch(function (e) {
		say("info rejected: " + e);
	});

	window.vails.call("fluxget.health", "").then(function (r) {
		var h = JSON.parse(r);
		set("engine", h.connected ? "connected " + h.aria2 : h.mode + ": " + h.detail, h.connected ? "ok" : "warn");
		say("health: " + r);
	}).catch(function (e) {
		set("engine", "rejected: " + e, "err");
		say("health rejected: " + e);
	});

	// A command the capability does not grant must come back as a rejection,
	// not a silent success: that is the vails T2 gate doing its job.
	window.vails.call("fluxget.not_granted", "").then(function () {
		say("UNEXPECTED: ungranted command resolved");
	}).catch(function (e) {
		say("ungranted command rejected as expected: " + e);
	});
}());
