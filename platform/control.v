// control.v - fluxget's row operations and its settings commands.
//
// Phase 1 gave us a queue you can watch. Phase 3 is the difference between a
// status display and a download manager: every row has to be operable, and the
// limits a user sets have to still be set tomorrow.
//
// The shape follows platform/app.v's add_json exactly, and the reasons are the
// same ones:
//
//   * A params struct, because the framework only checks that a body is JSON.
//     Everything else is validated HERE, before a gid reaches the engine.
//   * A byte cap, so a megabyte of JSON is a rejection and not a freeze.
//   * app.state.lock() around every engine call, because a tick runs on the same
//     state and two of them interleaving is a corrupted queue rather than a lost
//     frame.
//   * Errors travel as REJECTIONS. "No such download" must not be an empty
//     success - a UI that cannot tell them apart will report a button press that
//     did nothing as a button press that worked.
//
// What is deliberately absent: any command that could reach a path the user did
// not name. There is no "open this directory", no "run this", and the settings a
// user can change are limits and paths - nothing that executes anything.
module platform

import json2
import core
import engine
import rpc

// control_params_bytes bounds a control request. A gid and a couple of numbers
// is a few hundred bytes; 4096 is generous and still small.
pub const control_params_bytes = 4096

// GidParams is the body of every single-row command.
//
// One struct for pause, resume, remove, retry and move, rather than five, because
// they differ only in what they do with the gid and the frontend would otherwise
// have five near-identical payload shapes to get subtly different.
pub struct GidParams {
pub mut:
	gid string
}

// MoveParams extends GidParams with a queue position.
//
// `pos` is an aria2 index, so it is 0-based and `how` decides what it means
// relative to: POS_SET is absolute, POS_CUR is an offset. The frontend sends an
// absolute position and this layer converts, so the arithmetic that decides
// "one row up" lives in one place and not in the browser.
pub struct MoveParams {
pub mut:
	gid string
	// delta is how many places to move, and it is what the arrow keys produce:
	// -1 for up, +1 for down. `pos` stays for a future "drag to position".
	delta int
}

// RemoveParams adds the one decision a remove needs: whether to KEEP the record.
//
// The flag is named `keep_record` and not `purge` for a reason that cost a test to
// find: a JSON body that omits a bool decodes it as FALSE, whatever default the
// struct was initialised with. So `purge: true` as a default was silently
// overwritten by every payload that did not spell it out - which is every payload
// the frontend sends - and Remove stopped discarding anything.
//
// Naming the flag so that its ZERO value is the behaviour we want makes the
// default immune to that: absent means false means "purge". A default set before
// decoding is not a default, it is a value a decoder can overwrite.
pub struct RemoveParams {
pub mut:
	gid string
	// keep_record leaves the finished/failed history entry in place. Off by
	// default, because a Remove button which leaves the item visible in a list is
	// not removing anything.
	keep_record bool
}

// ItemOptionsParams sets per-download options on an existing gid.
//
// Options are a map of strings because that is aria2's own shape, and re-deciding
// which options are settable per download here would mean maintaining a list that
// drifts from aria2's documentation. What this layer refuses is a key that is
// obviously not an option at all.
pub struct ItemOptionsParams {
pub mut:
	gid     string
	options map[string]string
}

// settings_params_bytes bounds a settings write.
pub const settings_params_bytes = 16384

// require_gid is the one piece of validation every row command needs.
//
// An empty gid is refused rather than passed on, because aria2's answer to a bad
// gid is an error naming a gid that does not exist, and "no such download: ''"
// is a message that makes a user think the row they clicked is broken.
fn require_gid(command string, gid string) !string {
	if gid.trim_space() == '' {
		return error('${command}: gid is required')
	}
	if gid.len > 128 {
		return error('${command}: gid is ${gid.len} characters long')
	}
	return gid
}

