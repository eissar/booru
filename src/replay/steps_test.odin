package replay

import "../library"
import "core:fmt"
import "core:slice"
import "core:testing"

// Replay order: patch properties are commutative, overwrite properties are associative,
// and associativity is a 3-element law. Assuming the lifting theorem, every 3-event
// sequence checked against the oracle covers logs of any length.

// lifecycle.fly: from Absent, every 3-op sequence; accepted steps follow accepts/next.
@(test)
lifecycle_step_all_triples :: proc(t: ^testing.T) {
	ops := [?]string{"add", "patch", "overwrite", "delete", "bogus"}
	for a in ops {for b in ops {for c in ops {
				s := Item_Status.Absent
				adds := 0
				for op in ([3]string{a, b, c}) {
					accepts :=
						(s == .Absent && op == "add") ||
						(s == .Live && (op == "patch" || op == "overwrite" || op == "delete"))
					next, ok := lifecycle_step(s, op)
					testing.expect_value(t, ok, accepts)
					if !ok {break} 	// replay rejects the log here
					want :=
						op == "add" ? Item_Status.Live : op == "delete" ? Item_Status.Deleted : s
					testing.expect_value(t, next, want)
					testing.expect(t, next != .Absent) // L5
					if op == "add" {adds += 1}
					s = next
				}
				testing.expect(t, adds <= 1) // L2, L5 -> at most one add
			}}}
}

// commutative.fly + property-op.fly: the zero delta is neutral and every triple folds to the
// oracle's raw state in all 6 orders. Finalization is not modeled.
@(test)
patch_fold_all_triples :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	defer free_all(alloc)
	alphabet := [?]Patch_Delta {
		{tag = -1}, // neutral
		{mtime = 3, tag = -1},
		{mtime = 5, tag = -1},
		{added_at = 3, tag = -1},
		{added_at = 5, mtime = 4, tag = -1},
		{name = {1}, tag = -1},
		{name = {0, 2}, tag = -1},
		{name = {3, 0, 4}, tag = -1},
		{tag = 0},
		{tag = 2},
		{mtime = 4, name = {2, 2}, tag = 0},
		{added_at = 1, name = {1}, tag = 1},
	}
	orders := [6][3]int{{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}}
	for a in alphabet {for b in alphabet {for c in alphabet {
				triple := [3]Patch_Delta{a, b, c}
				want: Patch_State
				for order, n in orders {
					state := Patch_State {
						name = make([dynamic]u8, alloc),
					}
					for i in order {state = patch_fold(state, triple[i], alloc)}
					// Neutral property: folding the zero delta changes nothing.
					zeroed := patch_fold(state, {tag = -1}, alloc)
					ok :=
						zeroed.mtime == state.mtime &&
						zeroed.added_at == state.added_at &&
						slice.equal(zeroed.name[:], state.name[:]) &&
						(state.tags.allocator.procedure == nil ? (cast(^[2]u64)&zeroed.tags)^ == (cast(^[2]u64)&state.tags)^ : slice.equal(zeroed.tags[:], state.tags[:]))
					if !ok {testing.fail_now(t, fmt.tprint("zero delta changes fold:", triple))}
					if n == 0 {
						// property-op.fly values: tmax, mem(txor), set(nxor).
						ok =
							state.mtime == max(a.mtime, b.mtime, c.mtime) &&
							state.added_at == max(a.added_at, b.added_at, c.added_at)
						for tag in 0 ..< 4 {
							word :=
								state.tags.allocator.procedure == nil ? (^u64)(&state.tags)^ : (len(state.tags) > 0 ? state.tags[0] : 0)
							mem := (word & (u64(1) << u64(tag))) != 0
							ok &&= mem == ((a.tag == tag) != (b.tag == tag) != (c.tag == tag))
						}
						for i in 0 ..< 4 {
							x: u8
							for d in triple {if i < len(d.name) {x ~= d.name[i]}}
							ok &&= (i < len(state.name) ? state.name[i] : 0) == x
						}
						if !ok {testing.fail_now(t, fmt.tprint("fold value differs from spec:", triple))}
						want = state
						continue
					}
					ok =
						state.mtime == want.mtime &&
						state.added_at == want.added_at &&
						slice.equal(state.name[:], want.name[:]) &&
						(state.tags.allocator.procedure == nil ? (cast(^[2]u64)&state.tags)^ == (cast(^[2]u64)&want.tags)^ : slice.equal(state.tags[:], want.tags[:]))
					if !ok {testing.fail_now(t, fmt.tprint("order changes fold:", triple, order))}
				}
			}}}
	free_all(alloc)
}

