// app.v - Fluxget's own object, and the JSON the window sees.
//
// This is the seam from ADR-0001 seen from the other side. Everything below
// platform/ is ordinary V; everything above it is the framework. This file is
// where the two meet, and it is deliberately thin: it owns no rules, it only
// marshals. The rules live in engine/ (what to ask aria2), aria2ctl/ (when to
// restart it) and core/ (what changed since last tick).
//
// ---- why App is a heap object and not a global ---------------------------
//
// AGENTS.md section 4 forbids globals, and a bridge handler's signature is
// fixed: `fn (params string) !string`. There is nowhere to thread state through
// it. So the state is a heap object (core.State, behind &App) and the handlers
// are closures that capture it - the same shape rpc/fake.v already uses for its
// recording transport, and the reason V needs `mut p := app` before the closure
// (a closure captures a COPY unless the capture is mutable).
//
// ---- why the builders below are pure ------------------------------------
//
// `tick_from` and `health_from` take a value and return a value. They are the
// only way the wire format can be tested, because the alternative - asserting on
// a live tick - needs aria2 running and a window open, which `v test` may not
// do. Every field of the Tick payload is therefore reachable from a
// hand-written Snapshot, and the dts contract test can check the interface
// against a real payload rather than against a field list.
module platform

import aria2ctl
import core
import engine
import store
import json2
import os
import rpc
import strconv

// App is the running application, as the handlers see it.
//
// @[heap] because the handler closures capture a POINTER to it, and V refuses to
// let a reference to a stack object escape ("`app` cannot be assigned outside
// unsafe blocks as it might refer to an object stored on stack"). The same reason
// webview.Config's `router &bridge.Router` field makes its caller heap-allocate
// the router first.
@[heap]
pub struct App {
pub mut:
	// state is a pointer so every closure sees the same state. A value field
	// would be copied into each captured closure, and the tick handler would
	// mutate a copy that the add handler never sees.
	state &core.State
	// dev mirrors Spec.dev, so health can say which transport it is on.
	dev bool
	// settings is the user's preferences. It is a VALUE and not a pointer on
	// purpose: unlike the engine, it has no identity that other things hold, it
	// is small, and copying it into a closure is a feature - a handler that
	// mutates its copy cannot corrupt what the next tick reads.
	settings store.Settings
	// settings_path is where the document lives, resolved ONCE at startup.
	// Resolving per write would mean a settings file that moves if %APPDATA%
	// changes between two saves, which is a bug nobody would believe.
	settings_path string
	// settings_notes is what loading said: corrections applied, or a file that
	// could not be read. Kept so the UI can show it once instead of silently
	// holding different values than the user's file.
	settings_notes []string
}

// new_app builds the application. It starts nothing and opens nothing: the
// engine starts in window_ready, which is called from on_ready, and a handler
// that built an App must not thereby cause a process to appear.
pub fn new_app(root string, dev bool, probe_url string) &App {
	mut c := core.Config{
		root:      root
		port:      aria2ctl.default_rpc_port
		probe_url: probe_url
	}
	// Two escape hatches, because Settings does not exist yet and a clash with
	// the user's own aria2 must not be a dead end.
	//
	// getenv_opt and strconv.atoi rather than getenv plus String.int(): V 0.5.2
	// only allows `if x := expr` when expr is an Option or a Result, and
	// String.int() panics on anything that is not a number - so FLUXGET_RPC_PORT
	// set to a typo would crash the app at startup instead of being ignored.
	if p := os.getenv_opt('FLUXGET_RPC_PORT') {
		n := strconv.atoi(p) or { 0 }
		if n > 0 && n < 65536 {
			c.port = n
		}
	}
	if p := os.getenv_opt('FLUXGET_ARIA2') {
		if p != '' {
			c.aria2_path = p
		}
	}
	// The settings document is read HERE, at construction, and not in
	// window_ready: a corrupt file must not be able to delay the window, and a
	// slow disk must not either. Loading is one small read; if it fails, defaults
	// plus a note is a working app, and the note is in the UI.
	settings_path := store.default_path()
	loaded, notes := store.load(settings_path)

	mut app := &App{
		state:          core.new_state(c)
		dev:            dev
		settings:       loaded
		settings_path:  settings_path
		settings_notes: notes
	}
	return app
}

