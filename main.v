// main.v — Fluxget entry point.
//
// By rule R1 (scripts/check-isolation.ps1) this file and platform/ are the
// only places allowed to know the framework exists. Everything below this
// line is ordinary V: rpc, aria2ctl, core, engine, schedule, store, api,
// shell, pack — none of them import a vails module.
//
// Boots in one of two transports:
//   --dev   frontend/ is served over loopback by the vails dev server, with a
//           livereload poller, and the window is pointed at that URL
//   default build/web/index.html, the single packed document that tools/pack
//           produces. Required in production because webview_set_html gives
//           the document no real origin, so relative <script src> would not
//           load.
module main

import os
import platform

// packed_document is where scripts/build.ps1 + tools/pack leave the
// production frontend.
const packed_document = 'build/web/index.html'

// packed_candidates mirrors platform.config_candidates: the document sits
// next to the binary's project root, so the same probe order works.
fn packed_candidates() []string {
	exe := os.dir(os.executable())
	return [
		os.join_path(os.getwd(), packed_document),
		os.join_path(os.getwd(), '..', packed_document),
		os.join_path(exe, packed_document),
		os.join_path(exe, '..', packed_document),
	]
}

fn find_packed() string {
	for c in packed_candidates() {
		if os.exists(c) {
			return os.read_file(c) or { return '' }
		}
	}
	return ''
}

fn main() {
	args := os.args
	dev_mode := '--dev' in args
	if dev_mode {
		os.setenv('FLUXGET_DEV', '1', true)
		// In dev, prove the vails contract before opening the window. A
		// mismatch here is an upstream move, and the message says so instead
		// of leaving you with a silent UI that calls nothing.
		rep := platform.run_contract()
		if !rep.ok {
			eprintln('fluxget: vails contract check FAILED')
			eprintln('  registry_denies=${rep.registry_denies} manifest_ok=${rep.manifest_ok}')
			eprintln('  csp_idempotent=${rep.csp_idempotent} install_rejects=${rep.install_rejects}')
			for note in rep.notes {
				eprintln('  note: ' + note)
			}
			eprintln('  see .\\scripts\\sync-vails.ps1 -Report')
		}
	}
	mut spec := platform.Spec{
		dev: dev_mode
	}
	if !dev_mode {
		spec.html = find_packed()
	}

	// The App is built here, before boot, and owned here. Two things need it and
	// neither can create it:
	//
	//   * the handler set, because fluxget.health/tick/add need the engine's
	//     state and a bridge handler's signature has nowhere to put a parameter;
	//   * the shutdown, because webview.Config has on_ready and NO close hook
	//     (platform/host.v), so the daemon has to be stopped by whoever called
	//     boot. A temporary created inside boot() would be stopped by luck.
	//
	// The engine itself does NOT start here. It starts from spec.ready_fn, i.e.
	// once the window exists, because a missing aria2c must still leave a window
	// on screen - that window is the Setup page.
	//
	// The root comes from resolve_root, not os.getwd(). The working directory is
	// whatever the launcher happened to set: a shortcut or a double-click gives
	// one that has nothing to do with the project, and then runtime\aria2c.exe
	// and build\web\index.html are both "not found" for reasons that look like a
	// broken install. resolve_root probes the cwd, the executable's directory and
	// two levels up from it, and picks the first one holding vails.json - the
	// same directory the window's config came from, so the frontend and the
	// engine can never disagree about where the project is.
	mut app := platform.new_app(platform.resolve_root(spec), dev_mode,
		os.getenv('FLUXGET_PROBE'))
	spec.ready_fn = fn [app] (_ platform.Ctx) {
		app.window_ready()
	}

	platform.boot(spec, platform.default_backend(app)) or {
		// The window failed to open, so nothing was started and there is nothing
		// to stop. Exiting here with the reason beats leaving a process behind.
		eprintln('fluxget: ' + err.msg())
		exit(1)
	}
	// The window is closed. Save the session, shut aria2 down, then exit.
	app.stop()
}
