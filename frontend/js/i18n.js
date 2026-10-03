// i18n.js — the Locale layer.
//
// CONTEXT.md: "Locale — `fa` (RTL) or `en` (LTR). Switchable at runtime;
// direction is a document attribute, spacing is logical properties, numbers stay
// LTR."
//
// Three decisions worth stating, because each one is a trap:
//
// 1. DIRECTION IS A DOCUMENT ATTRIBUTE. `<html dir>` and `<html lang>` are the
//    only place direction lives. A `dir` on a subtree would make the R2L
//    override local to some panels and leave the rest LTR, which is how a
//    half-translated UI happens.
//
// 2. NUMBERS STAY LTR. A Persian UI still writes "128 MiB/s" and not a
//    Persian-digit, reordered form. Digits are handled by the native side
//    (engine/limits.v formats every byte count), so there is nothing to
//    localise here and nothing that *could* get it wrong - which is the point of
//    keeping formatting in one language.
//
// 3. THE NOTICE GRAMMAR IS COMPOSED HERE, IN ONE PLACE. The native side sends
//    the FACTS of an event (kind, the download's name, aria2's error text) and
//    this file turns them into a sentence. It used to be the other way round:
//    core/notice.v wrote an English sentence in `text`, which is untranslatable
//    and therefore means a Persian UI toasts in English. CONTEXT.md said "nothing
//    rephrases a Notice" so two components would not invent competing wording for
//    one event - and that intent is preserved by having ONE composer here rather
//    than by freezing the language. `text` still ships, unchanged, for the Logs
//    tab, the CLI and the MCP server, which have no locale.
"use strict";

