#+build windows
// Benchmark directory-listing strategies on Windows (getdents replacements).
// Build: odin build bench/dirlist -target:windows_amd64 -windows-sdk-root:$HOME/.xwin -o:speed -out:bin/win/dirlist.exe
// Run:   wine bin/win/dirlist.exe <dir> [files] [rounds]
package dirlist

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:time"

foreign import kernel32 "system:Kernel32.lib"
foreign import ntdll "system:Ntdll.lib"

FINDEX_INFO_LEVELS :: enum i32 {
	Standard = 0,
	Basic    = 1,
}
FINDEX_SEARCH_OPS :: enum i32 {
	NameMatch = 0,
}
FIND_FIRST_EX_LARGE_FETCH :: 0x2

@(default_calling_convention = "system")
foreign kernel32 {
	FindFirstFileExW :: proc(name: win.LPCWSTR, level: FINDEX_INFO_LEVELS, data: rawptr, op: FINDEX_SEARCH_OPS, filter: rawptr, flags: win.DWORD) -> win.HANDLE ---
}

@(default_calling_convention = "system")
foreign ntdll {
	NtQueryDirectoryFile :: proc(h: win.HANDLE, event: win.HANDLE, apc: rawptr, apc_ctx: rawptr, iosb: ^win.IO_STATUS_BLOCK, info: rawptr, length: win.ULONG, class: win.FILE_INFORMATION_CLASS, single: win.BOOLEAN, name: rawptr, restart: win.BOOLEAN) -> win.NTSTATUS ---
}

// FILE_FULL_DIR_INFO (GetFileInformationByHandleEx) layout.
FILE_FULL_DIR_INFO :: struct {
	NextEntryOffset: u32,
	FileIndex:       u32,
	CreationTime:    i64,
	LastAccessTime:  i64,
	LastWriteTime:   i64,
	ChangeTime:      i64,
	EndOfFile:       i64,
	AllocationSize:  i64,
	FileAttributes:  u32,
	FileNameLength:  u32,
	EaSize:          u32,
	FileName:        [1]u16,
}

// FILE_NAMES_INFORMATION (NtQueryDirectoryFile class 12) layout.
FILE_NAMES_INFORMATION :: struct {
	NextEntryOffset: u32,
	FileIndex:       u32,
	FileNameLength:  u32,
	FileName:        [1]u16,
}

STATUS_NO_MORE_FILES :: win.NTSTATUS(-2147483642) // 0x80000006

// Same work as filter_missing_thumbnails: count names ending in ".webp", skip dot-files.
check_name :: #force_inline proc(name: []u16, count: ^int) {
	if len(name) == 0 || name[0] == '.' {return}
	suffix := [5]u16{'.', 'w', 'e', 'b', 'p'}
	if len(name) < 5 {return}
	tail := name[len(name) - 5:]
	for c, i in suffix {if tail[i] != c {return}}
	count^ += 1
}

cstr_len :: proc(p: []u16) -> int {
	for c, i in p {if c == 0 {return i}}
	return len(p)
}

search_pattern :: proc(dir: string) -> win.LPCWSTR {
	return win.utf8_to_wstring(strings.concatenate({dir, "\\*"}, context.temp_allocator))
}

