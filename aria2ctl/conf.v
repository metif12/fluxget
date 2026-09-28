// conf.v - turning Fluxget's settings into an aria2c command line.
//
// This function is pure on purpose. It takes a Conf and returns a []string. It
// writes nothing, reads nothing, and depends on no environment variable, so
// the entire spawn contract is a value that `v test` can assert on. The
// supervisor is the only thing that turns that value into a process.
//
// Four arguments are not optional, and each one is a decision rather than a
// default:
//
//   --no-conf=true
//       aria2c reads %USERPROFILE%\.aria2\aria2.conf by default. A user who has
//       their own aria2 almost certainly has a file there, and it may well set
//       --rpc-listen-port, --rpc-secret or --dir. Inheriting it would mean the
//       app silently supervised somebody else's configuration, and the RPC
//       port we told rpc.Client to call would be the wrong one. The child has
//       to be hermetic: everything it needs, we pass.
//
//   --enable-rpc
//       aria2 1.32+ ships with RPC off. Without this there is no endpoint at
//       all and the first tick cannot even ask whether the engine is alive.
//
//   --rpc-secret=<random per start>
//       The token is a bearer credential in the request body, not a login. A
//       fresh one per app start means a captured request is worthless once the
//       app restarts, and not persisting it to disk means there is no secret
//       file to steal. The threat is a local process guessing a token on a
//       loopback port; the browser extension never sees it (see CONTEXT.md,
//       Control API).
//
//   --rpc-listen-all=false
//       The loopback bind. With it true, the token above is on the local
//       network, where every machine on the wifi can post to our RPC port.
//       rpc.is_loopback() re-checks the endpoint before the first call for the
//       same reason: belt to braces, and a test asserts it.
//
// The port is deliberately NOT aria2's default 6800. See default_rpc_port.
//
// The order of the returned arguments is fixed, and conf_test.v asserts it
// positionally. There is no performance reason for an order; the reason is that
// a spawn line you can diff in a bug report is worth more than the two
// comparisons a sorted map would save.
module aria2ctl

// COMPAT(v): `crypto.rand` is miscompiled by V 0.5.2 under its own name. The
// import below is ALIASED and the alias is load-bearing, not cosmetic:
//
//     import crypto.rand            ->  src.c: 'crypto' undeclared
//                                        string__bytes(crypto.rand)
//     import crypto.rand as csprng  ->  compiles, links, runs
//
// The codegen drops the module qualifier and then resolves the trailing
// selector against a string, so the call comes out as String.bytes on a variable
// named `crypto`. It is a hard C build error, not a warning, and it only shows
// up at link time - comptime is clean. Drop the alias only after checking
// v/compiler, and re-run the secret test: a silent fallback to a weak PRNG here
// would be invisible.
import crypto.rand as csprng
import os

// default_rpc_port is where Fluxget's own daemon listens.
//
// Not 6800, which is aria2's default, and not a random port. A user's own
// aria2 - the one they run from a terminal, or as a service - already holds
// 6800, and a second daemon cannot have it. Worse, the failure mode of guessing
// wrong is not a clean error: Fluxget would start, its first tick would reach
// the *user's* aria2 with our secret, get an auth error, and report "engine not
// ready" while the real engine we spawned died on the bind. 16800 is in aria2's
// own documented range, far from the defaults of the neighbouring tools that
// pick ports (16809 for its WebSocket client, 6801 for the old XML-RPC), and
// stable across restarts so the session file and the Control API can name it.
pub const default_rpc_port = 16800

// default_rpc_host is the loopback address, never a hostname. 'localhost' can
// resolve to ::1 on a machine with IPv6 enabled, and aria2 binds 127.0.0.1 when
// --rpc-listen-all is false, so the client would be talking to a socket nothing
// is listening on.
pub const default_rpc_host = '127.0.0.1'

// The default layout under a project root. Named so the supervisor, the Setup
// page and the tests all build the same paths from one place.
pub const downloads_dir_name = 'downloads'
pub const session_file_name = 'aria2.session'
pub const log_file_name = 'aria2.log'

