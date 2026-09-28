// limits_test.v - the three Limit layers, and the absent/zero distinction.
//
// The thing being protected here is a distinction that is easy to lose and
// impossible to see once lost:
//
//   '' means "do not send this option"
//   0  means "unlimited"
//
// A scheduler that sets a Preset every minute must be able to set a speed
// without clearing somebody's seed policy, and a speed cap of "off" must be
// expressible. Get this wrong and the symptom is a torrent that silently stops
// seeding, or a cap that a user cannot switch off.
module engine

import rpc

fn test_global_limits_render_only_what_was_set() {
	mut m := GlobalLimits{}.options()
	assert m.len == 0, 'an empty GlobalLimits must send nothing: ${m}'

	m = GlobalLimits{
		download_limit: 1048576
		upload_limit:   262144
		max_concurrent: 3
	}.options()
	assert m['max-overall-download-limit']! == '1048576'
	assert m['max-overall-upload-limit']! == '262144'
	assert m['max-concurrent-downloads']! == '3'
}

fn test_zero_concurrency_means_leave_it_alone_not_unlimited() {
	// The one genuinely confusing field. aria2 accepts
	// --max-concurrent-downloads=0 as a real value, so "0 means unlimited"
	// would be a second interpretation of the same number in the same file.
	m := GlobalLimits{
		download_limit: 1024
		max_concurrent: 0
	}.options()
	assert 'max-concurrent-downloads' !in m, 'a Preset that only names a speed must not reset concurrency: ${m}'
}

fn test_an_empty_set_of_global_limits_makes_no_round_trip() {
	// A scheduler rule firing every minute should not send aria2 an empty map.
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	r := e.set_global(GlobalLimits{}) or {
		assert false, err.msg()
		return
	}
	assert r.contains('skipped'), r
	assert f.requests.len == 0, 'and nothing should reach aria2: ${f.requests}'
}

fn test_the_global_layer_uses_change_global_option_and_takes_no_gid() {
	// The distinction that keeps "pause one item" from "slow down everything".
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	e.set_global(GlobalLimits{
		download_limit: 524288
	}) or {
		assert false, err.msg()
		return
	}
	assert f.method_of(0) == 'aria2.changeGlobalOption'
	assert f.params_of(0).contains('max-overall-download-limit'), f.params_of(0)
	assert !f.params_of(0).contains('aa01'), 'the global layer has no gid'
}

fn test_clearing_the_caps_sends_zero_rather_than_removing_the_key() {
	// An absent option leaves aria2's current value alone; 0 is how you take a
	// cap off. "Turn the feature off" has to be an explicit instruction.
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	e.clear_global() or {
		assert false, err.msg()
		return
	}
	p := f.params_of(0)
	assert p.contains('"max-overall-download-limit":"0"'), p
	assert p.contains('"max-overall-upload-limit":"0"'), p
}

fn test_the_item_layer_uses_change_option_and_carries_the_gid() {
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	e.set_item('aa01', ItemLimits{
		download_limit: 131072
		upload_limit:   65536
	}) or {
		assert false, err.msg()
		return
	}
	assert f.method_of(0) == 'aria2.changeOption'
	p := f.params_of(0)
	assert p.contains('aa01'), p
	assert p.contains('"max-download-limit":"131072"'), p
	assert p.contains('"max-upload-limit":"65536"'), p
	// NOT the global names. Sending max-overall-* to changeOption would either
	// be rejected or, worse, be accepted as a global change.
	assert !p.contains('max-overall'), 'the item layer must not send the global options: ${p}'
}

fn test_the_two_layers_never_share_an_option_name() {
	// Asserted directly, because the failure is silent: aria2 answers "OK" to
	// options it does not recognise in some versions.
	mut g := GlobalLimits{
		download_limit: 1
		upload_limit:   1
	}.options()
	mut i := ItemLimits{
		download_limit: 1
		upload_limit:   1
	}.options()
	for k in g.keys() {
		assert k !in i, '${k} is in both layers'
	}
}

fn test_an_empty_seed_policy_means_do_not_touch_it() {
	// A schedule that only knows about bandwidth must not reset how long
	// somebody has been seeding. This is the exact bug the '' rule prevents.
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	e.set_item('aa01', ItemLimits{
		download_limit: 1024
	}) or {
		assert false, err.msg()
		return
	}
	p := f.params_of(0)
	assert !p.contains('seed-ratio'), 'an unset seed policy must be absent: ${p}'
	assert !p.contains('seed-time'), p
}

fn test_a_seed_policy_is_passed_through_verbatim() {
	// aria2 accepts fractional ratios ("1.5") and the caller may want exactly
	// that, so this is a string and not a float that gets reformatted.
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	e.set_item('aa01', ItemLimits{
		seed_ratio: '1.5'
		seed_time:  '120'
	}) or {
		assert false, err.msg()
		return
	}
	p := f.params_of(0)
	assert p.contains('"seed-ratio":"1.5"'), p
	assert p.contains('"seed-time":"120"'), p
}

fn test_an_empty_set_of_item_limits_makes_no_round_trip() {
	f := rpc.new_fake([rpc.ok('"OK"')])
	mut e := new(f.client('tok'))
	r := e.set_item('aa01', ItemLimits{}) or {
		assert false, err.msg()
		return
	}
	assert r.contains('skipped'), r
	assert f.requests.len == 0
}

fn test_rates_are_rendered_the_same_way_everywhere() {
	// Pure and here rather than in the frontend: two panels that round
	// differently is the kind of disagreement nobody reports until a screenshot.
	assert rate_text(0) == '0 B/s'
	assert rate_text(512) == '512 B/s'
	assert rate_text(1024) == '1.0 KiB/s'
	assert rate_text(1536) == '1.5 KiB/s'
	assert rate_text(10 * 1024) == '10 KiB/s'
	assert rate_text(1024 * 1024) == '1.0 MiB/s'
	assert rate_text(150 * 1024 * 1024) == '150 MiB/s'
	// A rate the engine reports as 0 is "stopped", not a rounding question.
	assert rate_text(-1) == '0 B/s'
}

// gib is a gibibyte. Written as a function because `2 * 1024 * 1024 * 1024` is
// an untyped constant expression that V evaluates in i32 and overflows - and the
// 0.5.2 numeric literal suffixes that would fix it (`2147483648i64`) do not
// exist either.
fn gib(n int) i64 {
	return i64(n) * 1024 * 1024 * 1024
}

fn test_sizes_are_rendered_the_same_way_everywhere() {
	assert size_text(0) == '0 B'
	assert size_text(1023) == '1023 B'
	assert size_text(1024) == '1.0 KiB'
	assert size_text(1024 * 1024) == '1.0 MiB'
	assert size_text(gib(2)) == '2.0 GiB'
	assert size_text(gib(3) * 1024) == '3.0 TiB'
	assert size_text(-5) == '0 B', 'an unknown length is 0 B, not a negative one'
}

fn test_an_unknown_eta_says_unknown_rather_than_guessing() {
	// aria2 reports -1 when it cannot know: no rate yet, or a torrent that may
	// never finish. A countdown derived from a guess is a lie with a number on
	// it, which is worse than the word.
	assert eta_text(-1) == 'unknown'
	assert eta_text(0) == '0s'
	assert eta_text(45) == '45s'
	assert eta_text(90) == '1m 30s'
	assert eta_text(3661) == '1h 1m'
}
