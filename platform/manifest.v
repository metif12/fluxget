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
//
// Three commands carry a payload or a big result (tick, add, health) and two do
// not (ping, info). The distinction is load-bearing: services.install wires
// bridge.validate_empty for a no_params command and bridge.validate_any for one
// that declares a type, so `params` here is simultaneously the .d.ts signature
// and the framework's params gate. A command declared as no_params that starts
// accepting a payload is a security change, not a refactor.
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
			cmd(app_name + '.tick', services.no_params, 'Tick',
				'One poll of the engine: the queue, global stats, queued notices and the log tail. The UI heartbeat.'),
			cmd(app_name + '.add', 'AddParams', 'string',
				'Add a download by URI, magnet or .torrent. Returns the new GID.'),
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
//
// Tab-indented because services.dts emits these inside the service namespace
// without re-indenting.
//
// The Tick shape is nested on purpose. A flat Tick would be a single flat
// interface with thirty fields, and the moment a second view wanted "just the
// queue" it would either take the lot or need a second command. Split by what
// the UI actually renders - the counters, a row, an event - and a later view can
// take the pieces.
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
		'\t\taria2_path: string;',
		'\t\taria2_source: string;',
		'\t}',
		'\texport interface Stat {',
		'\t\tdownload_speed: string;',
		'\t\tupload_speed: string;',
		'\t\tnum_active: number;',
		'\t\tnum_waiting: number;',
		'\t\tnum_stopped: number;',
		'\t}',
		'\texport interface Download {',
		'\t\tgid: string;',
		'\t\tname: string;',
		'\t\tstatus: string;',
		'\t\tpercent: number;',
		'\t\ttotal: string;',
		'\t\tdone: string;',
		'\t\tspeed: string;',
		'\t\tupload: string;',
		'\t\teta: string;',
		'\t\tis_torrent: boolean;',
		'\t\tseeder: boolean;',
		'\t\tdir: string;',
		'\t\terror: string;',
		'\t}',
		'\texport interface Notice {',
		'\t\tkind: string;',
		'\t\tgid: string;',
		'\t\ttext: string;',
		'\t\tat_ms: number;',
		'\t}',
		'\texport interface Tick {',
		'\t\tok: boolean;',
		'\t\tphase: string;',
		'\t\tdetail: string;',
		'\t\tsupervised: boolean;',
		'\t\taria2_path: string;',
		'\t\taria2_source: string;',
		'\t\tversion: string;',
		'\t\tfeatures: string[];',
		'\t\trestart_in_ms: number;',
		'\t\tuptime_ms: number;',
		'\t\tticks: number;',
		'\t\tstat: Stat;',
		'\t\tdownloads: Download[];',
		'\t\tnotices: Notice[];',
		'\t\tlogs: string[];',
		'\t\tlogs_dropped: number;',
		'\t}',
		'\texport interface AddParams {',
		'\t\turis: string[];',
		'\t\tdir: string;',
		'\t\tout: string;',
		'\t\tpaused: boolean;',
		'\t}',
	]
}
