package webpinfo

import "core:c"

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
	foreign import validator {"windows-amd64/webpinfo.lib", "../libwebp/windows-amd64/libwebp.lib"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import validator {"linux-amd64/libwebpinfo.a", "system:webp"}
} else {
	#panic("webpinfo supports Linux and Windows amd64 only")
}

Status :: enum c.int {
	OK = 0,
	Truncated_Data,
	Parse_Error,
	Invalid_Param,
	Bitstream_Error,
	Missing_Data,
	Invalid_Command,
}

// Equivalent validation to webpinfo -diag, without printed diagnostics.
// Warnings alone succeed. This validates container/headers, not pixel decoding.
// Input is borrowed for the call; independent invocations are thread-safe.
@(default_calling_convention = "c")
foreign validator {
	@(link_name = "webpinfo_validate")
	validate :: proc(data: [^]u8, size: c.size_t) -> Status ---
}