// window_ready runs once the native window exists, on the webview main thread.
//
// The engine starts HERE and not before platform.boot, and that placement is the
// whole reason this function exists. If a missing aria2c stopped the app from
// opening a window, the user would have no way to reach the Setup page that
// explains how to install it. So the window always opens; the engine is a
// consequence of the window existing.
//
// The readiness wait inside start() is bounded (aria2ctl), so a daemon that
// never binds costs a short pause and then a tick that keeps reporting
// `starting` - not a frozen window.
pub fn (mut app App) window_ready() {
	// Two steps, and the split is load-bearing rather than tidy.
	//
	// step 1 starts the engine and seeds the probe. step 2 pushes the settings.
	// They are separate calls because each takes the state lock itself, and the
	// earlier version of this had both inside ONE lock scope: apply_settings ->
	// push_settings locks again, and a plain mutex locked twice from the same
	// thread never comes back. The window did not crash - it stopped answering,
	// so the symptom was a window that paints and then ignores every key, and a
	// screenshot tool that hangs waiting for it. "Hangs" is the worst shape of
	// regression: nothing in the log says deadlock.
	//
	// So: no function that locks may call another function that locks. The rule is
	// now written down here because it is invisible until it is fatal.
	app.window_ready_start()
	app.apply_settings()
}

// window_ready_start is the half that needs the lock.
fn (mut app App) window_ready_start() {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.start_engine() or {
		// Already reported as a Notice by core.start_engine. The window is up and
		// the Setup page has what it needs; this is not fatal.
		return
	}
	// The e2e probe. Fires once, through the normal engine path, and only when
	// FLUXGET_PROBE is set - see core.seed_probe.
	app.state.seed_probe()
}

// stop runs after webview.run returns, i.e. after the window closed.
//
// There is no framework hook for this: webview.Config has on_ready and nothing
// else, so the shutdown has to belong to whoever called boot. That is why
// main.v holds the App rather than letting boot create it - somebody has to own
// the object's lifetime, and a temporary inside boot() would be shut down by
// luck rather than by design.
pub fn (mut app App) stop() {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.stop_engine()
}

// ---- the wire shapes -----------------------------------------------------
//
// WIRE FORMAT RULE (platform/commands.v has the full statement): these field
// names ARE the JSON keys, snake_case, and each one is written identically in
// app_manifest().ts_types. Uppercase is a hard error in V, and the [json: '...']
// attribute that would decouple them is miscompiled by V 0.5.2.

// Stat is the global summary, in rendered units.
pub struct Stat {
pub mut:
	// Rendered strings, not raw byte counts, and that is deliberate: the
	// formatting lives in engine/limits.v where it is tested, so the queue's
	// total, the header's rate and a row's rate cannot disagree about what
	// "1.4 MiB/s" means.
	download_speed string
	upload_speed   string
	num_active     int
	num_waiting    int
	num_stopped    int
}

// Download is one row of the queue.
pub struct Download {
pub mut:
	gid    string
	name   string
	status string
	// percent is a number rather than a string because a progress bar needs a
	// number; everything else here is for display only.
	percent f64
	total   string
	done    string
	speed   string
	upload  string
	eta     string
	// is_torrent and seeder decide which detail panel the UI opens, and whether
	// a finished row is still uploading.
	is_torrent bool
	seeder     bool
	dir        string
	// error is aria2's own message, empty unless the status is `error`.
	error string
}

