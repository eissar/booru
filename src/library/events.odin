package library

import elog "../event_log"

new_add_event :: proc(e: ^elog.Event) {
	// these get set later:
	// e.oid
	// e.path
	// e.content_type
	//
	// we also explicitly validate
	// those are !nil
	// before writes to
	// the event log

	e.op = "add"
	e.id = requestNewId()
}
