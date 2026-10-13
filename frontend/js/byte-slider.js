// byte-slider.js — configuration for byte values.
//
// A plain number input is the wrong control for "how fast may this download
// go". The value is bytes per second and a human thinks in "4 MiB/s", so a bare
// field forces either arithmetic (and gets it wrong) or trial and error (and
// leaves it wrong).
//
// The stops are CURATED, not a linear sweep of 0..1 GiB. A linear range wastes
// most of the track: the whole usable band for a download limit is 64 KiB/s to
// 64 MiB/s, which is under a tenth of a 1 GiB track. A ladder of round values
// puts a real setting under every fraction of the track.
//
// WHY THE NUMBER FIELD SURVIVES
//
// The slider snaps. If the widget owned the value, opening Settings over a
// document holding something between two stops — aria2's own default
// `min-split-size` of 20 MiB is deliberately one of the stops now, and 5 MiB
// would not be — then saving would silently rewrite it. So the number field is
// the source of truth and the slider moves it to the nearest stop when dragged.

(function (global) {
	"use strict";

	// A rate ladder. Stop zero is "no limit", which is a value a user picks on
	// purpose, so it is a stop and not a floor.
	var RATE_STOPS = [
		0,
		16 * 1024,
		64 * 1024,
		256 * 1024,
		1024 * 1024,
		4 * 1024 * 1024,
		16 * 1024 * 1024,
		64 * 1024 * 1024,
		256 * 1024 * 1024,
		1024 * 1024 * 1024
	];

	// A size ladder. `20 MiB` is on it because that is aria2's own default for
	// min-split-size, and a ladder that cannot express the default would change
	// it on first save.
	var SIZE_STOPS = [
		1024,
		1024 * 1024,
		2 * 1024 * 1024,
		4 * 1024 * 1024,
		10 * 1024 * 1024,
		20 * 1024 * 1024,
		64 * 1024 * 1024,
		256 * 1024 * 1024,
		1024 * 1024 * 1024
	];

	function stops_for(kind) {
		return kind === "size" ? SIZE_STOPS : RATE_STOPS;
	}

	// nearest finds the ladder index closest to a value.
	//
	// Closest, rather than "next stop above": a document saying 5 MiB/s should
	// open with the thumb at 4 MiB and the field showing 5 MiB, agreeing with
	// each other. The two controls agreeing is the whole point of pairing them.
	function nearest(value, kind) {
		var steps = stops_for(kind);
		var best = 0;
		var bestGap = -1;
		for (var i = 0; i < steps.length; i++) {
			var gap = value > steps[i] ? value - steps[i] : steps[i] - value;
			if (bestGap < 0 || gap < bestGap) {
				bestGap = gap;
				best = i;
			}
		}
		return best;
	}

	// format renders a byte value, using the same rule chart.js draws with —
	// one decimal below ten, none above — and deliberately the same suffixes.
	// Two formatters is two answers to "how big is 7 MiB".
	function format(value, per_second) {
		var unit = per_second ? "/s" : "";
		var v = Number(value);
		if (!isFinite(v) || v <= 0) { return "0 B" + unit; }
		var suffixes = ["B", "KiB", "MiB", "GiB", "TiB"];
		var k = 0;
		while (v >= 1024 && k < suffixes.length - 1) { v /= 1024; k++; }
		var s = v < 10 ? v.toFixed(1) : String(Math.round(v));
		return s + " " + suffixes[k] + unit;
	}

	// label is what the readout says. A rate of zero reads "no limit" rather than
	// "0 B/s", because zero here is a choice and not an absence.
	function label(value, kind, zero_label) {
		var v = Number(value);
		if (!isFinite(v) || v <= 0) { return zero_label || "0 B"; }
		return format(v, kind !== "size");
	}

	// ---- the widget --------------------------------------------------------

	var registry = {};

	// mount wires one triple of controls together and registers it under a name,
	// so fill_settings and save_settings can address it by field name rather than
	// hunting DOM ids.
	//
	//   slider  <input type=range>
	//   number  <input type=number>   — the source of truth
	//   out     a <span>              — the human-readable readout
	function mount(opts) {
		var slider = document.getElementById(opts.slider);
		var number = document.getElementById(opts.number);
		var out = document.getElementById(opts.out);
		if (!slider || !number) { return null; }
		var kind = opts.kind || "rate";
		var zero = opts.zero || "no limit";
		slider.min = "0";
		slider.max = String(stops_for(kind).length - 1);
		slider.step = "1";

		function paint(readout_only) {
			var v = parse_int(number.value, 0);
			if (!readout_only) {
				slider.value = String(nearest(v, kind));
			}
			if (out) { out.textContent = label(v, kind, zero); }
		}

		slider.addEventListener("input", function () {
			var steps = stops_for(kind);
			var i = parseInt(this.value, 10) || 0;
			if (i < 0) { i = 0; }
			if (i >= steps.length) { i = steps.length - 1; }
			number.value = String(steps[i]);
			paint(true);
		});

		number.addEventListener("input", function () { paint(false); });

		registry[opts.name] = {
			kind: kind,
			zero: zero,
			paint: paint
		};
		paint(false);
		return registry[opts.name];
	}

	function parse_int(s, fallback) {
		var n = parseInt(s, 10);
		return isFinite(n) ? n : fallback;
	}

	// set paints a control and fills its exact field. Called from fill_settings.
	function set(name, value) {
		var w = registry[name];
		var number = document.getElementById("bynum-" + name);
		if (!w || !number) { return; }
		number.value = String(parse_int(String(value), 0));
		w.paint(false);
	}

	// value reads the exact field. Called from save_settings, so the document
	// keeps whatever the user actually typed.
	function value(name) {
		var number = document.getElementById("bynum-" + name);
		if (!number) { return 0; }
		var n = parse_int(number.value, 0);
		return n > 0 ? n : 0;
	}

	global.FluxSlider = {
		mount: mount,
		set: set,
		value: value,
		format: format,
		label: label,
		nearest: nearest,
		stops_for: stops_for
	};
}(window));