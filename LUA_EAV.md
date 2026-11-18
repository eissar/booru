# Lua EAV (Custom Metadata Plugin Architecture)

Design notes for extensible, plugin-owned metadata (EAV) with a strict boundary between **Core** and **Plugins**.

- **Native Odin plugins** (e.g. `perceptual_hash`) call the Core registration and EAV API directly in Odin—no Lua involved.
- **Lua EAV (deferred):** Future Lua plugins (`lua/*.lua` / `handlers.lua`) will bind to the exact same Core registration and EAV API without any schema or inspector changes.

---

## 1. Core vs. Plugin Boundary

### What Core Owns (`store`, `template`, `server`)

Core knows nothing about `perceptual_hash` or any specific plugin. It only owns the generic EAV storage, display configuration, and rendering/hook dispatch.

1. **Static Schema (`src/store/store.odin`)**

   In `create_tables`:

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
   ```

   In `create_indexes`:

   ```sql
   CREATE INDEX IF NOT EXISTS custom_metadata_by_name_value
       ON custom_metadata(name, value, item_id);
   ```

   This single static index supports fast reverse lookups by `(name, value)` for any plugin without per-plugin DDL changes.

2. **Fixed Store API (`src/store/`)**

   Because the schema is static, Core can use normal prepared statements and `sqlite.step_scan`:

   - `register_custom_metadata(db, name, display_name, inspector)` — upserts into `custom_metadata_display`:
     ```sql
     INSERT INTO custom_metadata_display (name, inspector, display_name)
     VALUES (?1, ?2, ?3)
     ON CONFLICT(name) DO UPDATE SET
         inspector    = excluded.inspector,
         display_name = excluded.display_name;
     ```
   - `set_custom_metadata(db, item_id, name, value)` — upserts into `custom_metadata`:
     ```sql
     INSERT INTO custom_metadata (item_id, name, value)
     VALUES (?1, ?2, ?3)
     ON CONFLICT(item_id, name) DO UPDATE SET
         value = excluded.value;
     ```
   - `get_custom_metadata(db, item_id, name)`
   - `find_items_by_custom_metadata(db, name, value)`
   - `read_inspector_custom_metadata(db, item_id, alloc)` — joins `custom_metadata` with `custom_metadata_display` where `inspector = 1`.

3. **Inspector Rendering (`src/template/inspector.odin`)**

   `render_inspector` iterates over the `[]Custom_Field` returned by `read_inspector_custom_metadata` and renders each via `write_detail_row` (or an optional registered render proc, falling back to `write_detail_row` by default).

4. **Plugin Hooks & Strategy Registry**

   Core exposes a small registration surface (e.g. startup/ingest hooks, optional renderers, optional route overrides) where re-registering the same `name` implicitly overrides the previous registration.

---

### What a Plugin Owns

#### Native Odin Plugin (e.g. `perceptual_hash`)

1. **Registers at startup** (wired in `main.odin` or a plugin init list):
   - Calls `register_custom_metadata(db, "perceptual_hash", "Perceptual Hash", inspector = false)`.
   - Registers its lifecycle hook (e.g. compute on ingest, backfill missing rows on startup) and any optional endpoints.
2. **Reads/writes only via Core's EAV API**:
   - Computes the hash from `images/<id>.<ext>`.
   - Calls `set_custom_metadata(db, item.id, "perceptual_hash", hash_hex)`.
   - Queries matches via `find_items_by_custom_metadata(db, "perceptual_hash", hash_hex)`.

#### Deferred: Lua EAV Plugins

Once Lua plugin loading (`lua/*.lua` in `src/server/lua_handle.odin`) is expanded beyond request overrides:
- Expose `register_custom_metadata`, `set_custom_metadata`, `get_custom_metadata`, and `find_items_by_custom_metadata` to the Lua state.
- Lua scripts can register their own EAV keys, populate values, and opt into `inspector = true` display without touching Odin or SQLite DDL.

---

## 2. Interaction with Existing Codebase Patterns

- **Schema verification (`src/store/schema.odin`, `src/replay/replay.odin`)**:
  `verify_table_columns` and `SCHEMA_MISMATCH` only need to check the static columns of `custom_metadata` (`item_id`, `name`, `value`) and `custom_metadata_display` (`name`, `inspector`, `display_name`). Plugins never run `ALTER TABLE` or mutate Core DDL.
- **Event log vs. derived data (`src/event_log/`, `src/replay/`)**:
  SQLite is a rebuildable projection of the event log:
  - **Derived metadata** (like `perceptual_hash`, recomputable from `images/<id>.<ext>`): safe to store only in `custom_metadata` and recompute/backfill if the DB is rebuilt.
  - **Authoritative/user-edited metadata**: if it must survive a DB rebuild from `events/`, it must also be recorded in the event log and applied during `replay`.
- **Disabling/removing a plugin**:
  Unwiring a native plugin in `main.odin` (or removing a Lua script) leaves Core compiling and running cleanly; existing rows in `custom_metadata` remain inert.
