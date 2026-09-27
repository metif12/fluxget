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
import time

// http_transport returns a Transport that POSTs a JSON body to an endpoint.
//
// http.post_json rather than the Request/FetchConfig pair: it already sets the
// content type and returns the body, and the lower-level API wants three
// arguments and a config struct, which is more surface than this needs.
pub fn http_transport(endpoint string, timeout_ms int) Transport {
	return fn [endpoint, timeout_ms] (body string) !string {
		started := time.now()
		res := http.post_json(endpoint, body) or {
			return error('rpc: ${endpoint}: ' + err.msg())
		}
		elapsed := time.now() - started
		if timeout_ms > 0 && elapsed > timeout_ms {
			return error('rpc: ${endpoint} took ${elapsed}ms (limit ${timeout_ms}ms)')
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
