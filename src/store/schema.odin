package store

import "../vendor/sqlite"
import "core:strings"

TABLE_ITEMS_COLUMNS :: []string {
	"id",
	"oid",
	"path",
	"ext",
	"name",
	"comment",
	"content_type",
	"width",
	"height",
	"mtime",
	"added_at",
	"deleted",
}

TABLE_ITEM_TAGS_COLUMNS :: []string{"item_id", "tag"}

TABLE_REPLAY_CURSORS_COLUMNS :: []string{"shard", "byte_offset"}

// verify_table_columns queries pragma_table_info for table_name and ensures all required columns exist.
verify_table_columns :: proc(
	db: ^sqlite.DB,
	table_name: string,
	required_columns: []string,
) -> bool {
	query := strings.clone_to_cstring(
		strings.concatenate({"SELECT name FROM pragma_table_info('", table_name, "')"}),
		context.temp_allocator,
	)
	stmt: ^sqlite.Stmt
	rc := sqlite.prepare_v2(db, query, -1, &stmt, nil)
	if rc != sqlite.OK {
		return false
	}
	defer sqlite.finalize(stmt)

	found := 0
	for sqlite.step(stmt) == sqlite.ROW {
		name := sqlite.column_string(stmt, 0)
		for req in required_columns {
			if name == req {
				found += 1
				break
			}
		}
	}
	return found == len(required_columns)
}
