# Test issues

Open issues found while adding `/merge` (5c900ed) and moving e2e HTTP to libcurl (9e3c97e).

## Harness

- [ ] **Listener double close.** In `test/library_lifecycle.odin` and `test/mipmap.odin`, the shutdown `defer` closes `sock` and sets `sock = {}`. The earlier `defer net.close(sock)` then calls `close(0)`, which can close another parallel test's file descriptor. Fix: `defer if sock != 0 {net.close(sock)}`. Also tracked in `TODO.md`.
- [ ] **Weaker unix-socket check.** `unix_socket_serves_request` used to check the raw `HTTP/1.1 200` status line. Now it checks only the status code from `test_http`.

## Coverage

- [ ] **Multi-source `/merge` untested.** The lifecycle e2e test merges a single source, because only 2 items remain after its delete. Nothing covers:
  - `from=a,b` folding in order
  - skipping a source comment the target already contains
  - the `DEV_ROUTES` `sample=1` shortcut

  The unit test that covered these was removed when the test moved to e2e.
- [ ] **`/duplicates` untested.** It has no handler test and no HTML fixture, so the page's switch to `POST /merge` is not covered.

## Replay and store (from the tag/name review)

- [ ] **Incremental replay cannot clear `name` or `comment`.** In `src/replay/replay.odin:289-290`, `force_write_item` gets `nil` for an empty name or comment, which means "unchanged". So `/update-metadata` with `name=` keeps the old name until a full replay. Confirmed in code but not covered by a test. The related test item is in `TODO.md`.
- [ ] **Incremental replay may skip the lifecycle check (unconfirmed).** It does not run `lifecycle_step`, so a tag patch on a deleted or unknown id may go straight to `toggle_tags` instead of `BadEvent`. Check against `delete_item` and the `item_tags` schema.
- [ ] **`bench/import-tags` panics on empty tags.** `len(ev.tags_xor[0])` panics when an event has no tags.
- [ ] **`swap_write` truncates lengths (`src/replay/lru_cache.odin`).** Name, comment, and word counts are written as `u16`, so lengths over 65535 truncate silently.

## Stale references

- `src/vendor/WINDOWS.md:126` and `src/vendor/tidy/README.md:84` name `import_browse_delete_replay`, which is now `import_browse_delete_merge_replay`. Both are records of past runs.