// Tick is the wire shape of fluxget.tick: CONTEXT.md's Snapshot, plus the events
// and the log that ride along with it.
pub struct Tick {
pub mut:
	// ok is false when aria2 could not be reached this tick. Every other field is
	// still meaningful, and the UI must not read counts out of a failed tick's
	// zeros as if they were real.
	ok bool
	// phase is aria2ctl.Phase.label(). The frontend picks its Setup screen by
	// matching on this.
	phase string
	// detail is why, when something is wrong. Empty when nothing is.
	detail string
	// supervised is false when no binary was found: the app is running and the
	// engine does not exist, which is a different screen from "starting".
	supervised   bool
	aria2_path   string
	aria2_source string
	version      string
	features     []string
	// restart_in_ms is the backoff still owed after a crash, so the UI can say
	// "retrying in 2s" instead of appearing to hang.
	restart_in_ms int
	uptime_ms     i64
	ticks         int
	stat          Stat
	downloads     []Download
	// notices are core.Notice values, reused rather than re-declared: the
	// sentence is written once, in core/notice.v, and shown verbatim everywhere.
	notices []core.Notice
	logs    []string
	// logs_dropped is how many log lines fell off the ring, so the Logs tab can
	// distinguish "quiet" from "we threw it away".
	logs_dropped int
}

// EngineView is what the App observed about the daemon, separated from the
// snapshot so tick_from stays a function of one value.
pub struct EngineView {
pub mut:
	phase         string
	detail        string
	path          string
	source        string
	supervised    bool
	version       string
	features      []string
	restart_in_ms int
}

// SnapshotIn is the pure input to tick_from.
pub struct SnapshotIn {
pub mut:
	view         EngineView
	res          core.TickResult
	logs         []string
	logs_dropped int
	uptime_ms    i64
	ticks        int
}

// tick_from builds the whole tick payload. Pure, and the only place a Download
// or a Stat is constructed - so there is one definition of what a row looks like.
pub fn tick_from(frame SnapshotIn) Tick {
	mut t := Tick{
		ok:            frame.res.ok
		phase:         frame.view.phase
		detail:        frame.res.detail
		supervised:    frame.view.supervised
		aria2_path:    frame.view.path
		aria2_source:  frame.view.source
		version:       frame.view.version
		features:      frame.view.features
		restart_in_ms: frame.view.restart_in_ms
		uptime_ms:     frame.uptime_ms
		ticks:         frame.ticks
		logs:          frame.logs
		logs_dropped:  frame.logs_dropped
		stat:          Stat{
			// The failed case renders as 0 B/s rather than blank, because a
			// snapshotter showing an empty field looks broken and one showing
			// "0 B/s" while the detail line says "not connected" looks right.
			download_speed: engine.rate_text(frame.res.snap.stat.download_speed)
			upload_speed:   engine.rate_text(frame.res.snap.stat.upload_speed)
			num_active:     frame.res.snap.stat.num_active
			num_waiting:    frame.res.snap.stat.num_waiting
			num_stopped:    frame.res.snap.stat.num_stopped
		}
	}
	if frame.res.detail != '' && t.detail == '' {
		t.detail = frame.res.detail
	}
	all := frame.res.snap.all()
	t.downloads = []Download{len: all.len, init: Download{}}
	for i, s in all {
		t.downloads[i] = download_from(s)
	}
	// Notices are copied rather than aliased: drain() already handed over
	// ownership, and json2.encode walking a slice the next poll might append to
	// is not a risk worth carrying.
	mut ns := []core.Notice{len: frame.res.notices.len, init: core.Notice{}}
	for i, n in frame.res.notices {
		ns[i] = n
	}
	t.notices = ns
	return t
}

// download_from is one row. Rendered units come from engine/, where the rounding
// is tested; percent stays a number for the progress bar.
pub fn download_from(s rpc.Status) Download {
	// An ETA on a finished download is noise: there is nothing left to wait for,
	// and "unknown" reads as a problem where there is none. A queue row that says
	// "Finished 100 MiB ... unknown" is a small lie about uncertainty.
	eta := if s.is_finished() { '' } else { engine.eta_text(s.eta_seconds()) }
	return Download{
		gid:        s.gid
		name:       s.display_name('')
		status:     s.status
		percent:    s.percent()
		total:      engine.size_text(s.total_length)
		done:       engine.size_text(s.completed_length)
		speed:      engine.rate_text(s.download_speed)
		upload:     engine.rate_text(s.upload_speed)
		eta:        eta
		is_torrent: s.is_torrent()
		seeder:     s.is_seeding()
		dir:        s.dir
		error:      s.error
	}
}

