package tidy

import "core:c"

when ODIN_OS == .Windows {
	foreign import tidy "windows-amd64/tidy.lib"
} else when ODIN_OS == .Linux {
	foreign import tidy "linux-amd64/libtidy.so"
} else {
	foreign import tidy "system:tidy"
}

Doc :: distinct rawptr // opaque TidyDoc; release with Release
// tidyplatform.h defines Bool as enum { no, yes }, NOT C99 _Bool.
Bool :: enum c.int {
	No  = 0,
	Yes = 1,
}

@(default_calling_convention = "c", link_prefix = "tidy")
foreign tidy {
	Create :: proc() -> Doc ---
	Release :: proc(doc: Doc) ---
	OptParseValue :: proc(doc: Doc, option: cstring, value: cstring) -> Bool ---
	ParseString :: proc(doc: Doc, html: cstring) -> c.int ---
	CleanAndRepair :: proc(doc: Doc) -> c.int ---
	// size is input capacity / output byte count. Output is NOT NUL-terminated.
	// Returns -ENOMEM when the buffer is too small; retry with the reported size.
	SaveString :: proc(doc: Doc, buffer: cstring, size: ^c.uint) -> c.int ---
}
