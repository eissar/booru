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
Message :: distinct rawptr // opaque TidyMessage; valid only during the callback
// tidyplatform.h defines Bool as enum { no, yes }, NOT C99 _Bool.
Bool :: enum c.int {
	No  = 0,
	Yes = 1,
}

// tidyenum.h report levels (TidyReportLevel). TidyInfo = 350, then +1 each.
ReportLevel :: enum c.int {
	Info            = 350,
	Warning         = 351,
	Config          = 352,
	Access          = 353,
	Error           = 354,
	BadDocument     = 355,
	Fatal           = 356,
	DialogueSummary = 357,
}

// TidyMessageCallback: return Yes to show the message via tidy's own output.
MessageCallback :: #type proc "c" (msg: Message) -> Bool

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

	// Diagnostics and error reporting.
	RunDiagnostics :: proc(doc: Doc) -> c.int ---
	ErrorCount :: proc(doc: Doc) -> c.uint ---
	WarningCount :: proc(doc: Doc) -> c.uint ---
	SetMessageCallback :: proc(doc: Doc, cb: MessageCallback) -> Bool ---
	GetMessageLevel :: proc(msg: Message) -> ReportLevel ---
	GetMessageLine :: proc(msg: Message) -> c.int ---
	GetMessageColumn :: proc(msg: Message) -> c.int ---
	GetMessageKey :: proc(msg: Message) -> cstring ---
	GetMessage :: proc(msg: Message) -> cstring ---
}
