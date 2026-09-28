// engine.v - the app-facing facade over aria2.
//
// The Engine is the only thing in Fluxget that talks to aria2. Everything above
// it - core, platform, the Control API - goes through here, and that is not
// tidiness: it is where the domain rules live, because a rule enforced in two
// places is a rule that will be enforced in one of them.
//
// Two rules from CONTEXT.md are enforced here rather than in the UI, and they
// are the reason this file is more than a pass-through:
//
//   * A Download's Selection (aria2's select-file) may only change while the
//     item is waiting or paused. aria2 restarts an ACTIVE download to apply it,
//     which throws away its connections and its position in the queue. The UI
//     only offers the picker before the item starts, but "only offers" is a
//     suggestion and this is a refusal.
//
//   * A Magnet is a URI, not a separate kind of thing. add_magnet is add_uris
//     with one element, so there is one code path and one set of rules.
//
// Everything is testable without a socket because rpc.Client takes an injected
// Transport. The tests in this module drive rpc.Fake and assert on the recorded
// request bodies, which is the only way to check that a rule became the right
// aria2 call.
module engine

import rpc

// How much of the queue one tick asks for.
//
// Both are caps on the RESPONSE, not on the queue: aria2 keeps everything, we
// just do not pull it all across a loopback socket every 500ms. aria2's own
// defaults are effectively unlimited, and a user with 2000 finished downloads
// would make every tick megabytes of JSON for rows nobody is looking at.
pub const waiting_window = 200
pub const stopped_window = 100

// max_add_uris is how many mirrors one add may carry.
//
// aria2 will happily take thousands, and so will a malformed frontend loop. The
// cap is generous for real mirror lists and small enough that a bug is visible
// as a rejected request rather than as a queue that mysteriously stops.
pub const max_add_uris = 200

// status_active is the one status that makes a Selection change illegal.
pub const status_active = 'active'

// Engine holds the client. A value, not a pointer: the transport is a shared
// closure and rpc.Client's mutable state is just the request id counter, which
// rpc.Client's own comment describes as cosmetic.
pub struct Engine {
pub mut:
	client rpc.Client
}

// new builds an Engine over an existing client.
pub fn new(client rpc.Client) Engine {
	return Engine{
		client: client
	}
}

// AddRequest is one "download this" instruction.
//
// It is a struct rather than a parameter list because the three sources of an
// add - the UI's URL box, the browser extension's Grab, and a .torrent drop -
// all need the same fields, and a positional signature would make the third one
// pass a torrent's base64 in the slot meant for a URI.
pub struct AddRequest {
pub mut:
	// uris are the sources. Several means mirrors of ONE download, which is
	// aria2's multi-source fetching; several addUri calls would be several
	// downloads. See CONTEXT.md, URI.
	uris []string
	// dir overrides the daemon's --dir for this item. Empty means the daemon's
	// setting, which is what the user configured in Settings.
	dir string
	// out is the file name to save as. Empty lets aria2 derive it from the URI.
	out string
	// select_file is a torrent Selection, aria2's own syntax: "1,3-5".
	select_file string
	// paused stages the item without starting it. How a torrent whose files the
	// user has not chosen yet is added: the picker needs a paused item to be
	// meaningful, and an active item would start fetching immediately.
	paused bool
}

// clean_uris drops blank entries and returns the rest, or an error if nothing
// usable is left.
//
// An empty add is refused rather than sent. aria2 accepts `addUri` with an
// empty array and answers "OK", which is a lie with no gid in it, and the UI
// would then wait forever for a download that does not exist.
pub fn (r AddRequest) clean_uris() ![]string {
	mut out := []string{cap: r.uris.len}
	for u in r.uris {
		v := u.trim_space()
		if v == '' {
			continue
		}
		out << v
	}
	if out.len == 0 {
		return error('engine: no uri to download')
	}
	if out.len > max_add_uris {
		return error('engine: ${out.len} uris is more than the ${max_add_uris} allowed for one download')
	}
	return out
}

// options renders the per-download option map.
//
// Built by assignment, never as a map literal: see the V trap list in
// platform/contract.v, and rpc/rpc.v does the same for the same reason.
//
// An absent key and a present empty one are different instructions to aria2, so
// every optional field is omitted rather than sent empty. `pause` is the one
// exception: it is only sent when true, because `pause=false` is a redundant
// instruction that still costs a round trip inside the add.
pub fn (r AddRequest) options() map[string]string {
	mut m := map[string]string{}
	if r.dir != '' {
		m['dir'] = r.dir
	}
	if r.out != '' {
		m['out'] = r.out
	}
	if r.select_file != '' {
		m['select-file'] = r.select_file
	}
	if r.paused {
		m['pause'] = 'true'
	}
	return m
}