(function (global) {
	var DICT = {
		en: {
			"lang.name": "English",
			"app.tagline": "aria2 download manager · built on vails",

			"card.engine": "engine",
			"card.speed": "speed",
			"card.queue": "queue",
			"card.aria2": "aria2c",
			"card.transport": "transport",
			"card.bridge": "bridge",

			// Short, because this lives in a card that ellipsises. The long version
			// ("packed document (set_html)") is what I wrote first, and it rendered as
			// "packed document (set_ht…" - which tells a user nothing, because the
			// interesting half is the part that got cut.
			"transport.packed": "packed",
			"transport.dev": "dev :${port}",

			"pane.downloads": "downloads",
			"pane.log": "engine log",
			"pane.speed": "speed",

			"empty.queue": "Nothing queued. Add a URL above.",
			"add.placeholder": "https://  ·  magnet:?xt=urn:btih:…  ·  C:\\path\\to\\file.torrent",
			"add.aria": "URL, magnet link or path to a .torrent to download",
			"add.button": "Add",

			"setup.title": "aria2c is not installed",
			"setup.note": "Then restart Fluxget. It picks the binary up from runtime\\ automatically.",
			"setup.body": "It was looked for beside the executable, in runtime\\, and on PATH.",

			"notice.added": "Added {name}",
			"notice.finished": "Finished {name}",
			"notice.finished.seeding": "Finished seeding {name}",
			"notice.failed": "Failed {name}: {reason}",
			"notice.removed": "Removed {name}",
			"notice.info": "{text}",
			"notice.failed.noreason": "no reason given",

"theme.toggle": "theme",
			"locale.toggle": "language",
			"shortcuts.title": "Keyboard shortcuts",
			"shortcuts.close": "close",
			// Only keys that are actually bound. The list used to promise space,
			// ctrl+arrows and pause/resume, none of which were wired - and a help
			// dialog that documents features which do not exist is worse than no
			// help dialog, because it teaches the reader to trust the wrong thing.
			// Pause, resume and reorder are Phase 3 commands; the line comes back
			// in the same commit that adds them.
			"shortcuts.body":
				"/            focus the add box\n" +
				"\u2191 \u2193          select a download\n" +
				"space        pause or resume the selection\n" +
				"ctrl + \u2191 \u2193   move it in the queue\n" +
				"delete       remove the selection\n" +
				"r            retry the selection\n" +
				"a            add whatever is in the add box\n" +
				"s            settings\n" +
				"t            toggle the theme\n" +
				"l            toggle fa / en\n" +
				"?            this list\n" +
				"esc          close this",
			"shortcuts.none-selected": "Nothing is selected. The arrow keys select a download.",
			"shortcuts.not-applicable": "{action} does not apply to this download.",
			"chart.empty": "waiting for the first sample",

			// ---- row actions
			"row.pause": "pause",
			"row.resume": "resume",
			"row.retry": "retry",
			"row.remove": "remove",
			"row.forget": "forget",
			"row.seeding": "seeding",

			// ---- queue-wide
			"queue.pauseall": "pause all",
			"queue.resumeall": "resume all",
			"queue.clear": "clear history",

			// ---- settings
			"settings.open": "settings",
			"settings.title": "Settings",
			"settings.save": "save",
			"settings.cancel": "close",
			"settings.saved": "Settings saved and applied.",
			"settings.legend.limits": "limits",
			"settings.legend.place": "files",
			"settings.max_concurrent": "downloads at once",
			"settings.max_per_server": "connections each",
			"settings.split": "split",
			"settings.min_split_size": "smallest split (bytes)",
			"settings.download_limit": "download limit (bytes/s, 0 = unlimited)",
			"settings.upload_limit": "upload limit (bytes/s, 0 = unlimited)",
			"settings.dir": "download folder (empty = your Downloads)",
			"settings.bt_enabled": "BitTorrent",
			"settings.save_session": "remember the queue across restarts",
			"settings.seed_ratio": "seed ratio",
			"settings.seed_time": "seed time (min, 0 = forever)",
			"settings.refused": "Not applied: {detail}",
			"settings.bad-payload": "The settings came back unreadable: {detail}",

			"engine.never-started": "not started yet",
			"engine.missing": "not installed",
			"engine.starting": "starting…",
			"engine.ready": "ready",
			"engine.crashed": "crashed",
			"engine.stopping": "stopping",
			"engine.stopped": "stopped",
			"engine.retrying": "retrying in {n}s",
			"engine.source": "via {source}"
		},

		fa: {
			"lang.name": "فارسی",
			"app.tagline": "مدیریت دانلود aria2 · ساخته‌شده با vails",

			"card.engine": "موتور",
			"card.speed": "سرعت",
			"card.queue": "صف",
			"card.aria2": "aria2c",
			"card.transport": "انتقال",
			"card.bridge": "پل",

			"transport.packed": "بسته‌شده",
			"transport.dev": "توسعه :${port}",

			"pane.downloads": "دانلودها",
			"pane.log": "گزارش موتور",
			"pane.speed": "نمودار سرعت",

			"empty.queue": "صف خالی است. یک نشانی بالا بیفزایید.",
			"add.placeholder": "https://  ·  magnet:?xt=urn:btih:…  ·  C:\\path\\to\\file.torrent",
			"add.aria": "نشانی، پیوند مگنت یا مسیر یک فایل تورنت برای دانلود",
			"add.button": "افزودن",

			"setup.title": "aria2c نصب نیست",
			"setup.note": "سپس Fluxget را دوباره اجرا کنید. مسیر آن را خودکار از runtime\\ پیدا می‌کند.",
			"setup.body": "کنار فایل اجرایی، در runtime\\ و در PATH جست‌وجو شد.",

			"notice.added": "افزوده شد: {name}",
			"notice.finished": "پایان یافت: {name}",
			"notice.finished.seeding": "پخش (سید) پایان یافت: {name}",
			"notice.failed": "ناموفق: {name} — {reason}",
			"notice.removed": "حذف شد: {name}",
			"notice.info": "{text}",
			"notice.failed.noreason": "دلیلی داده نشد",

			"theme.toggle": "پوسته",
			"locale.toggle": "زبان",
			"shortcuts.title": "کلیدهای میان‌بر",
			"shortcuts.close": "بستن",
			"shortcuts.body":
				"/            رفتن به کادر افزودن\n" +
				"↑ ↓          انتخاب یک دانلود\n" +
				"space        مکث یا ادامهٔ انتخاب‌شده\n" +
				"ctrl + ↑ ↓   جابه‌جایی در صف\n" +
				"delete       حذف انتخاب‌شده\n" +
				"r            تلاش دوباره برای انتخاب‌شده\n" +
				"a            افزودن محتوای کادر\n" +
				"s            تنظیمات\n" +
				"t            تغییر پوسته\n" +
				"l            تغییر فارسی / انگلیسی\n" +
				"?            همین فهرست\n" +
				"esc          بستن",
			"shortcuts.none-selected": "هیچ‌چیز انتخاب نشده است. با کلیدهای جهت یک دانلود را انتخاب کنید.",
			"shortcuts.not-applicable": "{action} برای این دانلود معنا ندارد.",
			"chart.empty": "منتظر نخستین نمونه",

			// ---- row actions
			"row.pause": "مکث",
			"row.resume": "ادامه",
			"row.retry": "تلاش دوباره",
			"row.remove": "حذف",
			"row.forget": "پاک کردن",
			"row.seeding": "در حال پخش",

			// ---- queue-wide
			"queue.pauseall": "مکث همه",
			"queue.resumeall": "ادامهٔ همه",
			"queue.clear": "پاک کردن تاریخچه",

			// ---- settings
			"settings.open": "تنظیمات",
			"settings.title": "تنظیمات",
			"settings.save": "ذخیره",
			"settings.cancel": "بستن",
			"settings.saved": "تنظیمات ذخیره و اعمال شد.",
			"settings.legend.limits": "محدودیت‌ها",
			"settings.legend.place": "فایل‌ها",
			"settings.max_concurrent": "تعداد هم‌زمان",
			"settings.max_per_server": "اتصال برای هرکدام",
			"settings.split": "تقسیم",
			"settings.min_split_size": "کوچک‌ترین بخش (بایت)",
			"settings.download_limit": "سقف دانلود (بایت بر ثانیه، ۰ = بدون سقف)",
			"settings.upload_limit": "سقف آپلود (بایت بر ثانیه، ۰ = بدون سقف)",
			"settings.dir": "پوشهٔ دانلود (خالی = Downloads شما)",
			"settings.bt_enabled": "بیت‌تورنت",
			"settings.save_session": "به یاد سپردن صف پس از بستن برنامه",
			"settings.seed_ratio": "نسبت پخش",
			"settings.seed_time": "زمان پخش (دقیقه، ۰ = همیشه)",
			"settings.refused": "اعمال نشد: {detail}",
			"settings.bad-payload": "تنظیمات خوانده نشد: {detail}",

			"engine.never-started": "هنوز آغاز نشده",
			"engine.missing": "نصب نیست",
			"engine.starting": "در حال آغاز…",
			"engine.ready": "آماده",
			"engine.crashed": "سقوط کرد",
			"engine.stopping": "در حال خاموش شدن",
			"engine.stopped": "متوقف",
			"engine.retrying": "تلاش دوباره در {n} ثانیه",
			"engine.source": "از {source}"
		}
	};

	var LOCALES = ["fa", "en"];
	var STORAGE_KEY = "fluxget.locale";
	var THEME_KEY = "fluxget.theme";

	// current is the active locale. Persian is the default: it is the project's
	// first language, and the UI is built RTL-first rather than translated into
	// RTL afterwards, which is the only way the layout ends up right.
	var current = "fa";

	function t(key) {
		var table = DICT[current] || DICT.en;
		if (Object.prototype.hasOwnProperty.call(table, key)) { return table[key]; }
		// English is the fallback so a missing Persian key shows a readable string
		// rather than the key itself. A visible key is a bug report; "undefined"
		// is not.
		if (Object.prototype.hasOwnProperty.call(DICT.en, key)) { return DICT.en[key]; }
		return key;
	}

	// fill substitutes {name}-style placeholders. Hand-rolled rather than
	// String.prototype.replaceAll with a function, because `replace` treats "$"
	// specially in the replacement and a filename containing "$&" would corrupt.
	function fill(template, vars) {
		var out = String(template);
		for (var k in vars) {
			if (!Object.prototype.hasOwnProperty.call(vars, k)) { continue; }
			out = out.split("{" + k + "}").join(String(vars[k]));
		}
		return out;
	}

	function locale() {
		return current;
	}

	function direction(loc) {
		return loc === "fa" ? "rtl" : "ltr";
	}

	// read_storage is guarded because a WebView2 document served from a file: or
	// set_html origin can have localStorage throw on access rather than merely be
	// unavailable, and a theme toggle must not be able to break the window.
	function read_storage(key) {
		try {
			return global.localStorage ? global.localStorage.getItem(key) : null;
		} catch (e) {
			return null;
		}
	}

	function write_storage(key, value) {
		try {
			if (global.localStorage) { global.localStorage.setItem(key, value); }
		} catch (e) {
			// Not being able to remember the choice is a cosmetic loss, not a
			// reason to break the UI.
		}
	}

	// apply walks the document and fills every [data-i18n] element, then
	// [data-i18n-attr] for attributes such as aria-label and title.
	function apply() {
		var nodes = document.querySelectorAll("[data-i18n]");
		for (var i = 0; i < nodes.length; i++) {
			nodes[i].textContent = t(nodes[i].getAttribute("data-i18n"));
		}
		var attrs = document.querySelectorAll("[data-i18n-attr]");
		for (var j = 0; j < attrs.length; j++) {
			var spec = attrs[j].getAttribute("data-i18n-attr");
			// "aria-label:key" - one attribute per element, because the common case
			// is aria-label and a list would be a parser for something simple.
			var parts = spec.split(":");
			if (parts.length === 2) { attrs[j].setAttribute(parts[0], t(parts[1])); }
		}
		var html = document.documentElement;
		html.setAttribute("lang", current);
		html.setAttribute("dir", direction(current));
	}

	function set_locale(loc) {
		if (LOCALES.indexOf(loc) < 0) { return; }
		current = loc;
		write_storage(STORAGE_KEY, loc);
		apply();
		if (typeof global.on_locale_changed === "function") { global.on_locale_changed(loc); }
	}

	function toggle_locale() {
		set_locale(current === "fa" ? "en" : "fa");
	}

	// ---- theme ----------------------------------------------------------
	//
	// A document attribute, not a class: `[data-theme]` on <html> was already how
	// tokens.css declares the light palette, and a second mechanism would be a
	// second source of truth for the same decision.

	var THEMES = ["dark", "light"];
	var theme = "dark";

	function set_theme(name) {
		if (THEMES.indexOf(name) < 0) { return; }
		theme = name;
		document.documentElement.setAttribute("data-theme", name);
		write_storage(THEME_KEY, name);
		if (typeof global.on_theme_changed === "function") { global.on_theme_changed(name); }
	}

	function toggle_theme() {
		set_theme(theme === "dark" ? "light" : "dark");
	}

	function current_theme() {
		return theme;
	}

	// init restores whatever was chosen last, then paints. Called once at boot.
	// The stored locale is applied before apply() so the first paint is already
	// in the right direction - a flash of LTR Persian is the kind of thing that
	// makes a localised UI feel unfinished.
	function init() {
		var saved = read_storage(STORAGE_KEY);
		if (saved && LOCALES.indexOf(saved) >= 0) { current = saved; }
		var saved_theme = read_storage(THEME_KEY);
		if (saved_theme && THEMES.indexOf(saved_theme) >= 0) { theme = saved_theme; }
		document.documentElement.setAttribute("data-theme", theme);
		apply();
	}

	// compose_notice turns a Notice into a sentence in the active locale.
	//
	// `fallback` is the native side's English `text`, used when a notice arrives
	// with no structured fields - an engine-level info notice, for instance, which
	// has no download to name and genuinely is only ever a sentence.
	function compose_notice(n) {
		if (!n) { return ""; }
		var name = n.name || "";
		switch (n.kind) {
			case "added":
				return fill(t("notice.added"), { name: name });
			case "finished":
				return fill(n.seeder ? t("notice.finished.seeding") : t("notice.finished"), { name: name });
			case "failed":
				return fill(t("notice.failed"), {
					name: name,
					reason: n.error || t("notice.failed.noreason")
				});
			case "removed":
				return fill(t("notice.removed"), { name: name });
			default:
				return fill(t("notice.info"), { text: n.text || name });
		}
	}

	global.I18n = {
		init: init,
		t: t,
		fill: fill,
		apply: apply,
		locale: locale,
		set_locale: set_locale,
		toggle_locale: toggle_locale,
		direction: direction,
		theme: current_theme,
		set_theme: set_theme,
		toggle_theme: toggle_theme,
		compose_notice: compose_notice,
		locales: LOCALES,
		themes: THEMES
	};
}(window));