// Field-presence shapes for each log position, built once at startup: [position][mask].
overwrite_shapes: [3][64]library.Image

@(init)
init_overwrite_shapes :: proc "contextless" () {
	vals := [?]string{"", "x", "y", "z"}
	for &row, i in overwrite_shapes {
		v := i + 1
		for &o, mask in row {
			if mask & 1 != 0 {o.oid = vals[v]}
			if mask & 2 != 0 {o.path = vals[v]}
			if mask & 4 != 0 {o.ext = vals[v]}
			if mask & 8 != 0 {o.content_type = vals[v]}
			if mask & 16 != 0 {o.width = 10 + v}
			if mask & 32 != 0 {o.height = 10 + v}
		}
	}
}

// last_write.fly: over every triple of field-presence shapes, each field ends as the
// last present value (L1, L2) under either grouping (L6), a repeat changes nothing (L3),
// and disjoint shapes commute (L4).
@(test)
overwrite_step_all_triples :: proc(t: ^testing.T) {
	base := library.Image {
		oid          = "o",
		path         = "p",
		ext          = "e",
		content_type = "c",
		width        = 1,
		height       = 1,
	}
	for a in 0 ..< 64 {for b in 0 ..< 64 {for c in 0 ..< 64 {
				seq := [3]^library.Image {
					&overwrite_shapes[0][a],
					&overwrite_shapes[1][b],
					&overwrite_shapes[2][c],
				}
				got := base
				for o in seq {got = overwrite_step(got, o^)}
				left := overwrite_step(overwrite_step(seq[0]^, seq[1]^), seq[2]^)
				right := overwrite_step(seq[0]^, overwrite_step(seq[1]^, seq[2]^))
				want := base
				for o, i in seq {
					m := [3]int{a, b, c}[i]
					if m & 1 != 0 {want.oid = o.oid}
					if m & 2 != 0 {want.path = o.path}
					if m & 4 != 0 {want.ext = o.ext}
					if m & 8 != 0 {want.content_type = o.content_type}
					if m & 16 != 0 {want.width = o.width}
					if m & 32 != 0 {want.height = o.height}
				}
				// Base values differ from every shape value, so applying to base keeps presence visible.
				for grouped in ([3]library.Image{got, overwrite_step(base, left), overwrite_step(base, right)}) {
					ok :=
						grouped.oid == want.oid &&
						grouped.path == want.path &&
						grouped.ext == want.ext &&
						grouped.content_type == want.content_type &&
						grouped.width == want.width &&
						grouped.height == want.height
					if !ok {testing.fail_now(t, fmt.tprint("last write differs:", a, b, c))}
				}
				// L3: repeating the last overwrite changes nothing.
				again := overwrite_step(got, seq[2]^)
				ok :=
					again.oid == got.oid &&
					again.path == got.path &&
					again.ext == got.ext &&
					again.content_type == got.content_type &&
					again.width == got.width &&
					again.height == got.height
				if !ok {testing.fail_now(t, fmt.tprint("repeated overwrite changes state:", c))}
				// L4: disjoint shapes commute.
				if a & b == 0 {
					swapped := overwrite_step(overwrite_step(base, seq[1]^), seq[0]^)
					first := overwrite_step(overwrite_step(base, seq[0]^), seq[1]^)
					ok =
						swapped.oid == first.oid &&
						swapped.path == first.path &&
						swapped.ext == first.ext &&
						swapped.content_type == first.content_type &&
						swapped.width == first.width &&
						swapped.height == first.height
					if !ok {testing.fail_now(t, fmt.tprint("disjoint overwrites do not commute:", a, b))}
				}
			}}}
}