// detail_from is gone, and the reason matters:
//
// The first attempt put detail fields on the Download struct, which meant every
// tick carried the tracker list and the file list of every row in the queue - two
// aria2 calls per download, per second, for a dialog that is open for one row at a
// time. It also meant a `verified_length` and `num_seeders` field on a plain HTTP
// download, which renders "0 seeders" for something that has no peers at all.
//
// So the details are their own command, `fluxget.details`, fetched when a row is
// clicked. One row, once, and the tick stays the size of a summary.

// health_from builds the health payload.
//
// Its five fields are the ones Phase 0 shipped and the existing frontend card
// reads, kept for compatibility; two were added (aria2_path, aria2_source)
// because the Setup page cannot name a binary it was never told about.
pub fn health_from(view EngineView) Health {
	connected := view.phase == phase_ready
	// A disconnected engine ALWAYS carries a reason. That is the Phase 0
	// behaviour and it was the right one then: "not connected" with nothing after
	// it is a dead end for the user, and the frontend can only choose a screen
	// from a sentence. A phase that has nothing of its own to say gets a generic
	// one rather than an empty string.
	mut detail := view.detail
	if !connected && detail == '' {
		detail = missing_hint_for(view.phase)
	}
	return Health{
		ok:           connected
		mode:         view.phase
		aria2:        view.version
		connected:    connected
		detail:       detail
		aria2_path:   view.path
		aria2_source: view.source
	}
}

// phase_ready is the one phase that means connected. Spelled here because the
// comparison decides what the UI does, and a literal repeated in two files is a
// literal that will be updated in one of them.
pub const phase_ready = 'ready'

// missing_hint_for is the sentence for each way of not being connected. The
// function exists so the answer is never empty - a `match` with a default arm
// cannot forget a case, which a chain of `if` can.
fn missing_hint_for(phase string) string {
	return match phase {
		'missing' {
			'aria2c was not found. Run .\\scripts\\fetch-aria2.ps1, or set a path in Settings.'
		}
		'starting' {
			'aria2c has been started and is still binding its RPC port.'
		}
		'crashed' {
			'aria2c exited and could not be restarted within the retry budget. See the log.'
		}
		'stopping' {
			'aria2c is shutting down.'
		}
		'stopped' {
			'aria2c is not running.'
		}
		else {
			// never-started: the window exists but window_ready has not run yet.
			'The engine has not been started yet.'
		}
	}
}

// ---- the handlers --------------------------------------------------------

// view_of reads the current engine state out of core. Impure by nature, and the
// only thing tick_json and health_json share.
fn (mut app App) view_of() EngineView {
	mut v := EngineView{
		phase: 'never-started'
	}
	mut sup := app.state.sup or { return v }
	v.phase = sup.phase.label()
	v.detail = sup.last_error
	v.supervised = true
	// The path and which of the four search rules found it were recorded when the
	// engine started. Re-running the search here would stat every PATH entry on
	// every tick, and the answer cannot have changed.
	v.path = app.state.aria2_path
	v.source = app.state.aria2_source
	if sup.phase == .ready {
		// A second call is a round trip, so it only happens when the phase says
		// the engine is up - and the answer is folded into `detail` if it is not,
		// which is how "it says ready but version() failed" becomes visible
		// instead of invisible.
		ver := app.state.eng.client.version() or {
			v.detail = 'aria2 answered the tick but not a direct version call: ' + err.msg()
			return v
		}
		v.version = ver.version
		v.features = ver.enabled_features
	}
	if sup.pending != none {
		p := sup.pending or { return v }
		left := p.at_ms - core.now_ms()
		v.restart_in_ms = if left < 0 { 0 } else { int(left) }
	}
	return v
}

