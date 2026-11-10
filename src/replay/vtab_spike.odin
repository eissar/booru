package replay

import "base:intrinsics"
import "base:runtime"
import "core:c"

import "../library"
import "../vendor/sqlite"

// vtab_insert_items bulk inserts full replay items from swap and lww_items into the items table
// using an eponymous-only virtual table scan in a single SQLite statement.
vtab_insert_items :: proc(
	db: ^sqlite.DB,
	swap: ^Swap_Store,
	lww_items: ^map[int]library.Image,
	seen_ids: ^map[int]Item_Status,
) -> c.int {
	Items_VTab :: struct {
		base:      sqlite.VTab,
		cursor:    sqlite.VTab_Cursor,
		swap:      ^Swap_Store,
		lww_items: ^map[int]library.Image,
		seen_ids:  ^map[int]Item_Status,
		id:        int,
		row:       library.Image,
		deleted:   i64,
	}

	advance :: proc "contextless" (tab: ^Items_VTab) {
		for tab.id += 1; tab.id <= tab.swap.max_id; tab.id += 1 {
			off := int(tab.swap.index[tab.id])
			if off == 0 {continue}
			status := tab.seen_ids[tab.id]
			if status == .Absent {continue}

			src := tab.swap.ptr[off:]
			mtime := (^i64)(&src[0])^
			added_at := (^i64)(&src[8])^
			pos := 16

			n_len := int((^u16)(&src[pos])^)
			pos += 2
			name_bytes := src[pos:pos + n_len]
			pos += n_len
			for n_len > 0 && name_bytes[n_len - 1] == 0 {n_len -= 1}

			c_len := int((^u16)(&src[pos])^)
			pos += 2
			comment := string(src[pos:pos + c_len])

			row := tab.lww_items[tab.id]
			row.id = tab.id
			row.name = string(name_bytes[:n_len])
			row.comment = comment
			if mtime > 0 {row.mtime = mtime}
			if added_at > 0 {row.added_at = added_at}

			tab.row = row
			tab.deleted = status == .Deleted ? 1 : 0
			return
		}
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
			tab := cast(^Items_VTab)pCursor.pVTab
			tab.id = 0
			advance(tab)
			return sqlite.OK
		},
		xNext = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			advance(cast(^Items_VTab)pCursor.pVTab)
			return sqlite.OK
		},
		xEof = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			return tab.id > tab.swap.max_id ? 1 : 0
		},
		xColumn = proc "c" (pCursor: ^sqlite.VTab_Cursor, pCtx: rawptr, col: c.int) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			item := tab.row
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
				sqlite.result_int64(pCtx, tab.deleted)
			}
			return sqlite.OK
		},
		xRowid = proc "c" (pCursor: ^sqlite.VTab_Cursor, pRowid: ^i64) -> c.int {
			tab := cast(^Items_VTab)pCursor.pVTab
			pRowid^ = i64(tab.row.id)
			return sqlite.OK
		},
	}

	tab := Items_VTab {
		swap      = swap,
		lww_items = lww_items,
		seen_ids  = seen_ids,
	}
	rc := sqlite.create_module(db, "vtab_items", &module, &tab)
	if rc != sqlite.OK {return rc}

	stmt, ok := sqlite.prepare(db, "INSERT INTO items SELECT * FROM vtab_items")
	if !ok {return 1}
	defer sqlite.finalize(stmt)

	rc = sqlite.step(stmt)
	return rc == sqlite.DONE ? sqlite.OK : rc
}

