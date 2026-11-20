package progress

import "core:testing"

@(test)
is_active_tracks_phase_lifecycle :: proc(t: ^testing.T) {
	phase :: "test.is_active"
	testing.expect(t, !is_active(phase), "unregistered phase is not active")

	update(phase, 0)
	testing.expect(t, is_active(phase), "updated phase is active")

	finish(phase)
	testing.expect(t, !is_active(phase), "finished phase is not active")
}