// tick_json is fluxget.tick. One poll, and the whole frame in one payload.
//
// The order inside is the ADR-0010 discipline made concrete: read the pipe, deal
// with a crash, drain the queue, ask aria2 once, diff. No sleeping, no emitting,
// no second round trip.
pub fn (mut app App) tick_json() !string {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	view := app.view_of()
	res := app.state.poll()
	mut logs := []string{}
	mut dropped := 0
	// `mut sup`, not `if sup := ...`: a non-mut local holding a ?&Supervisor
	// cannot be re-bound to a mutable reference, and V's notice says exactly
	// that ("`sup` is immutable, cannot have a mutable reference to an immutable
	// object"). Nothing here needs mutability of the Option itself - the pointee
	// is on the heap and ring.lines() takes a non-mut receiver.
	mut sup := app.state.sup
	if sup != none {
		logs = sup.ring.lines()
		dropped = sup.ring.how_many_dropped()
	}
	// `frame`, not `in`: `in` is a keyword.
	frame := SnapshotIn{
		view:         view
		res:          res
		logs:         logs
		logs_dropped: dropped
		uptime_ms:    core.now_ms() - app.state.started_ms
		ticks:        app.state.ticks
	}
	return json2.encode(tick_from(frame))
}

// health_json is fluxget.health. Cheaper than a tick on purpose: it does not
// poll, so a UI that only wants to know "is it up yet" does not drag the whole
// queue across a socket on every frame.
pub fn (mut app App) health_json() !string {
	app.state.lock()
	defer {
		app.state.unlock()
	}
	return json2.encode(health_from(app.view_of()))
}

// AddParams is the request body of fluxget.add.
//
// A struct, because a command with params gets bridge.validate_any - the
// framework checks that the payload is JSON, not that it has the right fields.
// Everything below is validated by add_json, which means this handler is the
// only place a malformed add can be stopped, and it stops it before the URL
// reaches the network.
pub struct AddParams {
pub mut:
	// uris are the sources. More than one means mirrors of ONE download.
	uris []string
	// dir is an optional per-download directory.
	dir string
	// out is an optional file name.
	out string
	// paused stages the item without starting it.
	paused bool
}

// max_add_params_bytes bounds the request body.
//
// The framework will happily hand a handler a megabyte of JSON. A cap costs one
// comparison and turns "the page froze" into "that request was too large".
pub const max_add_params_bytes = 8192

// add_json is fluxget.add: hand a URL, a magnet or a .torrent to the engine.
//
// This is the command that makes the window a download manager rather than a
// status display, and it is a real capability: the grant in vails.json is what
// authorises it, and any script in the window can call it. That is why the
// validation below is explicit rather than trusting the payload.
pub fn (mut app App) add_json(params string) !string {
	if params.len > max_add_params_bytes {
		return error('fluxget.add: the request is ${params.len} bytes; the limit is ${max_add_params_bytes}')
	}
	p := json2.decode[AddParams](params) or { return error('fluxget.add: bad params: ' + err.msg()) }
	mut req := engine.AddRequest{
		uris:   p.uris
		dir:    p.dir
		out:    p.out
		paused: p.paused
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	// The engine refuses an empty list and caps the count (engine/clean_uris);
	// those errors are the user's answer and they travel as a rejection, not as
	// a silent empty gid.
	gid := app.state.eng.add(req) or { return error('fluxget.add: ' + err.msg()) }
	// Remembered so a download that later fails can be retried: aria2 forgets the
	// source of a failed download, and Fluxget is the only party that still knows
	// it (core.State.added_uris).
	app.state.remember(gid, req.uris)
	app.state.notices.push(core.Notice{
		kind: core.notice_added
		text: 'Added ' + (if p.uris.len > 0 { p.uris[0] } else { gid })
	})
	// The gid is the answer, as a bare JSON string: it is the only handle the
	// frontend, the history and the scheduler have.
	return json2.encode(gid)
}

// A deliberate omission, recorded so nobody "fixes" it: fluxget.pause,
// fluxget.resume and fluxget.remove are NOT in the manifest yet.
//
// The README roadmap puts pause/resume/remove/retry in Phase 3, and the engine
// already has the calls (engine/queue.v's facade) waiting for it. What is being
// resisted here is a generic "call any aria2 method" escape hatch: it would hand
// the window the entire RPC surface, which is the exact opposite of the
// capability model this project is built on. Three named commands, each its own
// grant, is the shape that stays auditable.
