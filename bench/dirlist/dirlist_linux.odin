#+build linux
// Native Linux counterpart of dirlist_windows.odin.
// Build: odin build bench/dirlist -o:speed -out:bin/dirlist
// Run:   bin/dirlist <dir> [files] [rounds]
package dirlist

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

check_name :: #force_inline proc(name: string, count: ^int) {
	if len(name) == 0 || name[0] == '.' {return}
	if strings.has_suffix(name, ".webp") {count^ += 1}
}

// A: core:os iterator.
m_core_os :: proc(dir: string) -> (n: int) {
	f, err := os.open(dir)
	if err != nil {return -1}
	defer os.close(f)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {check_name(fi.name, &n)}
	return
}

getdents_n :: proc(dir: string, $SIZE: int) -> (n: int) {
	fd, errno := linux.open(
		strings.clone_to_cstring(dir, context.temp_allocator),
		{.DIRECTORY, .CLOEXEC},
	)
	if errno != nil {return -1}
	defer linux.close(fd)
	buf: [SIZE]u8 = ---
	for {
		got, err := linux.getdents(fd, buf[:])
		if err != nil {return -1}
		if got == 0 {break}
		off := 0
		for e in linux.dirent_iterate_buf(buf[:got], &off) {check_name(linux.dirent_name(e), &n)}
	}
	return
}

// L1: linux.getdents, 32 KiB buffer (current filter_missing_thumbnails).
m_getdents_32k :: proc(dir: string) -> int {return getdents_n(dir, 32 * 1024)}
// L2: linux.getdents, 64 KiB buffer (same batch size as the Windows D/E methods).
m_getdents_64k :: proc(dir: string) -> int {return getdents_n(dir, 64 * 1024)}

// L3: libc opendir/readdir.
m_readdir :: proc(dir: string) -> (n: int) {
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil {return -1}
	defer posix.closedir(d)
	for e := posix.readdir(d); e != nil; e = posix.readdir(d) {
		check_name(string(cstring(raw_data(e.d_name[:]))), &n)
	}
	return
}

Method :: struct {
	name: string,
	fn:   proc(dir: string) -> int,
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: dirlist <dir> [files=20000] [rounds=5]")
		os.exit(2)
	}
	dir := args[1]
	files := len(args) > 2 ? strconv.parse_int(args[2]) or_else 20000 : 20000
	rounds := len(args) > 3 ? strconv.parse_int(args[3]) or_else 5 : 5

	os.make_directory_all(dir)
	if m_getdents_32k(dir) != files {
		fmt.printfln("populating %s with %d .webp files...", dir, files)
		for i in 0 ..< files {
			if f, err := os.create(fmt.tprintf("%s/%032x.webp", dir, i)); err == nil {os.close(f)}
			free_all(context.temp_allocator)
		}
		for i in 0 ..< 100 {
			if f, err := os.create(fmt.tprintf("%s/noise_%d.txt", dir, i));
			   err == nil {os.close(f)}
		}
	}

	methods := []Method {
		{"A core:os iterator", m_core_os},
		{"L1 getdents 32K (current)", m_getdents_32k},
		{"L2 getdents 64K", m_getdents_64k},
		{"L3 libc readdir", m_readdir},
	}

	fmt.printfln("dir=%s files=%d rounds=%d (median ms)", dir, files, rounds)
	for m in methods {
		times := make([]f64, rounds, context.temp_allocator)
		count := 0
		for r in 0 ..< rounds {
			t0 := time.tick_now()
			count = m.fn(dir)
			times[r] = time.duration_milliseconds(time.tick_since(t0))
		}
		for i in 1 ..< len(times) {
			for j := i;
			    j > 0 && times[j] < times[j - 1];
			    j -= 1 {times[j], times[j - 1] = times[j - 1], times[j]}
		}
		fmt.printfln(
			"  %-32s %9.3f ms  (min %8.3f)  found=%d",
			m.name,
			times[len(times) / 2],
			times[0],
			count,
		)
		free_all(context.temp_allocator)
	}
}
