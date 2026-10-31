#+build windows
// Pipelined, UNORDERED raw NTFS $I30 read vs native NtQueryDirectoryFile (READ ONLY).
// Layout reference: github.com/fox-it/dissect.ntfs (index.py, mft.py, util.py).
//
// Design: setup once (target FILE record(s), $I30 runlist -> read chunks, extension
// records via $ATTRIBUTE_LIST). Every scan: re-read the $BITMAP:$I30 (live state),
// issue overlapped chunk reads at queue depth N on an IOCP-bound volume handle, and
// parse each chunk as it completes, in ANY order. Each in-use INDX block is
// self-contained (signature, VCN, fixups) and a B-tree stores live entries in
// internal nodes too, so the union over bitmap-set blocks + root = the directory.
// No tree walk, no ordering, no coalescing. Block validity is enforced per block;
// final name fingerprint must match native or the probe stops.
//
// Fixed at queue depth 16 -- the configuration that measured ~4.7 ms/scan on a
// 20,100-entry directory (10 MiB index, 2,515 live INDX blocks).
// Build: odin build dircache_dirlist_qd16.odin -file -o:speed -out:dircache-qd16.exe
// Run elevated: .\dircache-qd16.exe C:\tmp\booru-dirlist-bench 3
// Local NTFS only, no writes. Not a snapshot: keep the fixture quiet.
// Thread CPU figures only cover the calling thread (kernel I/O work is elsewhere).
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import win "core:sys/windows"
import "core:time"

foreign import k32 "system:Kernel32.lib"
foreign import nt "system:Ntdll.lib"
@(default_calling_convention = "system")
foreign k32 {
	GetThreadTimes :: proc(h: win.HANDLE, created, exited, kernel, user: ^win.FILETIME) -> win.BOOL ---
	GetFinalPathNameByHandleW :: proc(h: win.HANDLE, path: ^u16, size: win.DWORD, flags: win.DWORD) -> win.DWORD ---
	GetVolumePathNameW :: proc(path: win.LPCWSTR, root: ^u16, size: win.DWORD) -> win.BOOL ---
	GetVolumeNameForVolumeMountPointW :: proc(root: win.LPCWSTR, volume: ^u16, size: win.DWORD) -> win.BOOL ---
	GetVolumeInformationW :: proc(root: win.LPCWSTR, name: ^u16, name_size: win.DWORD, serial, component_length, flags: ^win.DWORD, fs: ^u16, fs_size: win.DWORD) -> win.BOOL ---
	GetQueuedCompletionStatus :: proc(port: win.HANDLE, bytes: ^win.DWORD, key: ^win.ULONG_PTR, ovl: ^^win.OVERLAPPED, ms: win.DWORD) -> win.BOOL ---
}
@(default_calling_convention = "system")
foreign nt {
	NtQueryDirectoryFile :: proc(h, event: win.HANDLE, apc, apc_context: rawptr, iosb: ^win.IO_STATUS_BLOCK, buffer: rawptr, length: win.ULONG, class: win.FILE_INFORMATION_CLASS, single: win.BOOLEAN, name: rawptr, restart: win.BOOLEAN) -> win.NTSTATUS ---
}

FSCTL_GET_NTFS_VOLUME_DATA :: win.DWORD(0x00090064)
FSCTL_GET_NTFS_FILE_RECORD :: win.DWORD(0x00090068)
STATUS_NO_MORE_FILES :: win.NTSTATUS(-2147483642)
FILE_ID_MASK :: u64(0x0000_ffff_ffff_ffff)
MAX_INDEX_BYTES :: u64(256 * 1024 * 1024)
CHUNK_BYTES :: 1024 * 1024
NT_BUFFER :: 64 * 1024
NT_REPEATS :: 20
DEPTH :: 16

Names :: struct {
	children, webp, hash_sum, hash_xor: u64,
}
Result :: struct {
	names:                                                      Names,
	calls, bytes, records, blocks, blocks_skipped, dos_skipped: u64,
	io_ns, parse_ns, meta_ns:                                   i64,
	wall_ms, kernel_ms, user_ms:                                f64,
	ok:                                                         bool,
}
Cpu :: struct {
	kernel, user: u64,
}

filetime :: proc(t: win.FILETIME) -> u64 {return(
		u64(t.dwHighDateTime) << 32 |
		u64(t.dwLowDateTime) \
	)}
cpu_now :: proc() -> Cpu {
	created, exited, kernel, user: win.FILETIME
	if !GetThreadTimes(win.GetCurrentThread(), &created, &exited, &kernel, &user) {
		fmt.eprintfln("GetThreadTimes failed: %d", win.GetLastError())
		os.exit(1)
	}
	return {filetime(kernel), filetime(user)}
}
finish :: proc(r: ^Result, start: time.Tick, cpu: Cpu) {
	r.wall_ms = time.duration_milliseconds(time.tick_since(start))
	end := cpu_now()
	r.kernel_ms = f64(end.kernel - cpu.kernel) / 10000
	r.user_ms = f64(end.user - cpu.user) / 10000
}
since :: proc(t: time.Tick) -> i64 {return time.duration_nanoseconds(time.tick_since(t))}

