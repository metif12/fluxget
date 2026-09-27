// host.v — the ONLY file in Fluxget allowed to import vails modules.
//
// Rule R1 (enforced by scripts/check-isolation.ps1): `main.v` and this file
// are the whole blast radius. Every other module — rpc, aria2ctl, core,
// engine, schedule, store, api, shell, pack and the entire frontend — is
// pure V with zero knowledge of the framework. When upstream vails moves,
// the fix lands here and nowhere else.
//
// host.v owns four jobs:
//   1. read vails.json and turn it into a live window (config -> webview.run)
//   2. bind the app's own command surface through the vails service model, so
//      vails.json grants stay the single source of truth and dts_text can
//      generate the frontend from the same manifest
//   3. pick the frontend transport: dev server with livereload, or the packed
//      single-file document for production
//   4. hide webview.Ctx behind a Fluxget-owned handle, so main.v does not
//      mention the framework either
//
// COMPAT(dev): dev.new_dev_server + webview.Config.url. If either is removed
// upstream, boot() falls back to the packed document and the app still runs,
// just without livereload.
module platform

import bridge
import capabilities
import config
import dev
import os
import services
import webview

// Handler is one bound command: raw JSON params in, raw JSON out. It mirrors
// bridge.MethodHandler structurally, so callers never see the vails type.
pub type Handler = fn (params string) !string

// NOTE: there is deliberately no `pub type Backend = map[string]Handler` here,
// even though it would read better at the call site. V 0.5.2 does not honour a
// type alias for a map: a value returned as the alias comes out empty when
// passed to a parameter of the underlying map type, which makes
// services.install reject every command and report "no handler for ...". The
// concrete map type is spelled out everywhere instead. The same is true of map
// literals: `{ 'k': v }` works when the type comes from context, but a typed
// `Backend{ 'k': v }` literal does not parse at all.
pub type Backend = map[string]Handler

// ReadyFn runs once the native window exists.
pub type ReadyFn = fn (ctx Ctx)

// Ctx is Fluxget's handle on the live window. It deliberately does not expose
// the vails type, so a Ctx can live in core/ and be passed around freely.
pub struct Ctx {
pub mut:
	inner webview.Ctx
}

// emit pushes one event to the frontend (V -> JS). Only call this from a
// command handler: handlers run on the webview main thread, and eval from a
// spawned worker is a platform violation (vails ADR-0010).
pub fn (c Ctx) emit(event string, data string) ! {
	c.inner.emit(event, data)
}

// is_ready reports whether a live window is attached.
pub fn (c Ctx) is_ready() bool {
	return c.inner.is_ready()
}

// has_parent reports whether a native parent handle is available, i.e.
// whether native dialogs can be parented to this window.
pub fn (c Ctx) has_parent() bool {
	return c.inner.has_parent()
}

// label is the capability identity of the window, e.g. 'main'.
pub fn (c Ctx) label() string {
	return c.inner.label
}

// Spec describes one window and where its frontend comes from. It is
// vails-free on purpose: main.v fills it, host.v executes it.
pub struct Spec {
pub mut:
	// project_root holds vails.json and the frontend/ tree. Probed from the
	// cwd, the executable dir and its parents when left empty.
	project_root string
	// html is the production document (build/web/index.html, packed by
	// tools/pack). Required when dev is false.
	html string
	// dev serves frontend/ over loopback with a livereload poller and points
	// the window at it.
	dev bool
	// dev_port overrides dev.default_port when non-zero.
	dev_port int
	// ready_fn is installed on Config.on_ready.
	ready_fn ?ReadyFn
}

// config_candidates probes where vails.json lives: next to a directory, next
// to the binary, and one/two levels up from the binary (the repo's build/
// layout puts the exe a level below the root).
fn config_candidates(root string) []string {
	exe := os.dir(os.executable())
	return [
		os.join_path(root, 'vails.json'),
		os.join_path(exe, 'vails.json'),
		os.join_path(exe, '..', 'vails.json'),
		os.join_path(exe, '..', '..', 'vails.json'),
	]
}

// resolve_root picks the directory that holds vails.json, falling back to the
// cwd when it cannot be found (load_config then reports it properly).
pub fn resolve_root(spec Spec) string {
	if spec.project_root != '' {
		return spec.project_root
	}
	roots := [
		os.getwd(),
		os.dir(os.executable()),
		os.join_path(os.dir(os.executable()), '..'),
		os.join_path(os.dir(os.executable()), '..', '..'),
	]
	for r in roots {
		for c in config_candidates(r) {
			if os.exists(c) {
				return os.dir(c)
			}
		}
	}
	return os.getwd()
}

