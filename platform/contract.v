// contract.v — the machine-checked list of vails API Fluxget depends on.
//
// This file contains no logic. Its only job is to *reference* every vails
// symbol the app needs, with the shape it needs, so that compiling it IS the
// contract check: if upstream renames a field, drops a parameter or changes a
// return type, the build fails here rather than at some random call site.
//
// Three kinds of reference, three different failure modes worth catching:
//
//   1. a *call*      - compile fails if the signature changed
//   2. a *type*      - compile fails if the name or arity changed
//   3. a *value*     - compiled but may be wrong; asserted in contract_test.v
//      (field presence, a struct field we rely on existing, a function that
//      must still be callable at runtime)
//
// contract_test.v is therefore not redundant: it catches the class of change
// that compiles fine and breaks behaviour.
//
// Kept in step with:
//   - scripts/sync-vails.ps1  ($ContractPatterns, the grep-level probe)
//   - scripts/check-isolation.ps1 ($allowedFiles)
module platform

import bridge
import capabilities
import config
import dev
import events
import services
import webview

// ---- 1. calls: the exact signatures we bind to ---------------------------

// router_shape proves Router is still constructible and still takes a
// validated handler with the (params string) !string shape.
fn router_shape() bridge.Router {
	mut r := bridge.new_router()
	r.register_validated('fluxget.contract.probe', bridge.validate_empty, fn (params string) !string {
		return params
	}) or { return r }
	return r
}

// config_shape proves load/load_text still take and return the same types.
fn config_shape(root string) !config.VailsConfig {
	cfg := config.load(root) or { return config.load_text('{"name":"x","windows":[]}')! }
	return cfg
}

// dev_shape proves the dev server is still constructed from a root, an asset
// root, a port, a registry and a label - the five arguments host.v passes.
fn dev_shape(root string, asset_root string, port int, reg capabilities.Registry, label string) dev.DevServer {
	return dev.new_dev_server(root, asset_root, port, reg, label)
}

// events_shape proves V->JS is still assembled by events.to_js.
fn events_shape(event string, data string) string {
	return events.to_js(event, data)
}

// webview_shape proves Config still has every field host.v sets. Struct
// literals with named fields are the strongest check available: a removed or
// renamed field fails to compile here.
//
// The router is built inside rather than passed in on purpose: webview.Config
// holds a &bridge.Router, and V only lets a pointer reach a struct field when
// the pointee is provably on the heap. `mut r := ...; mut router := &r` makes
// it escape, which is exactly what host.v does and what the check is meant to
// mirror.
fn webview_shape(reg capabilities.Registry, on_ready fn (ctx webview.Ctx)) webview.Config {
	mut r := bridge.new_router()
	mut router := &r
	return webview.Config{
		label:    'main'
		title:    'Fluxget'
		width:    1360
		height:   880
		router:   router
		registry: reg
		html:     ''
		url:      ''
		on_ready: on_ready
	}
}

// contract_ok_handler is a well-formed handler for a declared command, used to
// prove the install path accepts a matching manifest/backend pair.
fn contract_ok_handler(params string) !string {
	return params
}

// services_shape proves the service model still carries a manifest of commands
// and still installs through one path. It builds its own one-command manifest
// so it can be called from run_contract as well as compiled.
fn services_shape() bool {
	mut r := bridge.new_router()
	mut backend := map[string]Handler{}
	backend[app_name + '.probe'] = contract_ok_handler
	manifest := services.Service{
		name:     app_name
		version:  app_version
		summary:  'contract probe'
		commands: [services.Command{
			name:   app_name + '.probe'
			params: services.no_params
			result: 'string'
		}]
	}
	services.install(mut r, manifest, backend) or { return false }
	return r.call_validated('1', app_name + '.probe', '').result == ''
}

// csp_shape proves webview still owns document sanitisation.
fn csp_shape(html string) string {
	return webview.inject_csp(html)
}

// ---- 2. types: names and arities we store or pass around -----------------

// type_contract is never called; referencing the types in a signature is the
// assertion. If any of these names changes, this stops compiling.
fn type_contract(
	mut router bridge.Router,
	registry capabilities.Registry,
	cfg config.VailsConfig,
	w config.WindowConfig,
	bundle config.BundleConfig,
	ctx webview.Ctx,
	svc services.Service,
	cmd services.Command,
	bus events.Bus,
	empty fn (params string) !void,
	any fn (params string) !void,
	handler fn (params string) !string
) {
	_ = router
	_ = registry
	_ = cfg
	_ = w
	_ = bundle
	_ = ctx
	_ = svc
	_ = cmd
	_ = bus
	_ = empty
	_ = any
	_ = handler
}

