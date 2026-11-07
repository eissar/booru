package replay

import "base:runtime"
import "core:c"

import "../library"
import "../vendor/sqlite"

// vtab_insert_items bulk inserts an array of library.Image rows into the items table
// using an eponymous-only virtual table scan in a single SQLite statement.
vtab_insert_items :: proc(db: ^sqlite.DB, items: []library.Image) -> c.int {
	Items_VTab :: struct {
		base:   sqlite.VTab,
		cursor: sqlite.VTab_Cursor,
		items:  []library.Image,
		i:      int,
	}

	@(static) module := sqlite.Module {
		xConnect = proc "c" (
			db: ^sqlite.DB,
			pAux: rawptr,
			argc: c.int,
			argv: [^]cstring,
			ppVTab: ^^sqlite.VTab,
			pzErr: ^cstring,
		) -> c.int {
			context = runtime.default_context()
			schema := cstring(
				`CREATE TABLE x(
				id INTEGER,
				oid TEXT,
				path TEXT,
				ext TEXT,
				name TEXT,
				comment TEXT,
				content_type TEXT,
				width INTEGER,
				height INTEGER,
				mtime INTEGER,
				added_at INTEGER,
				deleted INTEGER
			)`,
			)
			if sqlite.declare_vtab(db, schema) != sqlite.OK {return 1}
			tab := new(Items_VTab)
			tab^ = (cast(^Items_VTab)pAux)^
			ppVTab^ = &tab.base
			return sqlite.OK
		},
		xBestIndex = proc "c" (_: ^sqlite.VTab, _: rawptr) -> c.int {
			return sqlite.OK
		},
		xDisconnect = proc "c" (pVTab: ^sqlite.VTab) -> c.int {
			context = runtime.default_context()
			free(pVTab)
			return sqlite.OK
		},
		xOpen = proc "c" (pVTab: ^sqlite.VTab, ppCursor: ^^sqlite.VTab_Cursor) -> c.int {
			ppCursor^ = &(cast(^Items_VTab)pVTab).cursor
			return sqlite.OK
		},
		xClose = proc "c" (_: ^sqlite.VTab_Cursor) -> c.int {
			return sqlite.OK
		},
		xFilter = proc "c" (
			pCursor: ^sqlite.VTab_Cursor,
			idxNum: c.int,
			idxStr: cstring,
			argc: c.int,
			argv: [^]rawptr,
		) -> c.int {
			(cast(^Items_VTab)pCursor.pVTab).i = 0
			return sqlite.OK
		},
		xNext = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			(cast(^Items_VTab)pCursor.pVTab).i += 1
			return sqlite.OK
		},
		xEof = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			return tab.i >= len(tab.items) ? 1 : 0
		},
		xColumn = proc "c" (pCursor: ^sqlite.VTab_Cursor, pCtx: rawptr, col: c.int) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			item := tab.items[tab.i]
			switch col {
			case 0:
				sqlite.result_int64(pCtx, i64(item.id))
			case 1:
				sqlite.result_string(pCtx, item.oid)
			case 2:
				sqlite.result_string(pCtx, item.path)
			case 3:
				sqlite.result_string(pCtx, item.ext)
			case 4:
				sqlite.result_string(pCtx, item.name)
			case 5:
				sqlite.result_string(pCtx, item.comment)
			case 6:
				sqlite.result_string(pCtx, item.content_type)
			case 7:
				sqlite.result_int64(pCtx, i64(item.width))
			case 8:
				sqlite.result_int64(pCtx, i64(item.height))
			case 9:
				sqlite.result_int64(pCtx, item.mtime)
			case 10:
				sqlite.result_int64(pCtx, item.added_at)
			case 11:
				sqlite.result_int64(pCtx, 0)
			}
			return sqlite.OK
		},
		xRowid = proc "c" (pCursor: ^sqlite.VTab_Cursor, pRowid: ^i64) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			pRowid^ = i64(tab.items[tab.i].id)
			return sqlite.OK
		},
	}

	tab := Items_VTab {
		items = items,
	}
	rc := sqlite.create_module(db, "vtab_items", &module, &tab)
	if rc != sqlite.OK {return rc}

	stmt, ok := sqlite.prepare(db, "INSERT INTO items SELECT * FROM vtab_items")
	if !ok {return 1}
	defer sqlite.finalize(stmt)

	rc = sqlite.step(stmt)
	return rc == sqlite.DONE ? sqlite.OK : rc
}
