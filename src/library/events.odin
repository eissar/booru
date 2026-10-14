package library

new_add_event :: proc(e: ^Event) {
	// these get set later:
	// e.oid
	// e.path
	// e.contentType
	//
	// we also explicitly validate
	// those are !nil
	// before writes to
	// the event log

	e.op = "add"
	e.id = requestNewId()
}
