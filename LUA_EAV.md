# Lua EAV (Custom Metadata Plugin Architecture)

Design notes for extensible, plugin-owned metadata with a strict boundary between **Core** and **Plugins**:

- **Native Odin plugins (landed in `src/plugin/`)** — e.g. `src/plugin/phash`: declare typed columns directly on `items` via `plugin.ColumnSpec` + `plugin.NativePlugin` (`plugin.register` / `plugin.run`). No EAV, no Lua.
- **Lua EAV (deferred):** Future Lua plugins (`lua/*.lua` / `handlers.lua`) will use a 3-column EAV table (`custom_metadata`) + `custom_metadata_display` managed by Core.

---

## 1. Native Odin Plugins (`src/plugin/`)

Native plugins are compiled into the binary and declare their `items` columns statically:

- `plugin.ColumnSpec` (`name`, `sql_type` in `BLOB | TEXT | INTEGER | REAL`, optional `display_name`).
- `plugin.register` ensures declared columns exist on `items` via `pragma_table_info('items')` + `ALTER TABLE` (and verifies `sql_type` on restart).
- `plugin.run` executes each plugin's `run(s, alloc)` inside `sqlite.with_transaction`.
- `verify_table_columns` (`src/store/schema.odin`) checks only the required core subset on `items`, so plugin-added columns do not trigger `SCHEMA_MISMATCH`.

---

## 2. Deferred: Lua EAV (`custom_metadata`)

When Lua plugin loading (`src/server/lua_handle.odin`) is expanded beyond request overrides, Core will own a static 3-column EAV schema strictly for Lua plugins:

```sql
CREATE TABLE IF NOT EXISTS custom_metadata (
    item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    name    TEXT NOT NULL,
    value   TEXT NOT NULL,
    PRIMARY KEY (item_id, name)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS custom_metadata_display (
    name         TEXT PRIMARY KEY,
    inspector    INTEGER NOT NULL DEFAULT 0, -- 0/1 boolean
    display_name TEXT NOT NULL
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS custom_metadata_by_name_value
    ON custom_metadata(name, value, item_id);
```

### Core EAV API (to expose to Lua later)

- `register_custom_metadata(db, name, display_name, inspector)` — upserts into `custom_metadata_display`.
- `set_custom_metadata(db, item_id, name, value)` — upserts into `custom_metadata`.
- `get_custom_metadata(db, item_id, name)`
- `find_items_by_custom_metadata(db, name, value)`
- `read_inspector_custom_metadata(db, item_id, alloc)` — joins `custom_metadata` with `custom_metadata_display` where `inspector = 1`, rendered by `src/template/inspector.odin`.

---

## 3. Event Log vs. Derived Data

SQLite is a rebuildable projection of `events/*.ndjson`:

- **Derived data** (like `phash`'s `pdq` column, recomputable from `thumbnails/128/<oid>.webp`): safe to store only in SQLite and recompute on backfill after a DB rebuild.
- **Authoritative/user-edited metadata**: if it must survive a DB rebuild from `events/`, it must be recorded in the event log and applied during `replay`.