// load_config reads and validates vails.json for the given root.
pub fn load_config(root string) !config.VailsConfig {
	for c in config_candidates(root) {
		if os.exists(c) {
			return config.load(c)!
		}
	}
	return error('vails.json not found (looked in: ' + config_candidates(root).join(', ') + ')')
}

// start_dev_server spawns the vails loopback dev server and returns its URL.
// Loopback only; the framework injects the livereload poller into HTML.
pub fn start_dev_server(root string, asset_root string, port int, label string) !string {
	mut srv := dev.new_dev_server(root, asset_root, port, load_config(root)!.to_registry(), label)
	url := srv.dev_url()
	spawn fn (s dev.DevServer) {
		s.run() or { eprintln('fluxget: dev server: ' + err.msg()) }
	}(srv)
	return url
}

// boot opens the window and blocks until it closes.
//
// Order matters: the app's own commands are bound *before* the window opens
// (they need no native handle), so the first frontend call can never race an
// install. Only services that need a parent window go in on_ready.
pub fn boot(spec Spec, backend map[string]Handler) ! {
	root := resolve_root(spec)
	cfg := load_config(root)!
	w := cfg.window('main') or { return err }
	mut r := bridge.new_router()
	mut router := &r

	// The app's own surface, declared as a vails service: services.install
	// refuses a manifest/handler mismatch, so the two cannot drift.
	services.install(mut router, app_manifest(), backend)!

	ready := spec.ready_fn
	on_ready := fn [mut router, ready] (inner webview.Ctx) {
		// Native-parented services (open/save/message pickers). Windows runs
		// the real dialogs; elsewhere the framework's own stub answers
		// 'not implemented', so the UI degrades instead of failing.
		services.install_dialog(mut router, inner) or {
			eprintln('fluxget: dialog service: ' + err.msg())
		}
		services.install_os_info(mut router) or {
			eprintln('fluxget: os_info service: ' + err.msg())
		}
		if cb := ready {
			cb(Ctx{
				inner: inner
			})
		}
	}

	port := if spec.dev_port > 0 { spec.dev_port } else { dev.default_port }
	url := if spec.dev {
		start_dev_server(root, cfg.asset_root, port, w.label)!
	} else {
		''
	}
	if url == '' && spec.html == '' {
		return error('fluxget: no frontend. Set spec.html (production) or spec.dev = true.')
	}

	webview.run(
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		router:   router
		registry: cfg.to_registry()
		html:     if url == '' { spec.html } else { '' }
		url:      url
		on_ready: on_ready
	)!
}

// registry_of is the capability registry for a project root, used by tests
// and by the dev server.
pub fn registry_of(root string) !capabilities.Registry {
	return load_config(root)!.to_registry()
}

// granted_commands flattens the command names vails.json grants.
pub fn granted_commands(cfg config.VailsConfig) []string {
	mut out := []string{}
	for c in cfg.capabilities {
		for name in services.granted_commands(c.commands) {
			if name !in out {
				out << name
			}
		}
	}
	return out
}

// dts_text renders the frontend TypeScript declarations plus the JS glue for
// the granted services, from the same manifests the router was installed
// with. tools/dtsgen writes this to frontend/vails.d.ts and
// frontend/vails-services.js.
//
// COMPAT(generator): upstream Phase 7 adds $for compile-time reflection and
// `vails dts` will derive specs itself. When that lands, delete dts_text and
// the dtsgen tool and call the CLI instead.
pub fn dts_text(cfg config.VailsConfig) string {
	ours := app_manifest()
	mut picked := [ours]
	mut seen := [ours.name]
	for name in granted_commands(cfg) {
		if name.starts_with(app_name + '.') {
			continue
		}
		if s := services.service_of(name) {
			if s.name in seen {
				continue
			}
			seen << s.name
			picked << s
		}
	}
	return services.dts(picked) + '\n' + services.snippets(picked)
}

// host_test_config mirrors the vails.json in the project root without touching
// the filesystem, so the codegen path is testable in isolation. The fields
// that matter for dts_text are the capability command lists.
pub fn host_test_config() config.VailsConfig {
	return config.VailsConfig{
		name:         'Fluxget'
		version:      app_version
		windows:      [config.WindowConfig{
			label:  'main'
			title:  'Fluxget'
			width:  1360
			height: 880
		}]
		capabilities: [config.CapabilitySpec{
			id:          'fluxget-core'
			windows:     ['main']
			commands:    app_manifest().command_names()
			asset_roots: ['frontend']
		}]
	}
}