open_dir :: proc(dir: string) -> win.HANDLE {
	return win.CreateFileW(
		win.utf8_to_wstring(dir),
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
}

// A: core:os iterator (opens every entry for metadata).
m_core_os :: proc(dir: string) -> (n: int) {
	f, err := os.open(dir)
	if err != nil {return -1}
	defer os.close(f)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for fi in os.read_directory_iterator(&it) {
		if len(fi.name) > 0 && fi.name[0] != '.' && strings.has_suffix(fi.name, ".webp") {n += 1}
	}
	return
}

// B: FindFirstFileW / FindNextFileW.
m_find_first :: proc(dir: string) -> (n: int) {
	data: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(search_pattern(dir), &data)
	if h == win.INVALID_HANDLE_VALUE {return -1}
	defer win.FindClose(h)
	for {
		check_name(data.cFileName[:cstr_len(data.cFileName[:])], &n)
		if !win.FindNextFileW(h, &data) {break}
	}
	return
}

// C: FindFirstFileExW(Basic, LARGE_FETCH): no 8.3 short names, bigger kernel batches.
m_find_ex :: proc(dir: string) -> (n: int) {
	data: win.WIN32_FIND_DATAW
	h := FindFirstFileExW(
		search_pattern(dir),
		.Basic,
		&data,
		.NameMatch,
		nil,
		FIND_FIRST_EX_LARGE_FETCH,
	)
	if h == win.INVALID_HANDLE_VALUE {return -1}
	defer win.FindClose(h)
	for {
		check_name(data.cFileName[:cstr_len(data.cFileName[:])], &n)
		if !win.FindNextFileW(h, &data) {break}
	}
	return
}

// D: GetFileInformationByHandleEx(FileFullDirectoryInfo), 64 KiB batches. Closest to getdents.
m_handle_ex :: proc(dir: string) -> (n: int) {
	h := open_dir(dir)
	if h == win.INVALID_HANDLE_VALUE {return -1}
	defer win.CloseHandle(h)
	buf: [64 * 1024]u8 = ---
	class := win.FILE_INFO_BY_HANDLE_CLASS.FileFullDirectoryRestartInfo
	for win.GetFileInformationByHandleEx(h, class, &buf, len(buf)) {
		class = .FileFullDirectoryInfo
		off := 0
		for {
			e := (^FILE_FULL_DIR_INFO)(&buf[off])
			name := ([^]u16)(&e.FileName)[:e.FileNameLength / 2]
			check_name(name, &n)
			if e.NextEntryOffset == 0 {break}
			off += int(e.NextEntryOffset)
		}
	}
	return
}

// E: NtQueryDirectoryFile(FileNamesInformation): names only, 64 KiB batches.
m_nt_names :: proc(dir: string) -> (n: int) {
	h := open_dir(dir)
	if h == win.INVALID_HANDLE_VALUE {return -1}
	defer win.CloseHandle(h)
	buf: [64 * 1024]u8 = ---
	iosb: win.IO_STATUS_BLOCK
	restart := true
	for {
		st := NtQueryDirectoryFile(
			h,
			nil,
			nil,
			nil,
			&iosb,
			&buf,
			len(buf),
			win.FILE_INFORMATION_CLASS(12),
			false,
			nil,
			win.BOOLEAN(restart),
		)
		restart = false
		if st == STATUS_NO_MORE_FILES {break}
		if st < 0 {return -1}
		off := 0
		for {
			e := (^FILE_NAMES_INFORMATION)(&buf[off])
			name := ([^]u16)(&e.FileName)[:e.FileNameLength / 2]
			check_name(name, &n)
			if e.NextEntryOffset == 0 {break}
			off += int(e.NextEntryOffset)
		}
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

	// Populate: <files> .webp files plus some noise.
	os.make_directory_all(dir)
	existing := m_find_first(dir)
	if existing != files {
		fmt.printfln("populating %s with %d .webp files...", dir, files)
		for i in 0 ..< files {
			p := fmt.tprintf("%s\\%032x.webp", dir, i)
			if f, err := os.create(p); err == nil {os.close(f)}
			free_all(context.temp_allocator)
		}
		for i in 0 ..< 100 {
			if f, err := os.create(fmt.tprintf("%s\\noise_%d.txt", dir, i));
			   err == nil {os.close(f)}
		}
	}

	methods := []Method {
		{"A core:os iterator", m_core_os},
		{"B FindFirstFileW", m_find_first},
		{"C FindFirstFileExW basic+large", m_find_ex},
		{"D GetFileInfoByHandleEx full", m_handle_ex},
		{"E NtQueryDirectoryFile names", m_nt_names},
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
		// insertion sort for the median
		for i in 1 ..< len(times) {
			for j := i;
			    j > 0 && times[j] < times[j - 1];
			    j -= 1 {times[j], times[j - 1] = times[j - 1], times[j]}
		}
		fmt.printfln(
			"  %-32s %9.2f ms  (min %8.2f)  found=%d",
			m.name,
			times[len(times) / 2],
			times[0],
			count,
		)
		free_all(context.temp_allocator)
	}
}
