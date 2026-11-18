# Job & Startup Concurrency Fixes

Tracked issues from the `src/plugin/` + `src/main.odin` review to address alongside the `progress` / jobs restructure:

1. **`scan_thread` vs `plugin_thread` ordering (`src/main.odin`, `src/plugin/phash/phash.odin`)**
   - `scan_thread` and `plugin_thread` currently start concurrently.
   - `phash.run` skips missing `thumbnails/128/<oid>.webp` (`if !hash_ok {continue}`), so items whose thumbnails haven't been generated yet by `scan_thread` remain `pdq IS NULL` until the next restart.
   - Fix: run thumbnail generation and plugin jobs serially in a single startup worker (or sequence plugin jobs after thumbnail generation completes).

2. **Global `progress` race (`src/main.odin`, `src/progress/progress.odin`)**
   - `progress.current` and `progress.done` are unsynchronized package globals; `main.cb` writes both from `scan_thread` and `plugin_thread` concurrently, and `done` is only ever set to `true`.
   - Fix: restructure `progress` for multi-job / synchronized reporting.

3. **SQLite `busy_timeout` on worker connections (`src/plugin/startup.odin`)**
   - `startup_threaded_run_plugins` opens `store.sqlite` with default 0ms `busy_timeout`, so concurrent writes from `server.Serve` (or `scan_thread`) fail immediately with `SQLITE_BUSY` / `SQLITE_BUSY_SNAPSHOT`.
   - Fix: configure `busy_timeout` / transaction retry policy on background worker connections.

4. **Background threads started before socket bind (`src/main.odin`)**
   - `scan_thread` and `plugin_thread` are started before `listen_unix` / `listen_tcp`. If binding fails and calls `os.exit(1)`, background threads are killed mid-transaction.
   - Fix: bind the listening socket before spawning background worker threads.
