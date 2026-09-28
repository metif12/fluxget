// http.v - the real transport, and the only file in rpc/ that knows about HTTP.
//
// Everything else in this module takes a Transport, so this is the one place
// that can be swapped for a fake. It is also the one place that can be wrong in
// a way nobody notices until a download stalls, so the rules are explicit:
//
//   * loopback only. aria2's RPC is unauthenticated by default and the secret
//     is a bearer token in the request body; binding it to 0.0.0.0 would put
//     that token on the local network. aria2ctl/conf.v passes
//     --rpc-listen-all=false for the same reason, and is_loopback() is the
//     belt to that braces.
//   * a measured timeout. The UI heartbeat cannot be allowed to hang behind a
//     wedged daemon, so a slow answer is reported as a failure.
module rpc

import net.http

// http_transport returns a Transport that POSTs a JSON body to an endpoint.
//
// Built from http.fetch with an explicit config rather than http.post_json,
// because the timeout is the point and post_json does not accept one. Three
// things that were wrong before, all found by the Phase 1 end-to-end run rather
// than by a test, because the rpc suite only ever used the fake transport:
//
//   * The budget was compared against the wrong unit. `elapsed` is a
//     time.Duration whose value is NANOSECONDS, and it was compared to a
//     millisecond number: 1_000_000 > 5_000 is true after ONE millisecond, so
//     every single real call reported a timeout. Nothing caught it because
//     http_transport had no test and no caller until the app talked to a real
//     aria2. `rpc: ... took 1.000msms (limit 5000ms)` is what the UI showed.
//   * The measurement was a REPORT, not a bound. The elapsed time was only
//     checked after post_json returned, so a daemon that never answered blocked
//     forever and the check never ran. read_timeout/write_timeout are handed to
//     the socket layer, so the bound is now actually enforced.
//   * Duration.str() already prints "ms", so the message had "msms" in it.
pub fn http_transport(endpoint string, timeout_ms int) Transport {
	return fn [endpoint, timeout_ms] (body string) !string {
		// A Duration is nanoseconds internally, and the config wants i64
		// nanoseconds, so the millisecond budget is scaled explicitly. A zero or
		// negative budget means "no bound of our own", which leaves net.http's
		// own 30s defaults alone rather than setting a nonsensical zero.
		budget := i64(timeout_ms) * 1000000
		mut cfg := http.FetchConfig{
			url:    endpoint
			method: .post
			data:   body
			header: http.new_header(key: .content_type, value: 'application/json')
		}
		if budget > 0 {
			cfg.read_timeout = budget
			cfg.write_timeout = budget
		}
		res := http.fetch(cfg) or {
			return error('rpc: ${endpoint}: ' + err.msg())
		}
		return res.body
	}
}

// with_http returns a copy of the client wired to the real network.
pub fn (c Client) with_http() Client {
	return c.with_transport(http_transport(c.endpoint, c.timeout_ms))
}

// is_loopback reports whether an endpoint points at this machine. The setup
// screen uses it to refuse a remote RPC endpoint: a token over the network is a
// token on the network, and the daemon is always a child process.
pub fn is_loopback(endpoint string) bool {
	return endpoint.starts_with('http://127.0.0.1:')
		|| endpoint.starts_with('http://localhost:')
		|| endpoint.starts_with('http://[::1]:')
}
