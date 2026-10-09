package util

import "core:mem"

bytes_equal :: proc "contextless" (a, b: []byte) -> bool {
	return mem.compare(a, b) == 0
}