// secret_bytes is the entropy behind --rpc-secret. 24 bytes is 192 bits, hex
// encoded to 48 characters: far past the point where a loopback port is
// brute-forceable, and short enough that it fits comfortably in a request body
// and in a log line we might have to show a user.
pub const secret_bytes = 24

// session_interval_sec is --save-session-interval.
//
// Without it aria2 writes the session file only on a *clean* exit, so a crash or
// a kill loses the whole queue - which is the one thing the session file exists
// to prevent. 60s is the value from aria2's own manual and caps the loss from an
// unclean stop at one minute of queue.
pub const session_interval_sec = 60

// Conf is everything aria2c needs to know at spawn time.
//
// Every field is an input. Nothing here is read from the environment, and no
// function in this file consults one, so a test can build a Conf and know
// exactly what the child will be told.
pub struct Conf {
pub mut:
	// binary is the absolute path to aria2c, as locate.v resolved it.
	binary string
	// host and port are where rpc.Client will connect. The daemon's bind
	// address is decided by --rpc-listen-all=false; these are what we dial.
	host string = default_rpc_host
	port int    = default_rpc_port
	// secret is the --rpc-secret token. Generated per app start by new_secret.
	secret string
	// dir is where downloads are written. Empty omits --dir and lets aria2 use
	// its own default, which is the cwd - almost never what a desktop app wants,
	// so callers set it.
	dir string
	// session_file is BOTH --input-file and --save-session. Same file, which is
	// the round trip aria2's manual documents.
	//
	// Empty omits both and runs without persistence: a download started in this
	// session is gone when the app closes. That is a legitimate degraded mode,
	// and it is the reason this is a field rather than a constant.
	session_file string
	// log_file is aria2's own --log, kept on disk for after the fact. The Logs
	// tab reads the process's stderr instead, so this is not what the UI shows.
	log_file string
	// download_limit and upload_limit are the GLOBAL caps, in bytes per second,
	// written as --max-overall-*. Zero means unlimited, and zero is also how a
	// caller says "no cap", so the flag is omitted entirely rather than passed
	// as 0.
	download_limit int
	upload_limit   int
	// max_concurrent is --max-concurrent-downloads. Five is aria2's own default;
	// Fluxget sets it explicitly so the number in the UI is the number in the
	// spawn line rather than a guess about a version's default.
	max_concurrent int = 5
	// console_level is --console-log-level, i.e. what arrives on stderr and
	// becomes the Logs tab. 'warn' rather than 'info': aria2's info level logs
	// every chunk of every download, which is a firehose a UI cannot render.
	console_level string = 'warn'
	// log_level is --log-level, for the on-disk log. 'notice' keeps the file
	// useful after the fact without growing without bound.
	log_level string = 'notice'
	// session_interval is --save-session-interval in seconds; see the const.
	session_interval int = session_interval_sec
}

// conf_for builds a Conf with the standard layout under a project root. Pure:
// string joins only, so the paths are testable without a disk.
pub fn conf_for(root string, binary string, port int, secret string) Conf {
	return Conf{
		binary:       binary
		port:         port
		secret:       secret
		dir:          os.join_path(root, downloads_dir_name)
		// The engine's own state lives beside the binary we fetched, not in the
		// user's profile: runtime/ is already gitignored, and keeping it there
		// means deleting the directory is a complete uninstall of the engine's
		// state.
		session_file: os.join_path(root, runtime_dir, session_file_name)
		log_file:     os.join_path(root, runtime_dir, log_file_name)
	}
}

