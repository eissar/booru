package plugin

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "core:time"

import "../library"
import "../vendor/sqlite"

// Note: NativePlugin covers SQLite-backed derived plugins only;
// event-producing plugins (appending to event_log) are deferred / unimplemented.
ColumnSpec :: struct {
	name:         string,
	sql_type:     string, // "BLOB", "TEXT", "INTEGER", "REAL"
	display_name: string, // "" => hidden from inspector
}

NativePlugin :: struct {
	name:    string,
	columns: []ColumnSpec,
	run:     proc(s: ^library.State, alloc: mem.Allocator) -> (processed: int, ok: bool),
}

// register ensures declared plugin columns exist on items.
register :: proc(s: ^library.State, plugins: []NativePlugin) -> bool {
	if s == nil || s.data_store == nil {return false}
	for p in plugins {
		for col in p.columns {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			check_stmt: ^sqlite.Stmt
			if sqlite.prepare_v2(
				   s.data_store,
				   "SELECT name FROM pragma_table_info('items') WHERE name = ?1",
				   -1,
				   &check_stmt,
				   nil,
			   ) !=
			   sqlite.OK {
				log.debugf("plugin %s: failed to check column %s", p.name, col.name)
				return false
			}
			col_cstr := strings.clone_to_cstring(col.name, context.temp_allocator)
			bind_rc := sqlite.bind_text(check_stmt, 1, col_cstr, -1, sqlite.TRANSIENT)
			has_col := bind_rc == sqlite.OK && sqlite.step(check_stmt) == sqlite.ROW
			sqlite.finalize(check_stmt)
			if bind_rc != sqlite.OK {
				log.debugf("plugin %s: failed to bind column %s", p.name, col.name)
				return false
			}
			if has_col {continue}

			alter_sql := strings.clone_to_cstring(
				fmt.tprintf("ALTER TABLE items ADD COLUMN %s %s", col.name, col.sql_type),
				context.temp_allocator,
			)
			alter_stmt: ^sqlite.Stmt
			tail: cstring
			if sqlite.prepare_v2(s.data_store, alter_sql, -1, &alter_stmt, &tail) != sqlite.OK ||
			   (tail != nil && len(tail) > 0) {
				if alter_stmt != nil {sqlite.finalize(alter_stmt)}
				log.debugf("plugin %s: failed to register column %s", p.name, col.name)
				return false
			}
			step_rc := sqlite.step(alter_stmt)
			sqlite.finalize(alter_stmt)
			if step_rc != sqlite.DONE {
				log.debugf("plugin %s: failed to register column %s", p.name, col.name)
				return false
			}
		}
	}
	return true
}

// run executes each plugin's batch runner inside a caller-owned transaction.
run :: proc(s: ^library.State, plugins: []NativePlugin, alloc: mem.Allocator) -> bool {
	if s == nil || s.data_store == nil {return false}
	all_ok := true
	for p in plugins {
		if p.run == nil {continue}
		Payload :: struct {
			p:         NativePlugin,
			s:         ^library.State,
			alloc:     mem.Allocator,
			processed: int,
			ok:        bool,
		}
		payload := Payload {
			p     = p,
			s     = s,
			alloc = alloc,
		}
		p_start := time.now()
		rc := sqlite.with_transaction(
			s.data_store,
			&payload,
			proc(_: ^sqlite.Tx, ctx: ^Payload) -> c.int {
				ctx.processed, ctx.ok = ctx.p.run(ctx.s, ctx.alloc)
				return sqlite.OK if ctx.ok else sqlite.ERROR
			},
		)
		if rc != sqlite.OK || !payload.ok {
			log.debugf("plugin %s: run failed (rc=%d)", p.name, rc)
			all_ok = false
		} else {
			log.debugf(
				"plugin %s: processed=%d in %.2f ms",
				p.name,
				payload.processed,
				time.duration_milliseconds(time.since(p_start)),
			)
		}
	}
	return all_ok
}
