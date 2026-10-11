// details.v - fluxget.details: the full record for ONE download.
//
// Why this is its own command and not more fields on the tick
//
// The tick carries the row itself - the eight fields that fit in a queue row - and
// one poll a second for the whole queue. A details dialog shows thirty fields for
// one download, and two of them (the file list, the tracker list) are separate
// aria2 calls.
//
// Putting them on the tick would have meant those calls running for EVERY row
// EVERY second, to fill a dialog that is open for one row at a time. It would also
// have put `verified_length` and `num_seeders` on a plain HTTP download, where they
// mean nothing, and a UI has no way to tell "0 seeders because there are none" from
// "0 seeders because nobody is seeding".
//
// So: one command, one row, on demand. The tick stays the size of a summary.
module platform

import json2
import rpc
import engine

// Detail is everything the row is not.
//
// Written out rather than reusing rpc.Status, because the wire format is ours and
// the field names are ours - rpc's are aria2's camelCase, which AGENTS.md section 5
// already rules out for the bridge. This is where aria2's vocabulary becomes
// Fluxget's.
pub struct Detail {
pub mut:
	gid         string
	name        string
	status      string
	percent     f64
	total       string
	done        string
	speed       string
	upload      string
	uploaded    string
	eta         string
	dir         string
	connections string
	error       string
	// The torrent-only fields. Empty for a plain download, and the frontend hides
	// an empty row rather than printing "0" for a thing that does not apply.
	info_hash       string
	num_pieces      int
	piece_length    string
	verified_length string
	num_seeders     int
	num_leechers    int
	trackers        []string
	files           []string
	// The sources this download was added from, and what aria2 is doing with each
	// of them. Two lists, not one, because "added" and "in use" are different
	// states and the UI shows a mirror as dead only when it knows the difference.
	uris []string
	live []string
	idle []string
}

// details_params_bytes bounds the request. A gid and nothing else, so a small cap
// is honest rather than generous.
pub const details_params_bytes = 512

// details_json is fluxget.details.
//
// Three aria2 calls - tellStatus, getFiles, getServers - and each one is allowed
// to fail independently. A single aria2 error must not blank the dialog:
//
//   * a torrent that has not announced yet answers an empty tracker list, not an
//     error, but an HTTP download answers an error, and that is not worth hiding
//     everything else for;
//   * getFiles on a magnet that has no metadata answers an error too.
//
// So each is `or { empty }` with the reason in a comment, and the dialog shows what
// it has.
pub fn (mut app App) details_json(params string) !string {
	if params.len > details_params_bytes {
		return error('fluxget.details: the request is ${params.len} bytes; the limit is ${details_params_bytes}')
	}
	if params.trim_space() == '' {
		return error('fluxget.details: gid is required')
	}
	mut p := GidParams{}
	if params.trim_space() != '' {
		p = json2.decode[GidParams](params) or {
			return error('fluxget.details: bad params: ' + err.msg())
		}
	}
	gid := require_gid('fluxget.details', p.gid) or { return err }

	app.state.lock()
	defer {
		app.state.unlock()
	}
	s := app.state.eng.client.tell_status(gid, []) or { return error('fluxget.details: ' + err.msg()) }

	mut d := Detail{
		gid:             s.gid
		name:            s.display_name('')
		status:          s.status
		percent:         s.percent()
		total:           engine.size_text(s.total_length)
		done:            engine.size_text(s.completed_length)
		speed:           engine.rate_text(s.download_speed)
		upload:          engine.rate_text(s.upload_speed)
		uploaded:        engine.size_text(s.upload_length)
		eta:             if s.is_finished() { '' } else { engine.eta_text(s.eta_seconds()) }
		dir:             s.dir
		connections:     if s.connections > 0 { '${s.connections} in use' } else { '' }
		error:           s.error
		info_hash:       if s.is_torrent() { s.info_hash } else { '' }
		num_pieces:      s.num_pieces
		verified_length: if s.verified_length > 0 {
			engine.size_text(s.verified_length)
		} else {
			''
		}
	}

	if s.piece_length > 0 {
		d.piece_length = engine.size_text(s.piece_length)
	}

	if s.is_torrent() {
		d.num_seeders = s.num_seeders
		d.num_leechers = s.num_leechers
		// A torrent that has not talked to a tracker yet answers an empty list,
		// which is a real state and not an error - so it is shown as no trackers.
		for t in app.state.eng.client.get_trackers(gid) or { []rpc.Tracker{} } {
			if t.uri != '' {
				d.trackers << t.uri
			}
		}
	}

	// The files, and only the ones worth naming. A torrent with forty files shows
	// forty; aria2's own cap is what stops a hostile .torrent from making a dialog
	// with ten thousand rows.
	for f in app.state.eng.client.get_files(gid) or { []rpc.FileEntry{} } {
		if f.path != '' {
			d.files << f.path
		}
	}

	// The mirror set, from the same place Phase 4 read it. Remembered first
	// because aria2 forgets the source of a failed download - the fact that made
	// retry need a remembered list.
	set := engine.mirror_set_from(app.state.remembered(gid)) or { engine.MirrorSet{} }
	for m in set.uris {
		d.uris << m
	}
	for m in (app.state.eng.mirror_state(gid, set.uris) or { []engine.Mirror{} }) {
		if m.in_use {
			d.live << m.uri
		} else {
			d.idle << m.uri
		}
	}
	return json2.encode(d)
}
