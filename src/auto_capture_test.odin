package cliche

import "core:sync"
import "core:testing"
import "core:time"

// What the auto capture posted, as the app's inbox would hold it: a tick counts only while its run is the current one
// (app_auto_tick's rule).
@(private = "file")
Posted :: struct {
	mutex: sync.Mutex,
	cond:  sync.Cond,
	owner: ^Auto_Capture,
	verbs: [dynamic]Verb,
	gens:  [dynamic]u64,
}

@(private = "file")
posted_add :: proc(user: rawptr, verb: Verb, generation: u64) {
	p := (^Posted)(user)
	if !auto_capture_current(p.owner, generation) { return }
	sync.mutex_lock(&p.mutex)
	append(&p.verbs, verb)
	append(&p.gens, generation)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mutex)
}

// Waits until `n` ticks came, `bound` at most. False: they did not come in time.
@(private = "file")
posted_wait :: proc(p: ^Posted, n: int, bound: time.Duration) -> bool {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	deadline := time.tick_add(time.tick_now(), bound)
	for len(p.verbs) < n {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 { return false }
		sync.cond_wait_with_timeout(&p.cond, &p.mutex, left)
	}
	return true
}

@(private = "file")
posted_count :: proc(p: ^Posted) -> int {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	return len(p.verbs)
}

@(private = "file")
posted_destroy :: proc(p: ^Posted) {
	delete(p.verbs)
	delete(p.gens)
}

// Each tick posts the capture's command with its run's generation.
@(test)
auto_capture_posts_its_capture :: proc(t: ^testing.T) {
	a: Auto_Capture
	p := Posted{owner = &a}
	defer posted_destroy(&p)
	testing.expect(t, auto_capture_start(&a, .Window, 5 * time.Millisecond, posted_add, &p))
	testing.expect(t, auto_capture_running(&a))
	gen := sync.atomic_load(&a.generation)
	testing.expect(t, posted_wait(&p, 2, 10 * time.Second), "two ticks came")
	auto_capture_stop(&a)
	testing.expect(t, !auto_capture_running(&a))
	sync.mutex_lock(&p.mutex)
	for v, i in p.verbs { testing.expect(t, v == .Window && p.gens[i] == gen) }
	sync.mutex_unlock(&p.mutex)
	for s in AUTO_CAPTURE_SOURCES {
		c, ok := command_parse(verb_message(auto_capture_verb(s)))
		testing.expectf(t, ok && TRIGGER_SOURCE[trigger_of_verb(c.verb)] == s, "%v: its command captures it", s)
	}
}

// After a stop no tick reaches the app: the stop returns without waiting for the thread, the run's generation stops
// counting (a tick of it queued before the stop is dropped too), and nothing comes in a bounded wait. A start again is a
// new run, with a new generation, that ticks.
@(test)
auto_capture_stops_without_waiting :: proc(t: ^testing.T) {
	a: Auto_Capture
	p := Posted{owner = &a}
	defer posted_destroy(&p)
	testing.expect(t, auto_capture_start(&a, .Screen, 5 * time.Millisecond, posted_add, &p))
	old := sync.atomic_load(&a.generation)
	testing.expect(t, posted_wait(&p, 1, 10 * time.Second), "it ticks")
	auto_capture_stop(&a)
	testing.expect(t, !auto_capture_running(&a))
	testing.expect(t, !auto_capture_current(&a, old), "the stopped run's ticks do not count")
	n := posted_count(&p)
	testing.expect(t, !posted_wait(&p, n + 1, 200 * time.Millisecond), "no tick after the stop")
	posted_add(&p, .Screen, old)   // (a tick of the stopped run, late)
	testing.expect_value(t, posted_count(&p), n)
	auto_capture_stop(&a)   // (none runs: nothing)

	testing.expect(t, auto_capture_start(&a, .Screen, 5 * time.Millisecond, posted_add, &p))
	now := sync.atomic_load(&a.generation)
	testing.expect(t, now != old && auto_capture_current(&a, now) && !auto_capture_current(&a, old))
	testing.expect(t, posted_wait(&p, n + 1, 10 * time.Second), "it ticks again once started again")
	// (a restart while running: the new run counts, the old one ends by itself)
	testing.expect(t, auto_capture_start(&a, .Window, 5 * time.Millisecond, posted_add, &p))
	testing.expect(t, !auto_capture_current(&a, now))
	m := posted_count(&p)
	testing.expect(t, posted_wait(&p, m + 1, 10 * time.Second), "the new run ticks")
	auto_capture_stop(&a)
	sync.mutex_lock(&p.mutex)
	testing.expect_value(t, p.verbs[len(p.verbs) - 1], Verb.Window)
	sync.mutex_unlock(&p.mutex)
}

// The trigger whose capture a verb runs (the verbs the auto capture posts).
@(private = "file")
trigger_of_verb :: proc(v: Verb) -> Trigger {
	#partial switch v {
	case .Window:      return .Window
	case .All_Screens: return .All_Screens
	case .Last_Region: return .Last_Region
	}
	return .Screen
}
