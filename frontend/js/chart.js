// chart.js — the speed chart.
//
// Why a canvas and not SVG
//
// The chart redraws once per tick, forever, and a DOM node per sample would mean
// tens of thousands of nodes a day for a two-line graph. Canvas draws the same
// pixels with no nodes at all, and the CSP allows it (nothing is fetched).
//
// Why the axis stays LTR even in a Persian document
//
// CONTEXT.md says numbers stay LTR. The same reasoning applies to the time axis:
// a series that runs right-to-left reads as "the future is on the left" to
// everyone, and the fix is not to reverse the axis but to keep the drawing
// direction fixed. The container therefore carries dir="ltr" regardless of the
// document's direction, which is the one place this file overrides i18n.
//
// Colours come from CSS custom properties, read back through getComputedStyle.
// A hard-coded hex in here would be a second source of truth for the palette and
// would not follow the theme switch at all - the chart would stay dark on a
// light page, which is exactly the kind of thing that survives a demo.
"use strict";

(function (global) {
	var WINDOW = 120;          // samples kept; at 1 tick/s that is two minutes
	var GRID = 3;              // horizontal guides

	function read_colour(node, name, fallback) {
		try {
			var v = global.getComputedStyle(node).getPropertyValue(name);
			return v && v.trim() ? v.trim() : fallback;
		} catch (e) {
			return fallback;
		}
	}

	// Series is the rolling sample buffer.
	function Series(capacity) {
		this.cap = capacity;
		this.down = [];
		this.up = [];
		this.peak = 0;
	}

	// push records one sample. A sample with a negative rate is clamped to zero:
	// a negative speed is not a thing, and letting it set the scale would render
	// the whole series flat against the top of the frame.
	Series.prototype.push = function (down, up) {
		var d = down > 0 ? down : 0;
		var u = up > 0 ? up : 0;
		this.down.push(d);
		this.up.push(u);
		if (this.down.length > this.cap) {
			this.down.shift();
			this.up.shift();
		}
		if (d > this.peak) { this.peak = d; }
		if (u > this.peak) { this.peak = u; }
	};

	Series.prototype.clear = function () {
		this.down = [];
		this.up = [];
		this.peak = 0;
	};

	// nice_scale picks a round ceiling above the peak, so the label reads
	// "8 MiB/s" rather than "7.4 MiB/s". A chart whose axis label is a
	// three-digit odd number is a chart nobody reads.
	function nice_scale(peak) {
		if (peak <= 0) { return 0; }
		var steps = [1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1];
		for (var i = 0; i < steps.length; i++) {
			var unit = steps[i];
			var mib = 1024 * 1024;
			if (peak >= mib * unit) { return mib * unit; }
			var kib = 1024;
			if (peak >= kib * unit) { return kib * unit; }
		}
		return peak;
	}

	// format_bytes mirrors engine/limits.v's rate_text: one decimal below ten,
	// none above. The native side formats every other number the UI shows, and a
	// chart with its own idea of "1.4 MiB/s" would be the one place the app
	// disagrees with itself.
	function format_bytes(v) {
		if (v <= 0) { return "0 B/s"; }
		if (v < 1024) { return v + " B/s"; }
		var x = v / 1024, unit = "KiB/s";
		if (x >= 1024) { x /= 1024; unit = "MiB/s"; }
		if (x >= 1024) { x /= 1024; unit = "GiB/s"; }
		return (x < 10 ? x.toFixed(1) : String(Math.round(x))) + " " + unit;
	}

	function Chart(canvas) {
		this.canvas = canvas;
		this.ctx = canvas.getContext ? canvas.getContext("2d") : null;
		this.series = new Series(WINDOW);
		this.resize = this.resize.bind(this);
		if (global.addEventListener) {
			global.addEventListener("resize", this.resize);
		}
	}

	Chart.prototype.push = function (down, up) {
		this.series.push(down, up);
	};

	Chart.prototype.clear = function () {
		this.series.clear();
	};

	// size fixes the backing store to the element's CSS box and the context
	// scale to the device pixel ratio, so the graph is not blurry on a HiDPI
	// screen - which is most of them.
	Chart.prototype.resize = function () {
		if (!this.ctx) { return; }
		var ratio = global.devicePixelRatio || 1;
		var rect = this.canvas.getBoundingClientRect();
		var w = Math.max(1, Math.round(rect.width));
		var h = Math.max(1, Math.round(rect.height));
		this.canvas.width = w * ratio;
		this.canvas.height = h * ratio;
		this.ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
		this.w = w;
		this.h = h;
	};

	Chart.prototype.draw = function () {
		if (!this.ctx) { return; }
		if (!this.w) { this.resize(); }
		if (!this.w) { return; }

		var ctx = this.ctx;
		var w = this.w, h = this.h;
		var pad = 4;

		var down_col = read_colour(this.canvas, "--chart-down", "#4cc2ff");
		var up_col = read_colour(this.canvas, "--chart-up", "#43d18b");
		var grid_col = read_colour(this.canvas, "--chart-grid", "#232830");
		var text_col = read_colour(this.canvas, "--text-faint", "#6b7382");

		ctx.clearRect(0, 0, w, h);

		var s = this.series;
		var scale = nice_scale(s.peak);
		if (scale <= 0) {
			// The empty state says so in words rather than drawing a flat line at
			// zero, which looks like a measurement.
			ctx.fillStyle = text_col;
			ctx.font = "11px " + read_colour(this.canvas, "--mono", "monospace");
			ctx.textAlign = "center";
			ctx.textBaseline = "middle";
			ctx.fillText(global.I18n ? global.I18n.t("chart.empty") : "no data yet",
				w / 2, h / 2);
			return;
		}

		// Guides, and the scale label at the top.
		ctx.strokeStyle = grid_col;
		ctx.lineWidth = 1;
		ctx.fillStyle = text_col;
		ctx.font = "10px " + read_colour(this.canvas, "--mono", "monospace");
		ctx.textAlign = "start";
		ctx.textBaseline = "top";
		for (var g = 0; g <= GRID; g++) {
			var gy = Math.round(pad + (h - pad * 2) * (g / GRID)) + 0.5;
			ctx.beginPath();
			ctx.moveTo(pad, gy);
			ctx.lineTo(w - pad, gy);
			ctx.stroke();
			if (g > 0) {
				var frac = 1 - (g / GRID);
				ctx.fillText(format_bytes(Math.round(scale * frac)), pad + 2, gy + 2);
			}
		}

		var plot_h = h - pad * 2;
		var n = s.down.length;
		// The series is drawn right-aligned so the newest sample is at the right
		// edge and the graph scrolls leftwards as time passes. Right-aligned also
		// means a partially-filled buffer grows from the right rather than
		// stretching, which is what makes the first minute readable.
		var span = Math.max(n - 1, 1);
		function x_of(i) {
			return w - pad - ((n - 1 - i) / span) * (w - pad * 2);
		}
		function y_of(v) {
			return pad + plot_h - (v / scale) * plot_h;
		}

		function area(values, colour, fill_alpha) {
			ctx.beginPath();
			ctx.moveTo(x_of(0), y_of(0));
			for (var i = 0; i < values.length; i++) {
				ctx.lineTo(x_of(i), y_of(values[i]));
			}
			ctx.lineTo(x_of(values.length - 1), y_of(0));
			ctx.closePath();
			ctx.globalAlpha = fill_alpha;
			ctx.fillStyle = colour;
			ctx.fill();
			ctx.globalAlpha = 1;
			ctx.strokeStyle = colour;
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			for (var k = 0; k < values.length; k++) {
				var px = x_of(k), py = y_of(values[k]);
				if (k === 0) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
			}
			ctx.stroke();
		}

		area(s.down, down_col, 0.18);
		area(s.up, up_col, 0.12);
	};

	global.FluxChart = {
		create: function (canvas) { return new Chart(canvas); },
		format_bytes: format_bytes,
		nice_scale: nice_scale
	};
}(window));