// add starts a download and returns its GID.
//
// The GID is the return value rather than a detail buried in a struct because
// it is the only handle the rest of Fluxget has: the UI's row, the history
// entry and the scheduler's target are all keyed by it.
pub fn (mut e Engine) add(r AddRequest) !string {
	uris := r.clean_uris()!
	return e.client.add_uri(uris, r.options())
}

// add_magnet adds a magnet link. CONTEXT.md is explicit that a Magnet is a URI
// form, so this is a one-line convenience over add and not a second code path.
pub fn (mut e Engine) add_magnet(magnet string, dir string) !string {
	return e.add(AddRequest{
		uris: [magnet]
		dir:  dir
	})
}

// add_torrent adds a torrent from its raw bytes, base64 encoded the way
// aria2.addTorrent expects them over JSON-RPC.
//
// `fallbacks` are web seeds / trackers, and are passed through unchanged: this
// is the Control API's Grab payload, where the extension has bytes it cannot
// name as a URI.
pub fn (mut e Engine) add_torrent(base64_data string, fallbacks []string, r AddRequest) !string {
	if base64_data == '' {
		return error('engine: a torrent add needs the .torrent bytes')
	}
	return e.client.add_torrent(base64_data, fallbacks, r.options())
}

// add_staged adds a torrent paused, with a Selection applied, which is how the
// file picker gets an item it can show.
pub fn (mut e Engine) add_staged(base64_data string, select_file string) !string {
	return e.add_torrent(base64_data, [], AddRequest{
		select_file: select_file
		paused:      true
	})
}

// ---- queue and lifecycle -------------------------------------------------

// The queue controls. Thin on purpose: aria2's semantics are already the
// domain's semantics (CONTEXT.md passes Status through unchanged), and inventing
// a translation layer here would be the place for a bug to hide.

pub fn (mut e Engine) pause(gid string) !string {
	return e.client.pause(gid)
}

pub fn (mut e Engine) resume(gid string) !string {
	return e.client.resume(gid)
}

// remove takes a download off the queue. The result stays on disk and in
// tellStopped; forget is what discards the record.
pub fn (mut e Engine) remove(gid string) !string {
	return e.client.remove(gid)
}

pub fn (mut e Engine) forget(gid string) !string {
	return e.client.remove_result(gid)
}

pub fn (mut e Engine) pause_all() !string {
	return e.client.pause_all()
}

pub fn (mut e Engine) resume_all() !string {
	return e.client.resume_all()
}

// move reorders the queue. `how` is aria2's keyword string, so the three
// constants are spelled here rather than passed as literals from the frontend.
pub const pos_set = 'POS_SET'
pub const pos_cur = 'POS_CUR'
pub const pos_end = 'POS_END'

pub fn (mut e Engine) move(gid string, pos int, how string) !int {
	return e.client.change_position(gid, pos, how)
}

pub fn (mut e Engine) move_to_top(gid string) !int {
	return e.client.change_position(gid, 0, pos_set)
}

pub fn (mut e Engine) move_to_end(gid string) !int {
	return e.client.change_position(gid, 0, pos_end)
}

// ---- the Selection rule --------------------------------------------------

// set_selection applies a torrent's file Selection, refusing to do it to an
// active download.
//
// `current_status` is the item's Status, passed in rather than fetched, because
// the caller has just read it in this tick's snapshot and a second
// tellStatus would be a round trip per click to learn something already on the
// table. The race this leaves - the item starts between the snapshot and the
// call - is resolved by aria2 itself, which restarts the item rather than
// corrupting it; the check here exists to make the common case a clear error
// instead of a silent restart.
pub fn (mut e Engine) set_selection(gid string, select_file string, current_status string) !string {
	if select_file == '' {
		return error('engine: a selection needs at least one file index')
	}
	if current_status == status_active {
		return error('engine: cannot change the files of an active download; aria2 would restart it and lose its position in the queue. Pause it first.')
	}
	return e.client.change_option(gid, {
		'select-file': select_file
	})
}

// ---- reads ---------------------------------------------------------------

// snapshot is one system.multicall: global stats, the three queues, the version
// and the global options. One round trip because it is the UI's heartbeat and
// six sequential calls would make the window stutter on every beat.
//
// This is CONTEXT.md's Snapshot, and the reason the app never makes three round
// trips to render a list.
pub fn (mut e Engine) snapshot() !rpc.Snapshot {
	return e.client.snapshot(waiting_window, stopped_window)
}

// files is one download's file list, for the torrent picker.
pub fn (mut e Engine) files(gid string) ![]rpc.FileEntry {
	return e.client.get_files(gid)
}

// is_ready is the liveness probe: a daemon that answers this is up, whatever
// the spawner believes. A successful spawn only means the process started.
pub fn (mut e Engine) is_ready() bool {
	e.client.version() or { return false }
	return true
}