// command_contract asserts the manifest field names we set, because
// services.install reads them by name and a rename there would silently stop
// validating no-argument commands.
fn command_contract() services.Command {
	return services.Command{
		name:    app_name + '.probe'
		params:  services.no_params
		result:  'string'
		summary: 'contract probe'
	}
}

// service_contract asserts the manifest field names, including ts_types -
// which is where dts_text reads the TypeScript shapes from.
fn service_contract() services.Service {
	return services.Service{
		name:     app_name
		version:  app_version
		summary:  'contract probe'
		commands: [command_contract()]
		ts_types: ['\texport interface Probe { ok: boolean; }']
	}
}

// window_contract asserts config.WindowConfig's four fields, which host.v
// reads positionally through the struct it gets back from `window()`.
fn window_contract() config.WindowConfig {
	return config.WindowConfig{
		label:  'main'
		title:  'Fluxget'
		width:  1360
		height: 880
	}
}

// dev_contract asserts the DevServer fields we use.
fn dev_contract() dev.DevServer {
	return dev.DevServer{
		root:       '.'
		asset_root: 'frontend'
		port:       dev.default_port
		build_id:   '0'
		label:      'main'
	}
}

// ---- 3. reachability: the functions must work at runtime -----------------

// ContractReport is what the contract test reports. It is a value, not a
// panic: a test that cannot build a Router is a test failure, and the message
// has to survive to be useful.
pub struct ContractReport {
pub mut:
	ok              bool
	shapes_ok       bool
	router_calls    int
	frontier_ok     bool
	manifest_ok     bool
	registry_denies bool
	csp_idempotent  bool
	install_rejects bool
	notes           []string
}

// contract_rogue_handler is a valid handler that belongs to no command the
// probe manifest declares. services.install must refuse it.
fn contract_rogue_handler(params string) !string {
	return params
}

// contract_noop_ready is the on_ready signature the framework must still
// accept: a plain fn taking a webview.Ctx.
fn contract_noop_ready(_ webview.Ctx) {}

// type_contract_is_complete calls type_contract so it counts as used, and
// returns whether every type it referenced is still inhabited. It returns
// true when the call itself did not trap, which is the whole assertion.
fn type_contract_is_complete(reg capabilities.Registry) bool {
	mut r := bridge.new_router()
	type_contract(mut r, reg, config_shape_or_empty(), window_contract(),
		config.BundleConfig{}, webview.Ctx{}, service_contract(), command_contract(),
		events.Bus{}, bridge.validate_empty, bridge.validate_any, contract_rogue_handler)
	return true
}

// config_valid reports whether VailsConfig still passes its own validation.
// Written as a helper for the same reason as install_ok: validate() returns a
// bare bool, so `validate() == none` would be permanently false and a green
// test would mean nothing.
fn config_valid(cfg config.VailsConfig) bool {
	cfg.validate() or { return false }
	return true
}

// config_shape_or_empty is config_shape's error path, kept separate so
// type_contract can pass a real value without touching the filesystem.
fn config_shape_or_empty() config.VailsConfig {
	return config.default_config('contract')
}

// V TRAPS, all hit while building this file. They are collected here so the
// next person does not pay for them again:
//
//   1. A function returning only `!` (no value) yields a plain bool, not a
//      Result. `f() == none` is always false and `f() != none` always true -
//      both compile, both lie. Use `f() or { ... }`. See install_ok and
//      config_valid.
//   2. A map literal whose values are functions does not work. `{ 'k': fn }`
//      silently yields an empty map; a typed `map[string]F{ 'k': fn }` literal
//      does not parse. Build maps with `mut m := map[string]F{}` plus
//      assignment, exactly as vails services/install_test.v does.
//   3. `m.clone()` on a map does not satisfy V's aliasing check: mutating the
//      clone is rejected with "aliases mutable data from an immutable value".
//      Rebuild the map by assignment instead.
//   4. `.str()` on the result of `.len()` for a map-of-function miscompiles
//      (it emits a call to the map's own len function into a string slot).
//      Keep counts in int variables.
//   5. A `[json: 'name']` attribute on a struct field is miscompiled: the
//      codegen emits a phantom `<module>__json` embedded struct and the C
//      build fails. Struct field names are the wire names; see the WIRE FORMAT
//      RULE in commands.v.
//   6. Uppercase in a struct field name is rejected outright, so camelCase on
//      the wire is not reachable from V 0.5.x. snake_case, like vails itself.
//
// install_ok runs services.install and reports whether it was accepted.
//
// A V function that returns only `!` (no value) hands back a plain bool, so
// `install(...) == none` is always false and `install(...) != none` is always
// true - both compile happily and both lie. The `or {}` form is the only
// correct test, which is why this helper exists instead of the operator
// appearing anywhere else in the project.
fn install_ok(mut router bridge.Router, svc services.Service, b map[string]Handler) bool {
	services.install(mut router, svc, b) or { return false }
	return true
}