// decode_gid is require_gid plus the size cap and the decode, in the order that
// gives the best message: too big first (nothing is parsed), then malformed
// JSON, then a missing gid.
fn decode_gid(command string, params string) !string {
	if params.len > control_params_bytes {
		return error('${command}: the request is ${params.len} bytes; the limit is ${control_params_bytes}')
	}
	if params.trim_space() == '' {
		return error('${command}: gid is required')
	}
	p := json2.decode[GidParams](params) or { return error('${command}: bad params: ' + err.msg()) }
	return require_gid(command, p.gid)
}

// ---- pause / resume -----------------------------------------------------

// pause_json is fluxget.pause.
//
// A notice is pushed for the same reason a row changes colour: the user pressed a
// button and needs to see that it took effect, and the next tick is up to a
// second away. The notice is not the confirmation - the engine's answer is - it is
// the feedback while the confirmation is in flight.
pub fn (mut app App) pause_json(params string) !string {
	gid := decode_gid('fluxget.pause', params) or { return err }
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.pause(gid) or { return error('fluxget.pause: ' + err.msg()) }
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		gid:  gid
		name: gid
		text: 'Paused ' + gid
	})
	return json2.encode(gid)
}

// resume_json is fluxget.resume.
//
// aria2's call is `unpause`, and the command is `resume`, because "resume" is what
// a user reads. aria2's name is noted here so nobody "fixes" it to match.
pub fn (mut app App) resume_json(params string) !string {
	gid := decode_gid('fluxget.resume', params) or { return err }
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.resume(gid) or { return error('fluxget.resume: ' + err.msg()) }
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		gid:  gid
		name: gid
		text: 'Resumed ' + gid
	})
	return json2.encode(gid)
}

// pause_all_json / resume_all_json are the two global switches.
//
// They take no params at all, and that is enforced rather than assumed: a payload
// on a command that ignores it is how "pause everything" ends up pausing the
// twelve rows a user had selected.
pub fn (mut app App) pause_all_json(params string) !string {
	if params.trim_space() != '' {
		return error('fluxget.pause_all: takes no params')
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.pause_all() or { return error('fluxget.pause_all: ' + err.msg()) }
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		text: 'Paused everything'
	})
	return json2.encode('ok')
}

pub fn (mut app App) resume_all_json(params string) !string {
	if params.trim_space() != '' {
		return error('fluxget.resume_all: takes no params')
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.resume_all() or { return error('fluxget.resume_all: ' + err.msg()) }
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		text: 'Resumed everything'
	})
	return json2.encode('ok')
}

// ---- remove -------------------------------------------------------------

// remove_json is fluxget.remove.
//
// Two aria2 calls behind one command, because the split is aria2's implementation
// detail and not a distinction a user has any reason to care about: remove takes
// the download off the queue, forgetting the record additionally stops it
// appearing in history.
pub fn (mut app App) remove_json(params string) !string {
	if params.len > control_params_bytes {
		return error('fluxget.remove: the request is ${params.len} bytes; the limit is ${control_params_bytes}')
	}
	// An empty payload cannot carry a gid, so it is refused by decode_gid's
	// sibling below rather than by decoding into an empty struct here.
	mut p := RemoveParams{}
	if params.trim_space() != '' {
		p = json2.decode[RemoveParams](params) or { return error('fluxget.remove: bad params: ' + err.msg()) }
	}
	gid := require_gid('fluxget.remove', p.gid) or { return err }
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.remove(gid) or { return error('fluxget.remove: ' + err.msg()) }
	if !p.keep_record {
		// A download that is still running cannot have its record discarded, and
		// aria2 says so. That is not a failure of remove - the download IS off the
		// queue now - so it is reported as a note and not as an error, or the UI
		// would show a failure for an action that worked.
		app.state.eng.forget(gid) or {
			app.state.notices.push(core.Notice{
				kind: core.notice_info
				gid:  gid
				name: gid
				text: 'Removed from the queue; its record is kept until it stops'
			})
			return json2.encode(gid)
		}
	}
	app.state.notices.push(core.Notice{
		kind: core.notice_removed
		gid:  gid
		name: gid
		text: 'Removed ' + gid
	})
	return json2.encode(gid)
}

