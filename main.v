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
	platform.boot(spec, platform.default_backend()) or {
		eprintln('fluxget: ' + err.msg())
		exit(1)
	}
}
