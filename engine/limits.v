// limits.v - the three Limit layers from CONTEXT.md, in one file.
//
//   Global  -> aria2.changeGlobalOption, --max-overall-*
//   item    -> aria2.changeOption,       --max-download-limit / --max-upload-limit
//   schedule-> a rule that picks a Preset and applies it as a Global
//
// They are two different RPC methods with two different failure modes, and
// conflating them is how a download manager ends up where pausing one item
// slows down all of them. So there are two functions and no shared helper that
// could blur them.
//
// The absent/zero rule, once, for both:
//
//   an EMPTY STRING means "do not send this option at all"
//   a 0 means "unlimited"
//
// Those are different instructions to aria2 and V will not let us conflate them
// in one field. `0` is a real value (the caps are genuinely off), and `''` is
// the absence of an opinion. GlobalLimits.max_concurrent is the awkward one: 0
// means "leave the daemon's concurrency alone" rather than "unlimited",
// because aria2's --max-concurrent-downloads=0 is a valid value with a different
// meaning again. It is called out at its field.
module engine

import rpc

// GlobalLimits are the daemon-wide caps.
pub struct GlobalLimits {
pub mut:
	// download_limit and upload_limit are bytes per second. 0 is unlimited,
	// which is why the flag is omitted at 0 rather than sent: an absent
	// --max-overall-download-limit and an explicit 0 mean the same thing to
	// aria2, but only one of them survives a round trip through a struct field
	// that has to mean "unset" as well.
	download_limit int
	upload_limit   int
	// max_concurrent is how many downloads may run at once. 0 here means LEAVE
	// IT ALONE, not "unlimited" - see the module header. A Preset that only
	// names a speed must not silently reset the user's concurrency.
	max_concurrent int
}

// is_empty reports whether applying this would change nothing. The engine skips
// the round trip in that case, because a scheduler rule that fires every minute
// should not send aria2 an empty option map.
pub fn (l GlobalLimits) is_empty() bool {
	return l.download_limit == 0 && l.upload_limit == 0 && l.max_concurrent == 0
}

// options renders the global option map.
pub fn (l GlobalLimits) options() map[string]string {
	mut m := map[string]string{}
	if l.download_limit > 0 {
		m['max-overall-download-limit'] = l.download_limit.str()
	}
	if l.upload_limit > 0 {
		m['max-overall-upload-limit'] = l.upload_limit.str()
	}
	if l.max_concurrent > 0 {
		m['max-concurrent-downloads'] = l.max_concurrent.str()
	}
	return m
}

// set_global applies the Global layer. This is what the scheduler drives.
pub fn (mut e Engine) set_global(l GlobalLimits) !string {
	if l.is_empty() {
		return 'skipped: nothing to change'
	}
	return e.client.change_global_option(l.options())
}

// clear_global removes every cap, which is the "no schedule, no preset" state a
// user expects by turning the feature off.
//
// Sent explicitly rather than skipped: the caps were set by a previous call, and
// "set 0" is how you take them off. Writing 0 rather than removing the key is
// deliberate, and the difference matters - an absent option leaves aria2's
// current value alone.
pub fn (mut e Engine) clear_global() !string {
	return e.client.change_global_option({
		'max-overall-download-limit': '0'
		'max-overall-upload-limit':   '0'
	})
}

// ItemLimits are the per-download caps.
pub struct ItemLimits {
pub mut:
	// download_limit and upload_limit are bytes per second; 0 is unlimited.
	download_limit int
	upload_limit   int
	// seed_ratio is aria2's ratio cap ("1.0") and seed_time its wall-clock cap
	// in minutes. Both are strings because aria2 accepts fractional ratios and
	// the caller may want to pass one through verbatim.
	//
	// Empty means "do not touch", which is what makes a Preset able to set a
	// speed without clearing a torrent's seeding policy. A schedule that only
	// knows about bandwidth must not reset how long someone seeds.
	seed_ratio string
	seed_time  string
}

// is_empty reports whether there is anything to send.
pub fn (l ItemLimits) is_empty() bool {
	return l.download_limit == 0 && l.upload_limit == 0 && l.seed_ratio == ''
		&& l.seed_time == ''
}

