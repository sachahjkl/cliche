package cliche

import "core:testing"
import "core:time"

@(private = "file")
step :: proc(t: ^testing.T, r: Record_Flow, e: Record_Event, want: Record_Flow, loc := #caller_location) -> Record_Flow {
	next, ok := record_step(r, e)
	testing.expect(t, ok, "the transition is refused", loc = loc)
	testing.expect_value(t, next, want, loc = loc)
	return next
}

@(test)
record_goes_from_choosing_to_done :: proc(t: ^testing.T) {
	r: Record_Flow = Record_Idle{}
	r = step(t, r, Record_Trigger{.Mp4}, Record_Choosing{.Mp4})
	// (the region chosen: nothing records until the Record button)
	r = step(t, r, Record_Chosen{}, Record_Ready{.Mp4})
	r = step(t, r, Record_Format_Set{.Gif}, Record_Ready{.Gif})
	r = step(t, r, Record_Start{}, Record_Starting{.Gif})
	r = step(t, r, Record_Started{}, Record_Recording{.Gif, 0})
	r = step(t, r, Record_Progress{1500}, Record_Recording{.Gif, 1500})
	r = step(t, r, Record_Stop{}, Record_Stopping{.Gif})
	r = step(t, r, Record_Finished{}, Record_Done{.Gif})
	r = step(t, r, Record_Reset{}, Record_Idle{})
}

@(test)
record_the_same_keys_walk_the_flow :: proc(t: ^testing.T) {
	// the shortcut chooses the region, then starts, then stops
	r: Record_Flow = Record_Idle{}
	r = step(t, r, Record_Trigger{.Mp4}, Record_Choosing{.Mp4})
	r = step(t, r, Record_Chosen{}, Record_Ready{.Mp4})
	r = step(t, r, Record_Trigger{.Mp4}, Record_Starting{.Mp4})
	r = step(t, r, Record_Started{}, Record_Recording{.Mp4, 0})
	r = step(t, r, Record_Trigger{.Mp4}, Record_Stopping{.Mp4})
}

@(test)
record_cancels :: proc(t: ^testing.T) {
	// before it starts: nothing to delete
	step(t, Record_Ready{.Mp4}, Record_Cancelled{}, Record_Idle{})
	step(t, Record_Choosing{.Gif}, Record_Cancelled{}, Record_Idle{})
	// while it records: the file goes, nothing is told, whatever the recorder says at its end
	r := step(t, Record_Recording{.Mp4, 4000}, Record_Discard{}, Record_Discarding{.Mp4})
	step(t, r, Record_Finished{}, Record_Idle{})
	step(t, r, Record_Fail{.Not_Saved}, Record_Idle{})
	step(t, Record_Starting{.Gif}, Record_Discard{}, Record_Discarding{.Gif})
}

@(test)
record_ends_by_itself_at_its_length :: proc(t: ^testing.T) {
	r: Record_Flow = Record_Recording{.Gif, 9000}
	r = step(t, r, Record_Finished{}, Record_Done{.Gif})
	r = step(t, r, Record_Trigger{.Gif}, Record_Choosing{.Gif})
	r = step(t, r, Record_Cancelled{}, Record_Idle{})
}

@(test)
record_failures_end_the_flow :: proc(t: ^testing.T) {
	step(t, Record_Starting{.Mp4}, Record_Fail{.No_Encoder}, Record_Failed{.Mp4, .No_Encoder})
	step(t, Record_Recording{.Mp4, 10}, Record_Fail{.Encoder}, Record_Failed{.Mp4, .Encoder})
	step(t, Record_Stopping{.Gif}, Record_Fail{.Not_Saved}, Record_Failed{.Gif, .Not_Saved})
	step(t, Record_Ready{.Mp4}, Record_Fail{.Failed}, Record_Failed{.Mp4, .Failed})
	// (a stop before the first frame)
	step(t, Record_Starting{.Gif}, Record_Stop{}, Record_Stopping{.Gif})
}

@(test)
record_refuses_what_means_nothing :: proc(t: ^testing.T) {
	cases := []struct { r: Record_Flow, e: Record_Event }{
		{Record_Idle{}, Record_Stop{}},
		{Record_Idle{}, Record_Reset{}},
		{Record_Idle{}, Record_Started{}},
		{Record_Idle{}, Record_Start{}},
		{Record_Choosing{.Mp4}, Record_Trigger{.Gif}},   // (the region's overlay is up: Escape cancels)
		{Record_Choosing{.Mp4}, Record_Start{}},
		{Record_Ready{.Mp4}, Record_Stop{}},
		{Record_Ready{.Mp4}, Record_Discard{}},
		{Record_Recording{.Mp4, 0}, Record_Format_Set{.Gif}},
		{Record_Stopping{.Mp4}, Record_Trigger{.Mp4}},
		{Record_Stopping{.Mp4}, Record_Discard{}},
		{Record_Discarding{.Mp4}, Record_Stop{}},
		{Record_Done{.Mp4}, Record_Progress{5}},
	}
	for c in cases {
		next, ok := record_step(c.r, c.e)
		testing.expectf(t, !ok, "%v then %v", c.r, c.e)
		testing.expect_value(t, next, c.r)
	}
	// a late progress never takes the time back
	next, _ := record_step(Record_Recording{.Mp4, 3000}, Record_Progress{2000})
	testing.expect_value(t, next, Record_Flow(Record_Recording{.Mp4, 3000}))
}

