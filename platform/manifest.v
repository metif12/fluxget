// manifest.v — Fluxget's own command surface, declared as a vails service.
//
// The service model (vails T5) is what keeps the security story honest: a
// command name in vails.json IS a capability grant, and services.install
// refuses to bind unless the manifest and the handler map agree exactly. So
// there is no third place where a command could be described differently.
//
// The surface grows one phase at a time. Adding a command means one cmd(...)
// line here plus one handler in commands.v — the vails grant in vails.json
// and the generated frontend/.d.ts follow from both.
module platform

import services

// app_name is the service namespace: 'fluxget' -> wire names 'fluxget.*'.
pub const app_name = 'fluxget'

// app_version is the Fluxget release this surface belongs to.
pub const app_version = '0.1.0'

// cmd is a one-line constructor; services.no_params means "no arguments",
// which makes the install path wire bridge.validate_empty for it.
fn cmd(name string, params string, result string, summary string) services.Command {
	return services.Command{
		name:    name
		params:  params
		result:  result
		summary: summary
	}
}

// app_manifest is the single description of what the frontend may call.
pub fn app_manifest() services.Service {
	return services.Service{
		name:     app_name
		version:  app_version
		summary:  'Fluxget: aria2 download manager commands.'
		commands: [
			cmd(app_name + '.ping', services.no_params, 'string',
				'Round-trip probe: proves JS -> V -> JS works.'),
			cmd(app_name + '.info', services.no_params, 'Info',
				'Build and host facts: version, OS, paths, dev mode.'),
			cmd(app_name + '.health', services.no_params, 'Health',
				'Engine health: aria2 connection, version, daemon state.'),
		]
		ts_types: app_ts_types()
	}
}

// app_ts_types are the TypeScript shapes the generated .d.ts refers to. They
// live in the manifest so codegen needs no second source.
//
// These names ARE the wire names: V encodes struct field names verbatim, and
// the [json: ...] attribute that would decouple the two is miscompiled by
// V 0.5.2. See the WIRE FORMAT RULE on BuildInfo in commands.v. The test
// `test_dts_text_agrees_with_the_wire_format` fails the build if an interface
// and a struct ever drift apart. snake_case matches the vails os_info service.
fn app_ts_types() []string {
	return [
		'\texport interface Info {',
		'\t\tapp: string;',
		'\t\tversion: string;',
		'\t\tos_name: string;',
		'\t\tarch: string;',
		'\t\texe_path: string;',
		'\t\troot: string;',
		'\t\tdev: boolean;',
		'\t\tfrontend: string;',
		'\t\tvails: string;',
		'\t}',
		'\texport interface Health {',
		'\t\tok: boolean;',
		'\t\tmode: string;',
		'\t\taria2: string;',
		'\t\tconnected: boolean;',
		'\t\tdetail: string;',
		'\t}',
	]
}
