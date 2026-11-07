package replay

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"

Swap_Store :: struct {
	fd:     posix.FD,
	path:   string,
	ptr:    [^]u8,
	size:   int,
	tail:   int,
	index:  [^]u32,
	max_id: int,
}

init_swap :: proc(
	lib_path: string,
	max_id := 1_000_000,
	prealloc_bytes := 64 * 1024 * 1024,
) -> Swap_Store {
	base := len(lib_path) > 0 ? lib_path : ".test-data"
	path := fmt.aprintf("%s/swap.bin", base)
	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	fd := posix.open(c_path, {.RDWR, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if fd < 0 {fmt.panicf("swap: cannot create %s", path)}

	if posix.ftruncate(fd, posix.off_t(prealloc_bytes)) != .OK {
		posix.close(fd)
		os.remove(path)
		fmt.panicf("swap: cannot ftruncate %s", path)
	}

	m_ptr := posix.mmap(nil, uint(prealloc_bytes), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if m_ptr == posix.MAP_FAILED {
		posix.close(fd)
		os.remove(path)
		fmt.panicf("swap: cannot mmap %s", path)
	}

	index_bytes := (max_id + 1) * size_of(u32)
	return Swap_Store {
		fd = fd,
		path = path,
		ptr = ([^]u8)(m_ptr),
		size = prealloc_bytes,
		tail = index_bytes,
		index = ([^]u32)(m_ptr),
		max_id = max_id,
	}
}

destroy_swap :: proc(s: ^Swap_Store) {
	if s.ptr != nil {
		posix.munmap(s.ptr, uint(s.size))
		s.ptr = nil
	}
	if s.fd >= 0 {
		posix.close(s.fd)
		s.fd = -1
	}
	if len(s.path) > 0 {
		os.remove(s.path)
		delete(s.path)
		s.path = ""
	}
}

swap_write :: proc(s: ^Swap_Store, id: int, state: ^Patch_State) {
	if id < 0 ||
	   id > s.max_id {fmt.panicf("swap: id %d exceeds preallocated max %d", id, s.max_id)}
	rec_size := 8 + 8 + 2 + len(state.name) + 2 + len(state.comment) + 2 + len(state.tags)
	if s.tail + rec_size > s.size {
		fmt.panicf("swap: out of preallocated swap space (%d + %d > %d)", s.tail, rec_size, s.size)
	}
	off := s.tail
	dst := s.ptr[off:]
	pos := 0

	(^i64)(&dst[pos])^ = state.mtime
	pos += 8
	(^i64)(&dst[pos])^ = state.added_at
	pos += 8

	(^u16)(&dst[pos])^ = u16(len(state.name))
	pos += 2
	if len(state.name) > 0 {
		mem.copy(&dst[pos], raw_data(state.name), len(state.name))
		pos += len(state.name)
	}

	(^u16)(&dst[pos])^ = u16(len(state.comment))
	pos += 2
	if len(state.comment) > 0 {
		mem.copy(&dst[pos], raw_data(state.comment), len(state.comment))
		pos += len(state.comment)
	}

	(^u16)(&dst[pos])^ = u16(len(state.tags))
	pos += 2
	if len(state.tags) > 0 {
		mem.copy(&dst[pos], raw_data(state.tags), len(state.tags))
		pos += len(state.tags)
	}

	s.tail += pos
	s.index[id] = u32(off)
}

swap_read :: proc(s: ^Swap_Store, id: int, alloc: mem.Allocator) -> (state: Patch_State) {
	if id < 0 || id > s.max_id {return}
	off := int(s.index[id])
	if off == 0 {return}
	src := s.ptr[off:]
	pos := 0

	state.mtime = (^i64)(&src[pos])^
	pos += 8
	state.added_at = (^i64)(&src[pos])^
	pos += 8

	n_len := int((^u16)(&src[pos])^)
	pos += 2
	if n_len > 0 {
		state.name = make([dynamic]u8, n_len, alloc)
		mem.copy(raw_data(state.name), &src[pos], n_len)
		pos += n_len
	}

	c_len := int((^u16)(&src[pos])^)
	pos += 2
	if c_len > 0 {
		state.comment = strings.clone(string(src[pos:pos + c_len]), alloc)
		pos += c_len
	}

	t_len := int((^u16)(&src[pos])^)
	pos += 2
	if t_len > 0 {
		state.tags = make([dynamic]u8, t_len, alloc)
		mem.copy(raw_data(state.tags), &src[pos], t_len)
		pos += t_len
	}
	return
}

on_evict_to_swap :: proc(key: int, val: Patch_State, user_data: rawptr) {
	swap := cast(^Swap_Store)user_data
	val := val
	swap_write(swap, key, &val)
}
