package server

import "core:math/bits"
import "core:sync"

Bitlist :: bit_set[0 ..< 64;u64]

acquire :: proc(b: ^Bitlist) -> (idx: int, ok: bool) {
	raw := transmute(u64)sync.atomic_load(b)
	if raw == 0 {
		return 0, false
	}
	idx = int(bits.count_trailing_zeros(raw))
	sync.atomic_sub(b, Bitlist{idx})
	return idx, true
}

release :: proc(b: ^Bitlist, idx: int) {
	sync.atomic_add(b, Bitlist{idx})
}
