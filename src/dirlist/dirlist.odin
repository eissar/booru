// Directory listing helpers shared by packages that read directories in
// batches. Linux callers use linux.getdents directly; this provides the
// equivalent batch read on Windows.
package dirlist

import win "core:sys/windows"

when ODIN_OS == .Windows {
	foreign import ntdll "system:Ntdll.lib"

	@(default_calling_convention = "system", private = "file")
	foreign ntdll {
		NtQueryDirectoryFile :: proc(FileHandle: win.HANDLE, Event: win.HANDLE, ApcRoutine: rawptr, ApcContext: rawptr, IoStatusBlock: ^win.IO_STATUS_BLOCK, FileInformation: rawptr, Length: win.ULONG, FileInformationClass: win.FILE_INFORMATION_CLASS, ReturnSingleEntry: win.BOOLEAN, FileName: rawptr, RestartScan: win.BOOLEAN) -> win.NTSTATUS ---
	}

	@(private = "file")
	FILE_DIRECTORY_INFORMATION :: struct {
		NextEntryOffset: u32,
		FileIndex:       u32,
		CreationTime:    i64,
		LastAccessTime:  i64,
		LastWriteTime:   i64,
		ChangeTime:      i64,
		EndOfFile:       i64,
		AllocationSize:  i64,
		FileAttributes:  u32,
		FileNameLength:  u32, // bytes
		FileName:        [1]u16,
	}

	@(private = "file")
	STATUS_NO_MORE_FILES :: win.NTSTATUS(-2147483642) // 0x80000006

	// getdents equivalent: reads the next batch of entries from an open
	// directory handle and appends their UTF-8 names (temp allocator).
	// n is the number of entries read; 0 means end of directory.
	read_batch :: proc(
		h: win.HANDLE,
		buf: []u64,
		names: ^[dynamic]string,
		dirs_only: bool,
	) -> (
		n: int,
		ok: bool,
	) {
		bytes := ([^]u8)(raw_data(buf))[:len(buf) * size_of(u64)]
		iosb: win.IO_STATUS_BLOCK
		st := NtQueryDirectoryFile(
			h,
			nil,
			nil,
			nil,
			&iosb,
			raw_data(bytes),
			win.ULONG(len(bytes)),
			.FileDirectoryInformation,
			false,
			nil,
			false,
		)
		if st == STATUS_NO_MORE_FILES {return 0, true}
		if st < 0 {return 0, false}
		off := 0
		for {
			e := (^FILE_DIRECTORY_INFORMATION)(&bytes[off])
			n += 1
			if !dirs_only || e.FileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 {
				wname := ([^]u16)(&e.FileName)[:e.FileNameLength / 2]
				if name, err := win.utf16_to_utf8(wname, context.temp_allocator); err == nil {
					append(names, name)
				}
			}
			if e.NextEntryOffset == 0 {break}
			off += int(e.NextEntryOffset)
		}
		return n, true
	}
}
