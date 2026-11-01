# Events and replay

## Contract

- The NDJSON log is authoritative and declarative. Storage is a disposable, pluggable projection; SQLite is currently rebuilt on startup.
- Tag membership supports out-of-order and partitioned reduction. Item lifecycle and scalar metadata still require log order; whole events are not commutative.
- Writers must validate edits against the immediately preceding state and transform them before append. Append first; recover a failed projection apply from the log before accepting further state-dependent writes.
- Replay must process each committed event exactly once. Idempotency is not required. Revisions or timestamps alone do not make events commutative.
- Event boundaries and completion rules belong to the log, not SQLite transactions. One inspector update can remain one event.
- The flat parser accepts scalars and arrays of scalars, not nested objects. ASCII-escaped encoded records must be smaller than 2,048 bytes.
- The prototype format changes directly. Old additive `tags` logs are unsupported and must be discarded; there is no migration or compatibility reader.

## Tag membership

`add` and `patch` events use `tags_xor`: a flat array of unique, normalized tag keys. Each key flips membership once. Initial tags toggle from empty. A rename toggles the old key off and the new key on.

Metadata forms submit desired membership. The writer computes the symmetric difference with current membership. A missing tags field leaves membership alone; an explicit empty value clears it. Unchanged membership emits no tag delta, and a wholly unchanged edit emits no event.

The server handles writes synchronously; import finishes before serving. Each writer appends first, then applies metadata and membership toggles in one SQLite transaction. An uncertain append or failed projection apply stops the process; startup rebuild must succeed before further writes.

Replay scans sorted shards once, applying metadata in order and collecting tag-toggle rows in a flat array. After the complete scan, it sorts rows by `(item_id, tag)` and keeps keys occurring an odd number of times. Only surviving items receive final tag rows. There is no parity map or parallel scheduler. Reduced partitions merge by sorted symmetric difference, not union.

Item IDs cannot be reused. Replay tracks creation IDs and seeds allocation above the historical maximum, including deleted items. Events must be processed exactly once: duplicate delivery flips membership again.

https://github.com/eissar/booru/issues/17

## Remaining work

- [ ] Replace `Scan.seen_ids: map[int]bool` and replay-side `seed_ids_from_library` with `INTEGER PRIMARY KEY AUTOINCREMENT` on `items` (`sqlite_sequence`) + SQLite liveness checks:
  - Seed `Id_Giver` in `main.odin` from `SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'items'), 0)` so deleted high-water IDs survive across restarts and future incremental replays without replay mutating global state.
  - Drop `seen_ids` from replay: rely on `PRIMARY KEY` + monotonic `item.id > scan.max_id` (or `sqlite_sequence`) to reject duplicate/resurrected IDs on `add`, and `sqlite.changes64(tx.db) == 0` on `patch`/`delete` to reject unknown or deleted IDs.
- [ ] Define required fields, absent versus empty/zero values, clear semantics, and item lifecycle. Harden parser validation and boundaries with tests/fuzzing.
  - Decided: absent scalar in a patch means unchanged. Explicit `""` fails replay with `NotImplemented`; clearing waits for the comment structure change.
  - [ ] Integer zero is not absent: Odin `json` `omitempty` still emits `0` for ints, so every patch carries `width`/`height`/`mtime`/`added_at` = 0 and `patch_item` relies on `NULLIF(?, 0)`. Omit zero ints at encode time, then make explicit `0` `NotImplemented` on replay and drop the zero tolerance for `delete`/`regen_thumbnail`.
  - [ ] Require `oid`, `path`, `content_type` on `add` (writer and replay). Blocked: Eagle import never sets `path`; unknown formats give empty `content_type`.
  - [x] Reject fields other than `op`, `id`, `version` on `delete` and `regen_thumbnail`. Replay tolerates integer `0` until zeros are omitted.
  - [x] Replay: reject `regen_thumbnail` for unknown or deleted IDs, like `patch`/`delete`.
  - [x] Reject unknown keys on replay. Duplicate keys already fail in `parse_flat` (panic; see corrupt-record handling).
  - [ ] Reject negative `width`, `height`, `mtime`, `added_at` in writer and replay.
  - [ ] Decide whether a patch with no fields besides `id` is invalid on replay (writers never emit one).
  - [ ] Move per-op field rules into `validate_events` so every writer shares them; `encode_event` checks only tags and size.
  - [ ] Drop `NULLIF` in `patch_item` once empty values cannot reach it.
  - [ ] Fuzz `parse_flat`/`parse_item`; malformed input currently panics instead of returning an error.
- [ ] Define incomplete/corrupt-record handling and replay progress. Unknown operations already fail replay.
- [ ] Implement incremental replay: advance each shard cursor in the same projection transaction as its state changes.
- [x] Keep batch transactions for replay/import and reduce tags before final insertion.
- [x] Test shuffled and partitioned tag reduction against sequential replay.

## Rebuild performance

Defer secondary indexes (`items_added_at`, `item_tags_by_tag`) and FK validation until after bulk loading; then create indexes and run `PRAGMA foreign_key_check`. Keep indexes and FKs for live handlers.

A 1.2M-event probe took ~2.4 s versus ~10.9 s with indexes maintained per insert. Use WAL + `synchronous=OFF` only on a disposable temporary DB verified before publication.

Probe: `/var/tmp/lfs-booru-odin-probe/`. Notes: pi sessions under `--srv-code-lfs-booru--`, 2026-10-18. Benchmark instructions: `bench/README.md`.

Checkpoints can reduce repeated work, but a full rebuild requires history or a retained, trusted checkpoint.