// vtab_insert_item_tags bulk inserts full replay item tags from swap slots into the item_tags table
// using an eponymous-only virtual table scan in a single SQLite statement.
vtab_insert_item_tags :: proc(
	db: ^sqlite.DB,
	swap: ^Swap_Store,
	seen_ids: ^map[int]Item_Status,
	dictionary: ^[dynamic]string,
) -> c.int {
	Tags_VTab :: struct {
		base:       sqlite.VTab,
		cursor:     sqlite.VTab_Cursor,
		swap:       ^Swap_Store,
		seen_ids:   ^map[int]Item_Status,
		dictionary: ^[dynamic]string,
		id:         int,
		words_ptr:  [^]u64,
		words_len:  int,
		word_idx:   int,
		curr_word:  u64,
		tag_idx:    int,
	}

	advance :: proc "contextless" (tab: ^Tags_VTab) {
		for {
			if tab.curr_word != 0 {
				bit := int(intrinsics.count_trailing_zeros(tab.curr_word))
				tab.curr_word &= tab.curr_word - 1
				tab.tag_idx = tab.word_idx * 64 + bit
				return
			}

			for tab.word_idx += 1; tab.word_idx < tab.words_len; tab.word_idx += 1 {
				w := tab.words_ptr[tab.word_idx]
				if w != 0 {
					bit := int(intrinsics.count_trailing_zeros(w))
					tab.curr_word = w & (w - 1)
					tab.tag_idx = tab.word_idx * 64 + bit
					return
				}
			}

			tab.id += 1
			if tab.id > tab.swap.max_id {return}

			off := int(tab.swap.index[tab.id])
			if off == 0 {
				tab.words_len = 0
				continue
			}
			status := tab.seen_ids[tab.id]
			if status == .Absent || status == .Deleted {
				tab.words_len = 0
				continue
			}

			src := tab.swap.ptr[off:]
			pos := 16
			n_len := int((^u16)(&src[pos])^)
			pos += 2 + n_len
			c_len := int((^u16)(&src[pos])^)
			pos += 2 + c_len
			w_len := int((^u16)(&src[pos])^)
			pos += 2

			tab.words_ptr = ([^]u64)(&src[pos])
			tab.words_len = w_len
			tab.word_idx = -1
			tab.curr_word = 0
		}
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
			schema := cstring(`CREATE TABLE x(
				item_id INTEGER,
				tag TEXT
			)`)
			if sqlite.declare_vtab(db, schema) != sqlite.OK {return 1}
			tab := new(Tags_VTab)
			tab^ = (cast(^Tags_VTab)pAux)^
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
			ppCursor^ = &(cast(^Tags_VTab)pVTab).cursor
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
			tab := cast(^Tags_VTab)pCursor.pVTab
			tab.id = 0
			tab.words_len = 0
			tab.word_idx = 0
			tab.curr_word = 0
			advance(tab)
			return sqlite.OK
		},
		xNext = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			advance(cast(^Tags_VTab)pCursor.pVTab)
			return sqlite.OK
		},
		xEof = proc "c" (pCursor: ^sqlite.VTab_Cursor) -> c.int {
			tab := cast(^Tags_VTab)pCursor.pVTab
			return tab.id > tab.swap.max_id ? 1 : 0
		},
		xColumn = proc "c" (pCursor: ^sqlite.VTab_Cursor, pCtx: rawptr, col: c.int) -> c.int {
			tab := cast(^Tags_VTab)pCursor.pVTab
			switch col {
			case 0:
				sqlite.result_int64(pCtx, i64(tab.id))
			case 1:
				sqlite.result_string(pCtx, tab.dictionary[tab.tag_idx])
			}
			return sqlite.OK
		},
		xRowid = proc "c" (pCursor: ^sqlite.VTab_Cursor, pRowid: ^i64) -> c.int {
			tab := cast(^Tags_VTab)pCursor.pVTab
			pRowid^ = i64(tab.id)
			return sqlite.OK
		},
	}

	tab := Tags_VTab {
		swap       = swap,
		seen_ids   = seen_ids,
		dictionary = dictionary,
	}
	rc := sqlite.create_module(db, "vtab_item_tags", &module, &tab)
	if rc != sqlite.OK {return rc}

	stmt, ok := sqlite.prepare(db, "INSERT INTO item_tags SELECT * FROM vtab_item_tags")
	if !ok {return 1}
	defer sqlite.finalize(stmt)

	rc = sqlite.step(stmt)
	return rc == sqlite.DONE ? sqlite.OK : rc
}