// run_contract exercises the parts of the contract that a compile check
// cannot: that the shape helpers still work, that Router.register_validated
// still routes, that a capability registry still denies, that inject_csp is
// still idempotent, and that services.install still refuses a
// manifest/handler mismatch.
//
// It opens no window and touches no network, so it runs inside `v test .`
// exactly like the vails repo's own tests.
pub fn run_contract() ContractReport {
	mut rep := ContractReport{}

	// Every shape helper, called for real. Compiling proves the signature;
	// calling it proves the value is still usable.
	//
	// config_shape touches the filesystem looking for vails.json, so it is
	// called with '.' and its result is only checked for having a name: a
	// missing file is load_config's error to report, not the contract's.
	mut reg := capabilities.new_registry()
	router_shape()
	mut probe_cfg := config_shape('.') or { config_shape_or_empty() }
	rep.shapes_ok = probe_cfg.name != '' && config_valid(probe_cfg)
	rep.shapes_ok = rep.shapes_ok && services_shape()
	dev_shape('.', 'frontend', dev.default_port, reg, 'main')
	events_shape('fluxget:contract', '{"probe":true}')
	webview_shape(reg, contract_noop_ready)
	window_contract()
	dev_contract()
	command_contract()
	service_contract()
	csp_shape('<html><head></head><body></body></html>')
	type_contract_is_complete(reg)

	// Router routing: register_validated must still dispatch to the handler.
	mut r := bridge.new_router()
	r.register_validated('fluxget.probe', bridge.validate_empty, contract_rogue_handler) or {
		return rep
	}
	res := r.call('1', 'fluxget.probe', 'payload')
	rep.router_calls = if res.err == '' { 1 } else { 0 }

	// Capability gating: an empty registry must deny. This is the T2 property
	// the browser extension and the frontend both rely on.
	rep.registry_denies = !reg.is_allowed('main', 'fluxget.probe')

	// The manifest must satisfy the framework's own install invariants: a
	// handler for a command the manifest does not declare must be refused.
	//
	// Built by assignment for the same reason as default_backend(): V 0.5.x
	// cannot parse a map literal whose values are functions.
	mut probe_router := bridge.new_router()
	mut rogue := map[string]Handler{}
	rogue['other.probe'] = contract_rogue_handler
	rep.install_rejects = !install_ok(mut probe_router, service_contract(), rogue)

	// Frontend document sanitisation: still injected once, still idempotent.
	once := webview.inject_csp('<html><head><title>x</title></head><body></body></html>')
	twice := webview.inject_csp(once)
	rep.csp_idempotent = once.contains('Content-Security-Policy')
		&& once.count('Content-Security-Policy') == 1
		&& twice.count('Content-Security-Policy') == 1

	// Our own manifest must be self-consistent: a handler for every declared
	// command, all in our own namespace. services.install is the framework's
	// own enforcement, so a green install is the assertion.
	mut own := bridge.new_router()
	svc := app_manifest()
	rep.manifest_ok = install_ok(mut own, svc, default_backend())
	for c in svc.commands {
		if !c.name.starts_with(app_name + '.') {
			rep.notes << ('command outside our namespace: ' + c.name)
		}
		if c.short_name() == '' {
			rep.notes << ('command has no short name: ' + c.name)
		}
	}

	rep.frontier_ok = rep.shapes_ok && rep.router_calls == 1 && rep.registry_denies
		&& rep.manifest_ok && rep.csp_idempotent && rep.install_rejects && rep.notes.len == 0
	rep.ok = rep.frontier_ok
	return rep
}