// args is the spawn contract. Pure, deterministic, and asserted positionally by
// conf_test.v.
pub fn args(c Conf) []string {
	mut out := []string{cap: 20}

	// Hermetic first. If everything after this is wrong, at least these are not
	// inherited from someone else's config file.
	out << '--no-conf=true'

	// The RPC surface. See the header for why each of these four is mandatory.
	out << '--enable-rpc'
	// Loopback only: the secret is a bearer token in the request body, and
	// binding 0.0.0.0 would put it on the local network.
	out << '--rpc-listen-all=false'
	out << '--rpc-listen-port=${c.port}'
	out << '--rpc-secret=${c.secret}'

	// Where things land. Each omitted when empty rather than passed as '',
	// because an empty --dir is not "the default", it is a relative path.
	if c.dir != '' {
		out << '--dir=${c.dir}'
	}

	// The queue survives a restart. Same file in, same file out.
	if c.session_file != '' {
		out << '--input-file=${c.session_file}'
		out << '--save-session=${c.session_file}'
		out << '--save-session-interval=${c.session_interval}'
	}

	// Resume rather than restart-from-zero. Without it an interrupted download
	// re-fetches every byte it already has, which is the single most
	// user-visible way to waste someone's bandwidth.
	out << '--continue=true'

	out << '--max-concurrent-downloads=${c.max_concurrent}'

	// The global speed caps, matching the "Global" layer in CONTEXT.md's Limit.
	// Omitted at 0 so "no cap" never has to be expressed as a magic value.
	if c.download_limit > 0 {
		out << '--max-overall-download-limit=${c.download_limit}'
	}
	if c.upload_limit > 0 {
		out << '--max-overall-upload-limit=${c.upload_limit}'
	}

	// The on-disk log, separate from the stderr the Logs tab reads.
	if c.log_file != '' {
		out << '--log=${c.log_file}'
		out << '--log-level=${c.log_level}'
	}

	// Last, because it is the only one the app consumes live.
	out << '--console-log-level=${c.console_level}'
	return out
}

// A deliberate omission, recorded here so nobody "fixes" it later: no --daemon.
//
// aria2c -d/--daemon detaches and forks, which would leave us with a process
// handle for a parent that has already exited, no stderr pipe to read, and no
// way to ask rpc.wait_ready to wait for something we are no longer the parent
// of. Fluxget supervises a foreground child, which is the only shape
// os.Process can actually supervise.

// value_of returns the text after `=` in `--flag=value`, or `none`. Test support
// for the argument-shape assertions; kept here rather than in conf_test.v
// because a _test.v file shares the module's namespace and two test files would
// each want this.
pub fn value_of(args []string, flag string) ?string {
	prefix := flag + '='
	for a in args {
		if a.starts_with(prefix) {
			return a[prefix.len..]
		}
	}
	return none
}

// has_flag reports whether a bare flag (no `=value`) is present.
pub fn has_flag(args []string, flag string) bool {
	return flag in args
}

// new_secret mints the --rpc-secret token.
//
// crypto.rand, not vlib/rand: on Windows that is BCryptGenRandom, a real CSPRNG
// with its own #flag in the V source, so Get-VCFlags needs no change. vlib/rand
// is seeded from the clock, and a token derived from the clock is a token an
// attacker can narrow down to a few thousand guesses.
//
// Returns empty when the OS refuses, and the caller must treat that as a hard
// error rather than spawning a daemon with an empty --rpc-secret. aria2 accepts
// `--rpc-secret=` and then requires no token at all, so an empty secret would
// turn "authenticated loopback RPC" into "open loopback RPC" without one word of
// complaint from either side.
pub fn new_secret() string {
	raw := csprng.bytes(secret_bytes) or { return '' }
	// `len` alongside `init`, not `cap` alongside `init`: V 0.5.2 rejects the
	// combination outright ("cannot use `init` attribute unless `len` attribute
	// is also provided"). `init` exists to make assignment into every slot legal,
	// which is only meaningful for an array that already has that many slots.
	mut out := []u8{len: secret_bytes * 2, init: u8(0)}
	for i, b in raw {
		out[i * 2] = hex_digit(b >> 4)
		out[i * 2 + 1] = hex_digit(b & 0x0f)
	}
	return out.bytestr()
}

// hex_digits is the alphabet. A const table rather than arithmetic on the digit
// value, because "n < 10 ? 48 + n : 87 + n" is the kind of line that is right
// until someone changes the offset.
const hex_digits = '0123456789abcdef'

fn hex_digit(n u8) u8 {
	return hex_digits[n]
}
