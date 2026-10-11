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

			// Short, because this lives in a log line. The long version
			// ("packed document (set_html)") is what I wrote first, and it rendered
			// as "packed document (set_ht…" - which tells a user nothing, because
			// the interesting half is the part that got cut.
			"transport.packed": "packed",
			"transport.dev": "dev :${port}",

			"pane.downloads": "downloads",
			"pane.log": "engine log",
			"pane.speed": "speed",
			"search.placeholder": "search the queue…",
			"search.hits": "{n} of {total} rows match “{q}”",
			"search.none": "no rows match “{q}”",

			"empty.queue": "Nothing queued. Add a URL above.",
			"add.placeholder": "https://  ·  magnet:?xt=urn:btih:…  ·  C:\\path\\to\\file.torrent",
			"add.aria": "a url, a magnet link, or a path to a .torrent",
			"add.button": "Add",
			"add.advanced": "Add with options (Enter)",
			"add.title": "Add downloads",
			"add.mode": "Add mode",
			"add.mode.simple": "simple",
			"add.mode.advanced": "advanced",
			"add.uris.long": "one address per line — a url, a magnet, or a path to a .torrent",
			"add.uris.placeholder": "https://example.com/file.bin\nmagnet:?xt=urn:btih:…\nC:\\path\\to\\file.torrent",
			"add.clipboard": "read the clipboard",
			"add.clipboard.hint": "the browser may ask first; nothing is read until you click",
			"add.clipboard.done": "{n} address(es) read from the clipboard",
			"add.clipboard.empty": "the clipboard has no address in it",
			"add.clipboard.failed": "the clipboard could not be read: {detail}",
			"add.pick.all": "all",
			"add.pick.none": "none",
			"add.pick.count": "{n} of {total} selected",
			"add.kind.url": "url",
			"add.kind.magnet": "magnet",
			"add.kind.torrent": "torrent",
			"add.out": "file name (optional)",
			"add.connections": "connections each",
			"add.paused": "add paused",
			"add.legend.this": "for these downloads",
			"add.submit": "add",
			"add.none": "nothing selected to add",
			// The folder suggestion. The wording is "suggested" and not "found",
			// because it is a guess from the URL's last path segment and the user is
			// entitled to disagree with it.
			"add.folder.suggested": "suggested folder, from the address:",
			"add.folder.use": "use it",
			"add.folder.empty": "nothing recognisable in the address to suggest from",
			"add.added": "Added {name}",

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
			"shortcuts.open": "?",
			"shortcuts.close": "close",
			// Only keys that are actually bound, and the wording of each line is what
			// the key DOES rather than a name for it. A help dialog that documents a
			// key which is not wired is worse than no dialog: it teaches the reader to
			// trust the wrong thing.
			"shortcuts.body":
				"/            focus the add box\n" +
				"\u2191 \u2193          select a download\n" +
				"space        pause or resume the selection\n" +
				"ctrl + \u2191 \u2193   move it in the queue\n" +
				"delete       remove the selection\n" +
				"r            retry the selection\n" +
				"enter        open the selection's details\n" +
				"a            open the add dialog\n" +
				"s            settings\n" +
				"t            toggle the theme\n" +
				"l            toggle fa / en\n" +
				"?            this list\n" +
				"m            this app's menu\n" +
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

			"menu.title": "the app's menu",
			"menu.group.downloads": "the queue",
			"menu.group.app": "the app",

			"nav.categories": "the categories",
			"sidebar.rule": "your categories",
			"sidebar.new": "new category",
			"cat.all": "all",
			"cat.active": "downloading",
			"cat.waiting": "queued",
			"cat.paused": "paused",
			"cat.done": "finished & failed",
			"category.new.prompt": "a name for the new category",
			"category.deleted": "Removed {name}",
			"category.added": "Added {name}",

			"details.title": "details",
			"details.actions": "actions",
			"details.gid": "gid",
			"details.status": "status",
			"details.dir": "folder",
			"details.total": "size",
			"details.done": "downloaded",
			"details.uploaded": "uploaded",
			"details.speed": "downloading at",
			"details.upload": "uploading at",
			"details.eta": "time left",
			"details.connections": "connections",
			"details.pieces": "pieces",
			"details.piece_length": "piece length",
			"details.verified_length": "verified",
			"details.info_hash": "info hash",
			"details.seeders": "seeders",
			"details.leechers": "leechers",
			"details.trackers": "trackers",
			"details.files": "files",
			"details.uris": "addresses",
			"details.live": "in use",
			"details.idle": "not in use",
			"details.failed": "could not read this download: {detail}",
			"details.none": "nothing selected",

			// ---- settings
			"settings.open": "settings",
			"settings.title": "Settings",
			"settings.dev.title": "developer",
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
			"settings.bad-payload": "The settings came back unreadable: {detail}"
		},

		fa: {
			"lang.name": "فارسی",
			"app.tagline": "مدیریت دانلود aria2 · ساخته‌شده با vails",

			"transport.packed": "بسته‌شده",
			"transport.dev": "توسعه :${port}",

			"pane.downloads": "دانلودها",
			"pane.log": "گزارش موتور",
			"pane.speed": "نمودار سرعت",

			"empty.queue": "صف خالی است. یک نشانی بالا بیفزایید.",
			"search.placeholder": "جست‌وجو در صف…",
			"search.hits": "{n} از {total} ردیف با «{q}» می‌خواند",
			"search.none": "هیچ ردیفی با «{q}» نمی‌خواند",
			"add.placeholder": "https://  ·  magnet:?xt=urn:btih:…  ·  C:\\path\\to\\file.torrent",
			"add.aria": "نشانی، پیوند مگنت یا مسیر یک فایل تورنت",
			"add.button": "افزودن",
			"add.advanced": "افزودن با گزینه‌ها (Enter)",
			"add.title": "افزودن دانلود",
			"add.mode": "حالت افزودن",
			"add.mode.simple": "ساده",
			"add.mode.advanced": "پیشرفته",
			"add.uris.long": "هر نشانی در یک سطر — وب‌نشانی، مگنت، یا مسیر یک فایل تورنت",
			"add.uris.placeholder": "https://example.com/file.bin\nmagnet:?xt=urn:btih:…\nC:\\path\\to\\file.torrent",
			"add.clipboard": "خواندن برگه‌دان (کلیپ‌بورد)",
			"add.clipboard.hint": "مرورگر ممکن است بپرسد؛ تا کلیک شما چیزی خوانده نمی‌شود",
			"add.clipboard.done": "{n} نشانی از برگه‌دان خوانده شد",
			"add.clipboard.empty": "نشانی‌ای در برگه‌دان نیست",
			"add.clipboard.failed": "برگه‌دان خوانده نشد: {detail}",
			"add.pick.all": "همه",
			"add.pick.none": "هیچ",
			"add.pick.count": "{n} از {total} انتخاب‌شده",
			"add.kind.url": "وب",
			"add.kind.magnet": "مگنت",
			"add.kind.torrent": "تورنت",
			"add.out": "نام فایل (اختیاری)",
			"add.connections": "اتصال برای هرکدام",
			"add.paused": "افزودن در حالت مکث",
			"add.legend.this": "برای این دانلودها",
			"add.submit": "افزودن",
			"add.none": "چیزی برای افزودن انتخاب نشده است",
			// The folder suggestion is a guess from the URL's last path segment, so
			// the wording says "suggested" and not "found" - the user can disagree.
			"add.folder.suggested": "پوشهٔ پیشنهادی، از نشانی:",
			"add.folder.use": "استفاده کن",
			"add.folder.empty": "از این نشانی چیزی برای پیشنهاد گزارش نمی‌شود",
			"add.added": "{name} افزوده شد",

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
			"shortcuts.open": "?",
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

			"menu.title": "منوی برنامه",
			"menu.group.downloads": "صف",
			"menu.group.app": "برنامه",

			"nav.categories": "دسته‌ها",
			"sidebar.rule": "دسته‌های شما",
			"sidebar.new": "دستهٔ تازه",
			"cat.all": "همه",
			"cat.active": "در حال دانلود",
			"cat.waiting": "در صف",
			"cat.paused": "متوقف",
			"cat.done": "پایان‌یافته و ناموفق",
			"category.new.prompt": "نامی برای دستهٔ تازه",
			"category.deleted": "{name} حذف شد",
			"category.added": "{name} افزوده شد",

			"details.title": "جزئیات",
			"details.actions": "کنش‌ها",
			"details.gid": "شناسه",
			"details.status": "وضعیت",
			"details.dir": "پوشه",
			"details.total": "اندازه",
			"details.done": "دانلودشده",
			"details.uploaded": "بارگذاری‌شده",
			"details.speed": "سرعت دانلود",
			"details.upload": "سرعت بارگذاری",
			"details.eta": "زمان مانده",
			"details.connections": "اتصال‌ها",
			"details.pieces": "تکه‌ها",
			"details.piece_length": "اندازهٔ تکه",
			"details.verified_length": "بررسی‌شده",
			"details.info_hash": "هش تورنت",
			"details.seeders": "بذرگذار",
			"details.leechers": "دریافت‌کننده",
			"details.trackers": "رهگیرها",
			"details.files": "فایل‌ها",
			"details.uris": "نشانی‌ها",
			"details.live": "در دست استفاده",
			"details.idle": "بی‌استفاده",
			"details.failed": "جزئیات خوانده نشد: {detail}",
			"details.none": "چیزی انتخاب نشده است",

			// ---- settings
			"settings.open": "تنظیمات",
			"settings.title": "تنظیمات",
			"settings.dev.title": "توسعه‌دهنده",
			"settings.dev.hint": "this is aria2's own output plus what Fluxget logs about itself. it is only written, never read back.",
			"settings.legend.categories": "دسته‌ها",
			"settings.categories.hint": "دسته‌ها برچسبی‌اند که خودتان می‌سازید. برای افزودن یک دانلود به یک دسته، در پنجرهٔ جزئیات آن را انتخاب کنید.",
			"settings.categories.new": "نام دستهٔ تازه",
			"settings.categories.add": "افزودن",
			"settings.categories.one": "دسته‌ها باید نام داشته باشند.",
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
			"settings.bad-payload": "تنظیمات خوانده نشد: {detail}"
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