// options renders the per-download option map.
pub fn (l ItemLimits) options() map[string]string {
	mut m := map[string]string{}
	if l.download_limit > 0 {
		m['max-download-limit'] = l.download_limit.str()
	}
	if l.upload_limit > 0 {
		m['max-upload-limit'] = l.upload_limit.str()
	}
	if l.seed_ratio != '' {
		m['seed-ratio'] = l.seed_ratio
	}
	if l.seed_time != '' {
		m['seed-time'] = l.seed_time
	}
	return m
}

// set_item applies the item layer to one GID.
pub fn (mut e Engine) set_item(gid string, l ItemLimits) !string {
	if l.is_empty() {
		return 'skipped: nothing to change'
	}
	return e.client.change_option(gid, l.options())
}

// bytes_per_second renders a human-facing rate for the UI, e.g. "1.4 MiB/s".
//
// Pure and here rather than in the frontend because the frontend has no business
// inventing units: aria2 reports bytes per second, and every place that shows a
// rate has to round the same way or two panels will disagree.
pub fn rate_text(bytes_per_second i64) string {
	if bytes_per_second <= 0 {
		return '0 B/s'
	}
	if bytes_per_second < 1024 {
		return bytes_per_second.str() + ' B/s'
	}
	mut v := f64(bytes_per_second) / 1024.0
	mut unit := 'KiB/s'
	if v >= 1024.0 {
		v /= 1024.0
		unit = 'MiB/s'
	}
	if v >= 1024.0 {
		v /= 1024.0
		unit = 'GiB/s'
	}
	// One decimal below 10, none above: "9.4 MiB/s" is informative and
	// "128 GiB/s" is noise.
	if v < 10.0 {
		return fixed1(v) + ' ' + unit
	}
	return fixed0(v) + ' ' + unit
}

// fixed1 renders a non-negative value with exactly one digit after the point.
//
// Hand-rolled because V 0.5.2 has no float format specifier: `${v:0.1f}` is
// rejected ("this number has unsuitable digit `f`"), there is no
// str_float_precision, and strconv.ftoa_64 is scientific ("1.5e+02"), which is
// not something to put in a download row.
//
// Scaling to an integer and rounding there is exact at these magnitudes (a rate
// or a file size, far below 2^53 tenths) and needs no library call.
fn fixed1(v f64) string {
	t := int((v * 10.0) + 0.5)
	return '${t / 10}.${t % 10}'
}

// fixed0 is fixed1 with no fractional part.
fn fixed0(v f64) string {
	t := int((v * 10.0) + 0.5)
	return '${t / 10}'
}

// size_text renders a byte count the same way, e.g. "1.4 GiB".
pub fn size_text(bytes i64) string {
	if bytes <= 0 {
		return '0 B'
	}
	if bytes < 1024 {
		return bytes.str() + ' B'
	}
	mut v := f64(bytes) / 1024.0
	mut unit := 'KiB'
	if v >= 1024.0 {
		v /= 1024.0
		unit = 'MiB'
	}
	if v >= 1024.0 {
		v /= 1024.0
		unit = 'GiB'
	}
	if v >= 1024.0 {
		v /= 1024.0
		unit = 'TiB'
	}
	if v < 10.0 {
		return fixed1(v) + ' ' + unit
	}
	return fixed0(v) + ' ' + unit
}

// eta_text renders a remaining time, and says "unknown" rather than a wrong
// number. aria2 reports -1 when it cannot know (no rate yet, or a torrent that
// may never finish), and a download manager that shows a countdown derived from
// a guess is lying.
pub fn eta_text(seconds i64) string {
	if seconds < 0 {
		return 'unknown'
	}
	if seconds < 60 {
		return seconds.str() + 's'
	}
	if seconds < 3600 {
		return (seconds / 60).str() + 'm ' + (seconds % 60).str() + 's'
	}
	return (seconds / 3600).str() + 'h ' + ((seconds % 3600) / 60).str() + 'm'
}

// options_of is a small reader for a decoded aria2 option bag, used by the
// setup page to show the engine's current caps.
pub fn option_of(opts rpc.Options, key string) string {
	return opts[key] or { '' }
}