@(test)
record_busy_and_running :: proc(t: ^testing.T) {
	testing.expect(t, !record_busy(Record_Idle{}))
	testing.expect(t, record_busy(Record_Choosing{.Mp4}))
	testing.expect(t, record_busy(Record_Ready{.Mp4}))
	testing.expect(t, !record_running(Record_Choosing{.Mp4}))
	testing.expect(t, !record_running(Record_Ready{.Mp4}))
	testing.expect(t, record_running(Record_Recording{.Gif, 0}))
	testing.expect(t, record_running(Record_Discarding{.Gif}))
	testing.expect(t, !record_busy(Record_Failed{.Gif, .Gone}))
	testing.expect_value(t, record_format(Record_Ready{.Gif}), Record_Format.Gif)
}

@(test)
record_bar_goes_outside_the_region :: proc(t: ^testing.T) {
	win := [2]f32{1000, 800}
	bar := [2]f32{300, 40}
	// below, centred on the region
	testing.expect_value(t, record_bar_place({100, 100, 400, 300}, win, bar, 10), [2]f32{150, 410})
	// no room below: above
	testing.expect_value(t, record_bar_place({100, 500, 400, 280}, win, bar, 10), [2]f32{150, 450})
	// the whole output: inside its bottom edge
	testing.expect_value(t, record_bar_place({0, 0, 1000, 800}, win, bar, 10), [2]f32{350, 750})
	// near a side: kept in the window
	testing.expect_value(t, record_bar_place({900, 100, 100, 100}, win, bar, 10), [2]f32{700, 210})
}

@(test)
gif_size_scales_down_wide_frames :: proc(t: ^testing.T) {
	w, h := gif_size(1920, 1080, 960)
	testing.expect_value(t, w, 960)
	testing.expect_value(t, h, 540)
	w, h = gif_size(800, 600, 960)
	testing.expect_value(t, w, 800)
	testing.expect_value(t, h, 600)
	w, h = gif_size(5000, 1, 100)
	testing.expect_value(t, h, 1)
	w, h = gif_size(1920, 1080, 0)
	testing.expect_value(t, w, 1920)
}

@(test)
scale_down_averages :: proc(t: ^testing.T) {
	// 2 x 2 to 1 x 1: the mean of the four
	src := []u8{0, 0, 0, 255, 100, 0, 0, 255, 0, 200, 0, 255, 100, 200, 40, 255}
	dst: [4]u8
	scale_down(dst[:], 1, 1, src, 2, 2, 8)
	testing.expect_value(t, dst, [4]u8{50, 100, 10, 255})
	// 3 x 1 to 2 x 1: every pixel of the source counts once
	src3 := []u8{10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 0}
	dst2: [8]u8
	scale_down(dst2[:], 2, 1, src3, 3, 1, 12)
	testing.expect_value(t, dst2[0], u8(10))
	testing.expect_value(t, dst2[4], u8(25))
}

@(test)
copy_fit_cuts_and_pads :: proc(t: ^testing.T) {
	// 1 x 2 into 2 x 1: the first row, its first pixel, then black
	src := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	dst := [8]u8{9, 9, 9, 9, 9, 9, 9, 9}
	copy_fit(dst[:], 2, 1, src, 1, 2, 4)
	testing.expect_value(t, dst, [8]u8{1, 2, 3, 4, 0, 0, 0, 0})
}

@(test)
gif_delays_add_up :: proc(t: ^testing.T) {
	// frames at an irregular pace: the delays always add up to the time of the last one
	times := []i64{0, 83_000_000, 166_000_000, 251_000_000, 1_000_000_000}
	sum := 0
	for i in 1 ..< len(times) { sum += gif_delay_cs(times[i - 1], times[i]) }
	testing.expect_value(t, sum, 100)
	testing.expect_value(t, gif_delay_cs(0, 1_000_000), 2)   // (never under 2)
}

@(test)
packet_durations :: proc(t: ^testing.T) {
	testing.expect_value(t, packet_duration(0, i64(500 * time.Millisecond), 30), 0.5)
	testing.expect_value(t, packet_duration(10, 10, 25), 0.04)
	testing.expect_value(t, packet_duration(20, 10, 0), 1.0)
}

@(test)
record_names_take_the_format :: proc(t: ^testing.T) {
	stamp := Stamp{year = 2026, month = 11, day = 12, hour = 9, minute = 5, second = 7}
	testing.expect_value(t, record_name(DEFAULT_NAME_PATTERN, stamp, .Region, .Mp4, context.temp_allocator), "cliche-20261112-090507.mp4")
	testing.expect_value(t, record_name("%s %Y", stamp, .Screen, .Gif, context.temp_allocator), "screen 2026.gif")
}

@(test)
record_texts :: proc(t: ^testing.T) {
	testing.expect_value(t, record_elapsed_text(7_400), "0:07")
	testing.expect_value(t, record_elapsed_text(754_000), "12:34")
	testing.expect_value(t, record_elapsed_text(3_723_000), "1:02:03")
	testing.expect_value(t, record_clock_text(83_400), "01:23")
	testing.expect_value(t, record_clock_text(3_723_000), "1:02:03")
	testing.expect_value(t, size_text(340_000), "340 KB")
	testing.expect_value(t, size_text(12_500_000), "12.5 MB")
	testing.expect_value(t, record_notice_body("/p/a.mp4", 2_000_000, 65_000), "/p/a.mp4\n2.0 MB, 1:05")
}