// forget_all_json clears the finished-and-failed history.
//
// purge_results is a housekeeping command, so it is the one control command with
// no notice: there is nothing to say afterwards and a toast per invocation would
// be noise.
pub fn (mut app App) forget_all_json(params string) !string {
	if params.trim_space() != '' {
		return error('fluxget.forget_all: takes no params')
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	app.state.eng.client.purge_results() or { return error('fluxget.forget_all: ' + err.msg()) }
	return json2.encode('ok')
}

// ---- retry --------------------------------------------------------------

// retry_json is fluxget.retry.
//
// The answer is the NEW gid, and a frontend that kept the old one would send every
// later command for a download the engine has already forgotten - which fails with
// a confusing "No such download" long after the retry itself succeeded.
pub fn (mut app App) retry_json(params string) !string {
	gid := decode_gid('fluxget.retry', params) or { return err }
	app.state.lock()
	defer {
		app.state.unlock()
	}
	fresh := app.state.eng.retry(gid, app.state.remembered(gid)) or {
		return error('fluxget.retry: ' + err.msg())
	}
	app.state.notices.push(core.Notice{
		kind: core.notice_info
		gid:  fresh
		name: gid
		text: 'Retried ' + gid
	})
	return json2.encode(fresh)
}

// ---- move ---------------------------------------------------------------

// move_json is fluxget.move, and it takes a DELTA rather than a position.
//
// The frontend moves a row by one place with the arrow keys, so it knows "up one"
// and not "position 3". Taking the delta means the arithmetic that turns "up one"
// into an aria2 POS_CUR offset lives here, where it can be tested, instead of in
// browser JavaScript that no test can reach.
pub fn (mut app App) move_json(params string) !string {
	if params.len > control_params_bytes {
		return error('fluxget.move: the request is ${params.len} bytes; the limit is ${control_params_bytes}')
	}
	p := json2.decode[MoveParams](params) or { return error('fluxget.move: bad params: ' + err.msg()) }
	gid := require_gid('fluxget.move', p.gid) or { return err }
	if p.delta == 0 {
		// A zero delta is a no-op that still costs a round trip and a queue
		// reorder, and it is what a double-pressed arrow produces.
		return json2.encode(gid)
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	pos := app.state.eng.move(gid, p.delta, engine.pos_cur) or {
		return error('fluxget.move: ' + err.msg())
	}
	return json2.encode(pos)
}

// ---- per-item options ---------------------------------------------------

// set_item_options_json is fluxget.set_item_options.
//
// A whitelist is NOT applied, and the reason is worth stating because it looks
// like an oversight: aria2 decides which options may be changed after a download
// starts, and it answers with the ones it refused. Re-deriving that list here
// would be a second source of truth that drifts from the engine. What this layer
// does is refuse the two things that are never options - an empty key, and a
// gid-less request - and then let aria2 be the authority and REPORT what it
// refused.
pub fn (mut app App) set_item_options_json(params string) !string {
	if params.len > settings_params_bytes {
		return error('fluxget.set_item_options: the request is ${params.len} bytes; the limit is ${settings_params_bytes}')
	}
	p := json2.decode[ItemOptionsParams](params) or {
		return error('fluxget.set_item_options: bad params: ' + err.msg())
	}
	gid := require_gid('fluxget.set_item_options', p.gid) or { return err }
	if p.options.len == 0 {
		return error('fluxget.set_item_options: no options given')
	}
	for k, v in p.options {
		if k.trim_space() == '' {
			return error('fluxget.set_item_options: an option name is empty')
		}
		if v.len > 1024 {
			return error('fluxget.set_item_options: ${k} is ${v.len} characters long')
		}
	}
	app.state.lock()
	defer {
		app.state.unlock()
	}
	raw := app.state.eng.client.change_option(gid, p.options) or {
		return error('fluxget.set_item_options: ' + err.msg())
	}
	rejected := rpc.refused_options(raw)
	// aria2 answers with the options it could NOT set. Returning them lets the UI
	// say "aria2 would not accept max-connection-per-server here" instead of
	// rendering a field that looks saved and is not.
	if rejected.len > 0 {
		return json2.encode(rejected)
	}
	return json2.encode('ok')
}
