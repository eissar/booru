package plugin

import "core:mem"
import "core:testing"

import "../library"
import "../progress"
import "../vendor/sqlite"

open_test_items_db :: proc(t: ^testing.T) -> ^sqlite.DB {
	db, rc := sqlite.open(":memory:")
	testing.expect_value(t, rc, sqlite.OK)
	exec_rc := sqlite.exec(
		db,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, val TEXT)",
		nil,
		nil,
		nil,
	)
	testing.expect_value(t, exec_rc, sqlite.OK)
	return db
}

@(test)
test_register_adds_columns_idempotently :: proc(t: ^testing.T) {
	db := open_test_items_db(t)
	defer sqlite.close(db)

	s := library.State {
		data_store = db,
	}
	plugins := []NativePlugin {
		{
			name = "alpha",
			columns = {
				{name = "alpha_blob", sql_type = "BLOB"},
				{name = "alpha_note", sql_type = "TEXT", display_name = "Note"},
			},
		},
	}

	testing.expect(t, register(&s, plugins))
	// Second call must be idempotent.
	testing.expect(t, register(&s, plugins))

	stmt: ^sqlite.Stmt
	testing.expect_value(
		t,
		sqlite.prepare_v2(
			db,
			"SELECT COUNT(*) FROM pragma_table_info('items') WHERE name IN ('alpha_blob', 'alpha_note')",
			-1,
			&stmt,
			nil,
		),
		sqlite.OK,
	)
	defer sqlite.finalize(stmt)
	testing.expect_value(t, sqlite.step(stmt), sqlite.ROW)
	testing.expect_value(t, sqlite.column_int64(stmt, 0), 2)
}

@(test)
test_register_rejects_invalid_column_specs :: proc(t: ^testing.T) {
	db := open_test_items_db(t)
	defer sqlite.close(db)

	s := library.State {
		data_store = db,
	}

	bad_cases := [][]NativePlugin {
		{{name = "bad1", columns = {{name = "", sql_type = ""}}}},
		{{name = "bad2", columns = {{name = "1bad", sql_type = "TEXT"}}}},
		{{name = "bad3", columns = {{name = "x; DROP TABLE items", sql_type = "TEXT"}}}},
		{{name = "bad4", columns = {{name = "a, b", sql_type = "TEXT"}}}},
	}
	for plugins in bad_cases {
		testing.expect(t, !register(&s, plugins))
	}
}

@(test)
test_run_commits_and_rolls_back :: proc(t: ^testing.T) {
	db := open_test_items_db(t)
	defer sqlite.close(db)

	s := library.State {
		data_store = db,
	}

	commit_proc :: proc(
		st: ^library.State,
		alloc: mem.Allocator,
		prog_callback: progress.Callback = nil,
	) -> (
		processed: int,
		ok: bool,
	) {
		rc := sqlite.exec(
			st.data_store,
			"INSERT INTO items (id, val) VALUES (1, 'committed')",
			nil,
			nil,
			nil,
		)
		return 1, rc == sqlite.OK
	}

	rollback_proc :: proc(
		st: ^library.State,
		alloc: mem.Allocator,
		prog_callback: progress.Callback = nil,
	) -> (
		processed: int,
		ok: bool,
	) {
		_ = sqlite.exec(
			st.data_store,
			"INSERT INTO items (id, val) VALUES (2, 'rolled_back')",
			nil,
			nil,
			nil,
		)
		return 0, false
	}

	testing.expect(t, run(&s, {{name = "ok_plugin", run = commit_proc}}, context.allocator))
	testing.expect(t, !run(&s, {{name = "fail_plugin", run = rollback_proc}}, context.allocator))

	stmt: ^sqlite.Stmt
	testing.expect_value(
		t,
		sqlite.prepare_v2(db, "SELECT COUNT(*) FROM items", -1, &stmt, nil),
		sqlite.OK,
	)
	defer sqlite.finalize(stmt)
	testing.expect_value(t, sqlite.step(stmt), sqlite.ROW)
	testing.expect_value(t, sqlite.column_int64(stmt, 0), 1)
}