u16_at :: proc(b: []u8, p: int) -> u16 {return u16(b[p]) | u16(b[p + 1]) << 8}
u32_at :: proc(b: []u8, p: int) -> u32 {return u32(u16_at(b, p)) | u32(u16_at(b, p + 2)) << 16}
u64_at :: proc(b: []u8, p: int) -> u64 {return u64(u32_at(b, p)) | u64(u32_at(b, p + 4)) << 32}
put16 :: proc(b: []u8, p: int, v: u16) {b[p] = u8(v); b[p + 1] = u8(v >> 8)}
bad :: proc(m: string) -> bool {fmt.eprintfln("RAW: %s", m); return false}

// Order-independent fingerprint over UTF-16LE name bytes (same for both paths).
add_name :: proc(n: ^Names, name: []u8) {
	if len(name) == 2 && u16_at(name, 0) == '.' {return}
	if len(name) == 4 && u16_at(name, 0) == '.' && u16_at(name, 2) == '.' {return}
	n.children += 1
	h := u64(14695981039346656037)
	for b in name {h = (h ~ u64(b)) * 1099511628211}
	n.hash_sum += h
	n.hash_xor ~= h
	if len(name) >= 10 {
		t := name[len(name) - 10:]
		if u16_at(t, 0) == '.' &&
		   u16_at(t, 2) == 'w' &&
		   u16_at(t, 4) == 'e' &&
		   u16_at(t, 6) == 'b' &&
		   u16_at(t, 8) == 'p' {n.webp += 1}
	}
}
same_names :: proc(a, b: Names) -> bool {
	return(
		a.children == b.children &&
		a.webp == b.webp &&
		a.hash_sum == b.hash_sum &&
		a.hash_xor == b.hash_xor \
	)
}

// ---------------------------------------------------------------- native baseline
nt_scan :: proc(path: win.LPCWSTR, buf: []u8) -> Result {
	cpu := cpu_now()
	start := time.tick_now()
	r := nt_scan_impl(path, buf)
	finish(&r, start, cpu)
	return r
}
nt_scan_impl :: proc(path: win.LPCWSTR, buf: []u8) -> (r: Result) {
	h := win.CreateFileW(
		path,
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if h ==
	   win.INVALID_HANDLE_VALUE {fmt.eprintfln("directory open failed: %d", win.GetLastError()); return}
	defer win.CloseHandle(h)
	restart := true
	for {
		iosb: win.IO_STATUS_BLOCK
		t := time.tick_now()
		st := NtQueryDirectoryFile(
			h,
			nil,
			nil,
			nil,
			&iosb,
			raw_data(buf),
			win.ULONG(len(buf)),
			win.FILE_INFORMATION_CLASS(12),
			false,
			nil,
			win.BOOLEAN(restart),
		)
		r.io_ns += since(t)
		restart = false
		r.calls += 1
		if st == STATUS_NO_MORE_FILES {r.ok = true; return}
		if st < 0 {fmt.eprintfln("NtQueryDirectoryFile failed: %x", u32(st)); return}
		n := int(iosb.Information)
		if n < 12 || n > len(buf) {fmt.eprintln("invalid native length"); return}
		r.bytes += u64(n)
		t = time.tick_now()
		pos := 0
		for {
			if pos + 12 > n {fmt.eprintln("truncated native record"); return}
			next := int(u32_at(buf, pos))
			name_len := int(u32_at(buf, pos + 8))
			end := next == 0 ? n : pos + next
			if end > n ||
			   end < pos + 12 ||
			   name_len % 2 != 0 ||
			   name_len > end - pos - 12 {fmt.eprintln("invalid native record"); return}
			add_name(&r.names, buf[pos + 12:pos + 12 + name_len])
			r.records += 1
			if next == 0 {break}
			pos = end
		}
		r.parse_ns += since(t)
	}
}

// ---------------------------------------------------------------- raw plan / setup
Run :: struct {
	vcn, lcn, clusters: u64,
}
// ovl MUST be first: completions return ^OVERLAPPED which we cast back to ^Chunk.
Chunk :: struct {
	ovl:                 win.OVERLAPPED,
	stream_off, vol_off: u64,
	length:              u32,
}
Raw_Plan :: struct {
	volume, avol, port:                       win.HANDLE, // sync (metadata) / overlapped+IOCP (index data)
	root, data:                               []u8,
	runs:                                     [dynamic]Run,
	chunks:                                   []Chunk,
	bitmap_ref:                               u64,
	sector, cluster, record_size, index_size: int,
	unit:                                     int, // bytes per VCN unit
	stream_bytes, volume_bytes, reference:    u64,
}

// FILE records come from FSCTL and may already be logical: apply fixup only when
// every sector tail still carries the USA stamp. INDX blocks are raw: strict.
fix_file :: proc(b: []u8) -> bool {
	if len(b) < 512 || len(b) % 512 != 0 {return bad("bad FILE size")}
	off, count := int(u16_at(b, 4)), int(u16_at(b, 6))
	if off < 8 ||
	   off % 2 != 0 ||
	   count != len(b) / 512 + 1 ||
	   off + count * 2 > 512 {return bad("bad FILE USA")}
	stamp := u16_at(b, off)
	for i in 1 ..< count {if u16_at(b, i * 512 - 2) != stamp {return true}}
	for i in 1 ..< count {put16(b, i * 512 - 2, u16_at(b, off + i * 2))}
	return true
}
fix_indx :: proc(b: []u8) -> bool {
	off, count := int(u16_at(b, 4)), int(u16_at(b, 6))
	if off < 8 ||
	   off % 2 != 0 ||
	   count != len(b) / 512 + 1 ||
	   off + count * 2 > 512 {return bad("bad INDX USA")}
	stamp := u16_at(b, off)
	for i in 1 ..< count {if u16_at(b, i * 512 - 2) != stamp {return bad("INDX fixup mismatch (live change or stale block)")}}
	for i in 1 ..< count {put16(b, i * 512 - 2, u16_at(b, off + i * 2))}
	return true
}

is_i30 :: proc(attr: []u8) -> bool {
	if len(attr) < 16 || attr[9] != 4 {return false}
	p := int(u16_at(attr, 10))
	return(
		p >= 16 &&
		p + 8 <= len(attr) &&
		u16_at(attr, p) == '$' &&
		u16_at(attr, p + 2) == 'I' &&
		u16_at(attr, p + 4) == '3' &&
		u16_at(attr, p + 6) == '0' \
	)
}
little :: proc(b: []u8) -> u64 {
	v: u64
	for x, i in b {v |= u64(x) << uint(8 * i)}
	return v
}
decode_runs :: proc(p: ^Raw_Plan, attr: []u8) -> bool {
	if len(attr) < 64 {return bad("short nonresident attribute")}
	if u16_at(attr, 12) != 0 {return bad("compressed/encrypted/sparse unsupported")}
	vcn := u64_at(attr, 16)
	highest := u64_at(attr, 24)
	pos := int(u16_at(attr, 32))
	if pos < 64 || pos >= len(attr) {return bad("bad mapping-pairs offset")}
	lcn: i64
	for pos < len(attr) && attr[pos] != 0 {
		header := attr[pos]
		pos += 1
		nlen, noff := int(header & 15), int(header >> 4)
		if nlen < 1 ||
		   nlen > 8 ||
		   noff < 1 ||
		   noff > 8 ||
		   pos + nlen + noff > len(attr) {return bad("invalid/sparse runlist")}
		clusters := little(attr[pos:pos + nlen])
		pos += nlen
		bits := little(attr[pos:pos + noff])
		if noff < 8 && attr[pos + noff - 1] & 0x80 != 0 {bits |= ~u64(0) << uint(noff * 8)}
		delta := transmute(i64)bits
		pos += noff
		if delta == -0x7fff_ffff_ffff_ffff - 1 {return bad("bad LCN delta")}
		if delta < 0 && lcn < -delta ||
		   delta > 0 && lcn > 0x7fff_ffff_ffff_ffff - delta {return bad("LCN overflow")}
		lcn += delta
		if lcn < 0 ||
		   clusters == 0 ||
		   clusters > p.volume_bytes / u64(p.cluster) ||
		   u64(lcn) > p.volume_bytes / u64(p.cluster) - clusters {return bad("run outside volume")}
		if vcn > 0x7fff_ffff_ffff_ffff - clusters {return bad("VCN overflow")}
		append(&p.runs, Run{vcn, u64(lcn), clusters})
		vcn += clusters
	}
	if pos >= len(attr) ||
	   vcn == 0 ||
	   vcn - 1 != highest {return bad("unterminated/inconsistent runlist")}
	return true
}
// Synchronous aligned read on the metadata handle (setup + per-scan bitmap only).
read_sync :: proc(p: ^Raw_Plan, dst: []u8, offset: u64, r: ^Result) -> bool {
	if offset > p.volume_bytes ||
	   u64(len(dst)) > p.volume_bytes - offset {return bad("read outside volume")}
	if offset % u64(p.sector) != 0 || len(dst) % p.sector != 0 {return bad("unaligned read")}
	if !win.SetFilePointerEx(
		p.volume,
		win.LARGE_INTEGER(offset),
		nil,
		win.FILE_BEGIN,
	) {return bad("seek failed")}
	done := 0
	for done < len(dst) {
		n := min(len(dst) - done, CHUNK_BYTES)
		got: win.DWORD
		r.calls += 1
		if !win.ReadFile(p.volume, &dst[done], win.DWORD(n), &got, nil) ||
		   int(got) != n {return bad("sync read failed")}
		r.bytes += u64(got)
		done += n
	}
	return true
}

fetch_record :: proc(p: ^Raw_Plan, reference: u64, r: ^Result) -> (record: []u8, ok: bool) {
	resp := make([]u8, p.record_size + 16)
	defer delete(resp)
	req := reference & FILE_ID_MASK
	used: win.DWORD
	r.calls += 1
	if !win.DeviceIoControl(
		p.volume,
		FSCTL_GET_NTFS_FILE_RECORD,
		&req,
		8,
		raw_data(resp),
		win.DWORD(len(resp)),
		&used,
		nil,
	) {fmt.eprintfln("FILE %x failed: %d", reference, win.GetLastError()); return}
	r.bytes += u64(used)
	if used < 12 || int(used) > len(resp) {bad("short FILE response"); return}
	length := int(u32_at(resp, 8))
	if u64_at(resp, 0) & FILE_ID_MASK != req ||
	   length != p.record_size ||
	   length > int(used) - 12 {bad("different/invalid FILE record"); return}
	view := resp[12:12 + length]
	if string(view[:4]) != "FILE" || !fix_file(view) {bad("invalid FILE"); return}
	if u16_at(view, 22) & 1 == 0 ||
	   u16_at(view, 16) != u16(reference >> 48) {bad("stale FILE reference"); return}
	if reference == p.reference {
		if u16_at(view, 22) & 2 == 0 ||
		   u64_at(view, 32) != 0 {bad("base is not the target directory"); return}
	} else if u64_at(view, 32) != p.reference {bad("extension of a different base"); return}
	record = make([]u8, length)
	copy(record, view)
	r.records += 1
	return record, true
}
attribute_value :: proc(p: ^Raw_Plan, attr: []u8, r: ^Result) -> (value: []u8, ok: bool) {
	if attr[8] == 0 {
		size, off := int(u32_at(attr, 16)), int(u16_at(attr, 20))
		if off < 24 ||
		   off > len(attr) ||
		   size > len(attr) - off {bad("bad resident value"); return}
		value = make([]u8, size)
		copy(value, attr[off:off + size])
		return value, true
	}
	if attr[8] != 1 ||
	   len(attr) < 64 ||
	   u64_at(attr, 16) != 0 {bad("unsupported nonresident layout"); return}
	size := u64_at(attr, 48)
	if size == 0 ||
	   size > 16 * 1024 * 1024 ||
	   u64_at(attr, 56) < size {bad("bad/oversized nonresident value"); return}
	aligned := (size + u64(p.sector) - 1) / u64(p.sector) * u64(p.sector)
	q := Raw_Plan {
		volume       = p.volume,
		sector       = p.sector,
		cluster      = p.cluster,
		volume_bytes = p.volume_bytes,
		runs         = make([dynamic]Run),
	}
	defer delete(q.runs)
	if !decode_runs(&q, attr) {return}
	buf := make([]u8, int(aligned))
	defer delete(buf)
	cursor: u64
	for run in q.runs {
		if run.vcn * u64(p.cluster) != cursor {bad("missing value extent"); return}
		if cursor >= aligned {break}
		n := min(run.clusters * u64(p.cluster), aligned - cursor)
		if !read_sync(p, buf[int(cursor):int(cursor + n)], run.lcn * u64(p.cluster), r) {return}
		cursor += n
	}
	if cursor != aligned {bad("short value runlist"); return}
	value = make([]u8, int(size))
	copy(value, buf[:int(size)])
	return value, true
}
queue_index_records :: proc(v: []u8, refs: ^[dynamic]u64) -> bool {
	pos := 0
	for pos < len(v) {
		if pos + 26 > len(v) {return bad("truncated ATTRIBUTE_LIST")}
		kind := u32_at(v, pos)
		if kind == 0xffff_ffff {break}
		length := int(u16_at(v, pos + 4))
		chars, off := int(v[pos + 6]), int(v[pos + 7])
		if length < 26 ||
		   length % 8 != 0 ||
		   length > len(v) - pos ||
		   off > length ||
		   chars * 2 > length - off {return bad("bad ATTRIBUTE_LIST entry")}
		if (kind == 0x90 || kind == 0xa0 || kind == 0xb0) && chars == 4 && off >= 26 {
			nm := v[pos + off:pos + off + 8]
			if u16_at(nm, 0) == '$' &&
			   u16_at(nm, 2) == 'I' &&
			   u16_at(nm, 4) == '3' &&
			   u16_at(nm, 6) == '0' {
				ref := u64_at(v, pos + 16)
				found := false
				for old in refs^ {
					if old == ref {found = true; break}
					if old & FILE_ID_MASK ==
					   ref & FILE_ID_MASK {return bad("conflicting sequences in ATTRIBUTE_LIST")}
				}
				if !found {
					if len(refs^) >= 128 {return bad("over 128 extension records")}
					append(refs, ref)
				}
			}
		}
		pos += length
	}
	return true
}
collect_attributes :: proc(
	p: ^Raw_Plan,
	ref: u64,
	record: []u8,
	refs: ^[dynamic]u64,
	r: ^Result,
) -> bool {
	limit, pos := int(u32_at(record, 24)), int(u16_at(record, 20))
	if limit > len(record) || pos < 48 || pos > limit {return bad("bad FILE attribute bounds")}
	for pos + 4 <= limit {
		kind := u32_at(record, pos)
		if kind == 0xffff_ffff {return true}
		if pos + 16 > limit {return bad("short attribute")}
		length := int(u32_at(record, pos + 4))
		if length < 24 || length > limit - pos {return bad("bad attribute length")}
		attr := record[pos:pos + length]
		if kind == 0x20 {
			v, ok := attribute_value(p, attr, r)
			if !ok {return false}
			ok = queue_index_records(v, refs)
			delete(v)
			if !ok {return false}
		}
		if is_i30(attr) {
			switch kind {
			case 0x90:
				if attr[8] != 0 || len(p.root) != 0 {return bad("bad/multiple INDEX_ROOT")}
				size, off := int(u32_at(attr, 16)), int(u16_at(attr, 20))
				if off < 24 ||
				   off > length ||
				   size < 32 ||
				   size > length - off {return bad("bad INDEX_ROOT")}
				p.root = make([]u8, size)
				copy(p.root, attr[off:off + size])
			case 0xa0:
				if attr[8] != 1 || length < 64 {return bad("bad INDEX_ALLOCATION")}
				if u64_at(attr, 16) == 0 {
					p.stream_bytes = u64_at(attr, 48)
					if u64_at(attr, 56) <
					   p.stream_bytes {return bad("uninitialized tail unsupported")}
				}
				if !decode_runs(p, attr) {return false}
			case 0xb0:
				if p.bitmap_ref != 0 {return bad("multiple $I30 bitmaps")}
				p.bitmap_ref = ref
			}
		}
		pos += length
	}
	return bad("missing attribute terminator")
}
// Live bitmap, re-read every scan (it changes with directory growth/shrink).
read_bitmap :: proc(p: ^Raw_Plan, r: ^Result) -> (bits: []u8, ok: bool) {
	record, fetched := fetch_record(p, p.bitmap_ref, r)
	if !fetched {return}
	defer delete(record)
	limit, pos := int(u32_at(record, 24)), int(u16_at(record, 20))
	for pos + 16 <= limit {
		kind := u32_at(record, pos)
		if kind == 0xffff_ffff {break}
		length := int(u32_at(record, pos + 4))
		if length < 24 || length > limit - pos {break}
		attr := record[pos:pos + length]
		if kind == 0xb0 && is_i30(attr) {return attribute_value(p, attr, r)}
		pos += length
	}
	bad("$I30 bitmap disappeared")
	return
}

prepare_raw :: proc(p: ^Raw_Plan, reference: u64, volume: win.LPCWSTR) -> (r: Result) {
	cpu := cpu_now()
	start := time.tick_now()
	r = prepare_impl(p, reference, volume)
	finish(&r, start, cpu)
	return
}
prepare_impl :: proc(p: ^Raw_Plan, reference: u64, volume: win.LPCWSTR) -> (r: Result) {
	p.reference = reference
	p.runs = make([dynamic]Run)
	share := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE
	p.volume = win.CreateFileW(
		volume,
		win.GENERIC_READ,
		win.DWORD(share),
		nil,
		win.OPEN_EXISTING,
		0,
		nil,
	)
	if p.volume ==
	   win.INVALID_HANDLE_VALUE {fmt.eprintfln("volume open failed: %d (elevate)", win.GetLastError()); return}
	p.avol = win.CreateFileW(
		volume,
		win.GENERIC_READ,
		win.DWORD(share),
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if p.avol ==
	   win.INVALID_HANDLE_VALUE {fmt.eprintfln("overlapped volume open failed: %d", win.GetLastError()); return}
	p.port = win.CreateIoCompletionPort(p.avol, nil, 0, 1)
	if p.port == nil {fmt.eprintfln("IOCP create failed: %d", win.GetLastError()); return}
	geo: [128]u8
	used: win.DWORD
	r.calls += 1
	if !win.DeviceIoControl(
		p.volume,
		FSCTL_GET_NTFS_VOLUME_DATA,
		nil,
		0,
		&geo[0],
		len(geo),
		&used,
		nil,
	) {fmt.eprintfln("volume data failed: %d", win.GetLastError()); return}
	if used < 96 {bad("short volume data"); return}
	p.sector, p.cluster, p.record_size =
		int(u32_at(geo[:], 40)), int(u32_at(geo[:], 44)), int(u32_at(geo[:], 48))
	if p.sector < 512 ||
	   p.sector > 65536 ||
	   p.cluster < p.sector ||
	   p.cluster > 2 * 1024 * 1024 ||
	   p.cluster % p.sector != 0 ||
	   p.record_size < 512 ||
	   p.record_size > 1024 * 1024 ||
	   p.record_size % 512 != 0 {bad("unsupported geometry"); return}
	sectors := u64_at(geo[:], 8)
	if sectors > 0x7fff_ffff_ffff_ffff / u64(p.sector) {bad("bad volume size"); return}
	p.volume_bytes = sectors * u64(p.sector)

	refs := make([dynamic]u64)
	defer delete(refs)
	append(&refs, reference)
	for i := 0; i < len(refs); i += 1 {
		rec, ok := fetch_record(p, refs[i], &r)
		if !ok {return}
		ok = collect_attributes(p, refs[i], rec, &refs, &r)
		delete(rec)
		if !ok {return}
	}
	if len(p.root) < 32 || u32_at(p.root, 0) != 0x30 {bad("missing filename index root"); return}
	p.index_size = int(u32_at(p.root, 8))
	if p.index_size < 512 ||
	   p.index_size > CHUNK_BYTES ||
	   CHUNK_BYTES % p.index_size != 0 ||
	   p.index_size % p.sector != 0 {bad("unsupported index block size"); return}
	p.unit = p.cluster <= p.index_size ? p.cluster : 512
	if p.stream_bytes > MAX_INDEX_BYTES ||
	   p.stream_bytes % u64(p.index_size) != 0 {bad("index stream too big/unaligned"); return}
	if p.stream_bytes == 0 {r.ok = true; return}
	if len(p.runs) == 0 ||
	   p.bitmap_ref == 0 {bad("index allocation without extents or bitmap"); return}
	slice.sort_by(p.runs[:], proc(a, b: Run) -> bool {return a.vcn < b.vcn})
	chunks := make([dynamic]Chunk)
	cursor: u64
	for run in p.runs {
		if run.vcn != cursor {bad("missing/overlapping extents"); return}
		cursor += run.clusters
		start := run.vcn * u64(p.cluster)
		if start >= p.stream_bytes {continue}
		length := min(run.clusters * u64(p.cluster), p.stream_bytes - start)
		if start % u64(p.index_size) != 0 ||
		   length % u64(p.index_size) !=
			   0 {bad("INDX block straddles extents (unsupported)"); return}
		for off: u64 = 0; off < length; off += CHUNK_BYTES {
			n := min(u64(CHUNK_BYTES), length - off)
			append(
				&chunks,
				Chunk {
					stream_off = start + off,
					vol_off = run.lcn * u64(p.cluster) + off,
					length = u32(n),
				},
			)
		}
	}
	if cursor * u64(p.cluster) < p.stream_bytes {bad("runlist shorter than stream"); return}
	p.chunks = chunks[:]
	mem := win.VirtualAlloc(
		nil,
		uint(p.stream_bytes),
		win.MEM_RESERVE | win.MEM_COMMIT,
		win.PAGE_READWRITE,
	)
	if mem == nil {bad("buffer allocation failed"); return}
	p.data = ([^]u8)(mem)[:int(p.stream_bytes)]
	r.ok = true
	return
}
destroy_raw :: proc(p: ^Raw_Plan) {
	for h in ([?]win.HANDLE{p.avol, p.volume, p.port}) {
		if h != nil && h != win.INVALID_HANDLE_VALUE {win.CloseHandle(h)}
	}
	if len(p.data) != 0 {win.VirtualFree(raw_data(p.data), 0, win.MEM_RELEASE)}
	delete(p.root)
	delete(p.runs)
	delete(p.chunks)
}

// ---------------------------------------------------------------- unordered parse
// Entries of ONE node (root or INDX). Child pointers are ignored: children are
// parsed independently as their own bitmap-set blocks.
parse_entries :: proc(p: ^Raw_Plan, node: []u8, header: int, r: ^Result) -> bool {
	if header + 16 > len(node) {return bad("bad node header")}
	first, total := int(u32_at(node, header)), int(u32_at(node, header + 4))
	if first < 16 || total < first || total > len(node) - header {return bad("bad entry bounds")}
	pos, end := header + first, header + total
	for pos + 16 <= end {
		length, key_len, flags :=
			int(u16_at(node, pos + 8)), int(u16_at(node, pos + 10)), u16_at(node, pos + 12)
		if length < 16 ||
		   length % 8 != 0 ||
		   length > end - pos ||
		   flags & ~u16(3) != 0 {return bad("bad INDEX_ENTRY")}
		if flags & 2 != 0 {return true}
		trailer := flags & 1 != 0 ? 8 : 0
		if key_len < 66 || key_len > length - 16 - trailer {return bad("bad FILE_NAME key")}
		key := node[pos + 16:pos + 16 + key_len]
		chars, ns := int(key[64]), key[65]
		if ns > 3 ||
		   66 + chars * 2 > len(key) ||
		   u64_at(key, 0) != p.reference {return bad("bad key / foreign parent")}
		if ns != 2 {add_name(&r.names, key[66:66 + chars * 2])} else {r.dos_skipped += 1}
		r.records += 1
		pos += length
	}
	return bad("missing terminal entry")
}
parse_chunk :: proc(p: ^Raw_Plan, c: ^Chunk, bits: []u8, r: ^Result) -> bool {
	for off := 0; off < int(c.length); off += p.index_size {
		n := int(c.stream_off / u64(p.index_size)) + off / p.index_size
		if bits[n >> 3] >> uint(n & 7) & 1 == 0 {r.blocks_skipped += 1; continue} 	// free/stale: cheap skip
		block := p.data[int(c.stream_off) + off:int(c.stream_off) + off + p.index_size]
		if string(block[:4]) != "INDX" ||
		   u64_at(block, 16) != u64(n) * u64(p.index_size) / u64(p.unit) ||
		   !fix_indx(block) {return bad("in-use block invalid")}
		r.blocks += 1
		if !parse_entries(p, block, 24, r) {return false}
	}
	return true
}

// ---------------------------------------------------------------- pipelined scan
raw_scan :: proc(p: ^Raw_Plan, depth: int) -> Result {
	cpu := cpu_now()
	start := time.tick_now()
	r := raw_scan_impl(p, depth)
	finish(&r, start, cpu)
	return r
}
raw_scan_impl :: proc(p: ^Raw_Plan, depth: int) -> (r: Result) {
	t := time.tick_now()
	bits: []u8
	if p.stream_bytes != 0 {
		ok: bool
		bits, ok = read_bitmap(p, &r)
		if !ok {return}
		if u64(len(bits)) * 8 <
		   p.stream_bytes /
			   u64(p.index_size) {bad("bitmap shorter than index"); delete(bits); return}
	}
	defer delete(bits)
	r.meta_ns = since(t)
	t = time.tick_now()
	if !parse_entries(p, p.root, 16, &r) {return}
	r.parse_ns += since(t)

	next, inflight, done := 0, 0, 0
	failed := false
	for done < len(p.chunks) || inflight > 0 {
		for !failed && next < len(p.chunks) && inflight < depth {
			c := &p.chunks[next]
			c.ovl = win.OVERLAPPED{}
			c.ovl.OffsetFull = c.vol_off
			t = time.tick_now()
			ok := win.ReadFile(
				p.avol,
				&p.data[int(c.stream_off)],
				win.DWORD(c.length),
				nil,
				&c.ovl,
			)
			r.io_ns += since(t)
			r.calls += 1
			if !ok && win.GetLastError() != win.ERROR_IO_PENDING {
				fmt.eprintfln("ReadFile failed: %d", win.GetLastError())
				failed = true
				break
			}
			next += 1
			inflight += 1
		}
		if inflight == 0 {break}
		bytes: win.DWORD
		key: win.ULONG_PTR
		ovl: ^win.OVERLAPPED
		t = time.tick_now()
		ok := GetQueuedCompletionStatus(p.port, &bytes, &key, &ovl, win.INFINITE)
		r.io_ns += since(t)
		if ovl == nil {fmt.eprintfln("IOCP wait failed: %d", win.GetLastError()); os.exit(1)} 	// cannot safely free buffers
		inflight -= 1
		c := cast(^Chunk)ovl
		done += 1
		if !ok ||
		   bytes !=
			   win.DWORD(
				   c.length,
			   ) {fmt.eprintfln("chunk read failed/short: ok=%v bytes=%d", ok, bytes); failed = true; continue}
		r.bytes += u64(bytes)
		if failed {continue}
		t = time.tick_now()
		if !parse_chunk(p, c, bits, &r) {failed = true}
		r.parse_ns += since(t)
	}
	r.ok = !failed
	return
}

batch :: proc(p: ^Raw_Plan, depth: int, repeats: int, expected: Names) -> (total: Result) {
	total.ok = true
	for _ in 0 ..< repeats {
		r := raw_scan(p, depth)
		if !r.ok || !same_names(r.names, expected) {
			fmt.eprintfln(
				"raw depth=%d invalid or fingerprint mismatch (children=%d); STOP",
				depth,
				r.names.children,
			)
			total.ok = false
			return
		}
		accumulate(&total, r)
	}
	return
}
nt_batch :: proc(path: win.LPCWSTR, buf: []u8, expected: Names) -> (total: Result) {
	total.ok = true
	for _ in 0 ..< NT_REPEATS {
		r := nt_scan(path, buf)
		if !r.ok || !same_names(r.names, expected) {
			fmt.eprintln("native invalid/changed; STOP")
			total.ok = false
			return
		}
		accumulate(&total, r)
	}
	return
}
accumulate :: proc(t: ^Result, r: Result) {
	t.names = r.names
	t.calls += r.calls
	t.bytes += r.bytes
	t.records += r.records
	t.blocks += r.blocks
	t.blocks_skipped += r.blocks_skipped
	t.dos_skipped += r.dos_skipped
	t.io_ns += r.io_ns
	t.parse_ns += r.parse_ns
	t.meta_ns += r.meta_ns
	t.wall_ms += r.wall_ms
	t.kernel_ms += r.kernel_ms
	t.user_ms += r.user_ms
}
report :: proc(label: string, r: Result, scans: int) {
	d := f64(scans)
	fmt.printfln(
		"%-12s ok=%v wall=%.3f ms (thread cpu k=%.2f u=%.2f) calls=%.1f MiB=%.2f records=%.0f blocks=%.0f skipped=%.0f DOS=%.0f children=%d webp=%d",
		label,
		r.ok,
		r.wall_ms / d,
		r.kernel_ms / d,
		r.user_ms / d,
		f64(r.calls) / d,
		f64(r.bytes) / d / 1048576,
		f64(r.records) / d,
		f64(r.blocks) / d,
		f64(r.blocks_skipped) / d,
		f64(r.dos_skipped) / d,
		r.names.children,
		r.names.webp,
	)
	per := r.records > 0 ? f64(r.parse_ns) / f64(r.records) : 0
	fmt.printfln(
		"             io/wait=%.3f ms parse=%.3f ms (%.1f ns/record) bitmap+meta=%.3f ms",
		f64(r.io_ns) / d / 1e6,
		f64(r.parse_ns) / d / 1e6,
		per,
		f64(r.meta_ns) / d / 1e6,
	)
}

main :: proc() {
	fmt.printfln("PID=%d TID=%d -- READ ONLY", win.GetCurrentProcessId(), win.GetCurrentThreadId())
	if len(os.args) <
	   2 {fmt.eprintln("usage: dirindex-probe.exe <directory> [rounds=3]"); os.exit(2)}
	rounds := len(os.args) > 2 ? strconv.parse_int(os.args[2]) or_else 0 : 3
	if rounds < 1 || rounds > 20 {fmt.eprintln("rounds 1..20"); os.exit(2)}
	path := win.utf8_to_wstring(os.args[1], context.temp_allocator)
	dir := win.CreateFileW(
		path,
		win.FILE_LIST_DIRECTORY,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if dir ==
	   win.INVALID_HANDLE_VALUE {fmt.eprintfln("open directory failed: %d", win.GetLastError()); os.exit(1)}
	defer win.CloseHandle(dir)
	info: win.BY_HANDLE_FILE_INFORMATION
	if !win.GetFileInformationByHandle(
		dir,
		&info,
	) {fmt.eprintfln("directory ID failed: %d", win.GetLastError()); os.exit(1)}
	if info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY ==
	   0 {fmt.eprintln("not a directory"); os.exit(1)}
	parent := u64(info.nFileIndexHigh) << 32 | u64(info.nFileIndexLow)
	final_path: [32768]u16
	n := GetFinalPathNameByHandleW(dir, &final_path[0], len(final_path), 0)
	if n == 0 ||
	   n >= len(final_path) {fmt.eprintfln("resolve failed: %d", win.GetLastError()); os.exit(1)}
	root: [32768]u16
	volume: [1024]u16
	if !GetVolumePathNameW(win.LPCWSTR(&final_path[0]), &root[0], len(root)) ||
	   !GetVolumeNameForVolumeMountPointW(
			   win.LPCWSTR(&root[0]),
			   &volume[0],
			   len(volume),
		   ) {fmt.eprintfln("local volume resolve failed: %d", win.GetLastError()); os.exit(1)}
	fs: [32]u16
	serial: win.DWORD
	if !GetVolumeInformationW(
		win.LPCWSTR(&volume[0]),
		nil,
		0,
		&serial,
		nil,
		nil,
		&fs[0],
		len(fs),
	) {fmt.eprintfln("volume info failed: %d", win.GetLastError()); os.exit(1)}
	if fs[0] != 'N' ||
	   fs[1] != 'T' ||
	   fs[2] != 'F' ||
	   fs[3] != 'S' ||
	   fs[4] != 0 ||
	   serial !=
		   info.dwVolumeSerialNumber {fmt.eprintln("needs same-volume local NTFS"); os.exit(1)}
	for i in 0 ..< len(volume) {
		if volume[i] == 0 {
			if i > 0 && volume[i - 1] == '\\' {volume[i - 1] = 0}
			break
		}
	}

	fmt.printfln(
		"directory=%s ref=%x rounds=%d scans/batch=%d",
		os.args[1],
		parent,
		rounds,
		NT_REPEATS,
	)
	nt_buf := make([]u8, NT_BUFFER)
	defer delete(nt_buf)
	warm := nt_scan(path, nt_buf)
	if !warm.ok {os.exit(1)}
	report("native-warm", warm, 1)
	plan: Raw_Plan
	defer destroy_raw(&plan)
	setup := prepare_raw(&plan, parent, win.LPCWSTR(&volume[0]))
	report("raw-setup", setup, 1)
	if !setup.ok {fmt.eprintln("unsupported layout/access; no fallback"); os.exit(1)}
	fmt.printfln(
		"sector=%d cluster=%d INDX=%d stream=%d extents=%d chunks=%d",
		plan.sector,
		plan.cluster,
		plan.index_size,
		plan.stream_bytes,
		len(plan.runs),
		len(plan.chunks),
	)
	first := raw_scan(&plan, DEPTH)
	report("raw-first", first, 1)
	if !first.ok ||
	   !same_names(first.names, warm.names) {fmt.eprintln("STOP: names differ"); os.exit(1)}
	fmt.println("fingerprints match")

	for round in 1 ..= rounds {
		fmt.printfln("ROUND %d", round)
		if round % 2 == 1 {
			a := nt_batch(path, nt_buf, warm.names)
			report("native", a, NT_REPEATS)
			if !a.ok {os.exit(1)}
		}
		b := batch(&plan, DEPTH, NT_REPEATS, warm.names)
		report("raw qd16", b, NT_REPEATS)
		if !b.ok {os.exit(1)}
		if round % 2 == 0 {
			a := nt_batch(path, nt_buf, warm.names)
			report("native", a, NT_REPEATS)
			if !a.ok {os.exit(1)}
		}
	}
	check := nt_scan(path, nt_buf)
	if !check.ok ||
	   !same_names(
			   check.names,
			   warm.names,
		   ) {fmt.eprintln("directory changed during run: INVALID"); os.exit(1)}
	fmt.println("done; all scans matched native")
}
