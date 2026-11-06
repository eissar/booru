# Phase 1: commutative patches and LWW-only overwrites

## Contract

- `patch` accepts only non-LWW operations. Field-specific reducers must be associative and commutative.
- `overwrite` accepts only LWW fields and records replacement assignments. Omitted keys remain unchanged; explicit empty/zero values are assignments.
- Field ownership is disjoint: `mtime`, `added_at`, `name`, `comment`, and tag membership belong to commutative patches and cannot be assigned by `overwrite`. The remaining item value fields (`oid`, `path`, `ext`, `content_type`, `width`, and `height`) belong to LWW overwrites and cannot be changed by `patch`.
- Replay has two passes: first reduce commutative operations in parallel and collect overwrite events; then apply overwrites sequentially in authoritative log order.
- Among overwrites, the last assignment to each LWW field wins. There is no overwrite-versus-patch precedence: they operate on disjoint fields.
- Item creation remains once ever per ID. Preserve lifecycle handling and final filtering of deleted items; do not treat creation as an ordinary commutative patch.
- Writers validate against current state, append first, then apply. Live application and full rebuild must agree with the two-pass semantics, including edits after an overwrite.
- The declarative event contract is independent of the projection backend.

## Step 1: `mtime` / `added_at`

- [x] Define patch values as upward-only timestamp advances, reduced by `max(current, incoming)`.
- [x] Reject or omit redundant advances; earlier timestamps must not lower a value through `patch`.
- [x] Preserve creation values as reduction seeds.
- Timestamp lowering/clearing is intentionally unsupported by this max-only contract, including through `overwrite`. If required, revise the timestamp reducer or move the field wholly to LWW; do not introduce a second operation assigning the same field.

## Step 2: `name`

- [x] Replace name assignments in patches with UTF-8 byte XOR deltas computed from the immediately preceding state.
- [x] Compute each delta over `max(old_byte_length, new_byte_length)`, treating absent bytes as zero.
- [x] Grow the byte accumulator as needed; remove trailing zero padding only at finalization.
- [x] Define the encoded payload and validate the final encoded record size before append.
- Payload: `name_xor` is the lowercase hex of the UTF-8 byte XOR (length `max(old, new)`, absent bytes zero). Unchanged values are omitted, and an unchanged name emits no event. Add events keep `name` as the plain seed; patches may not carry `name`.
- Replay keeps a per-item accumulator at its full historical extent, XORs the stored seed in at the end, then trims trailing zero padding to determine the final length. Writers (`name_delta`) derive deltas from the current projected name, including clears (a present empty `name` form key), and reject invalid UTF-8; the record-size check runs before append.
- Replay now decodes `\uD83D\uDE00` surrogate pairs correctly, so seed names with non-BMP characters keep exact bytes.

## Step 3: `comment`

- [x] Choose and document the comment delta representation before implementation: Pijul-inspired anchored line diff patch representation (`slop-pijul`).
- [x] Compare direct XOR's historical high-water memory and shifted-suffix cost against patch representations using representative comments.
- Representation:
  - Wire format in event log is a human-readable, context-anchored patch in the `"comment"` field.
  - Replaces absolute line indices with adjacent context anchors (`@@ <anchor> @@`), deleted lines (`- <line>`), and added lines (`+ <line>`).
  - Implemented cleanly in native Odin in package `src/slop_pijul/`.
  - Commutative across distinct context anchors: edits at different positions in the document commute without shifting absolute coordinates.
  - Projection stores final reconstructed text in `items.comment TEXT NOT NULL` without requiring new database tables.
- [x] Keep comment replacement assignments out of `patch`; compute deltas from validated preceding state.
- [x] Support exact text reconstruction, including empty comments, repeated lines, whitespace, line endings, and multibyte UTF-8.
- [x] Reduce anchored line patches commutatively during stream walk, and resolve final text at finalization.

## Step 4: `overwrite`

- [x] Add the distinct `overwrite` operation and enforce per-operation allowed keys in writers and replay.
- [x] Allow replacement assignments only for `oid`, `path`, `ext`, `content_type`, `width`, and `height`. Reject commutative fields, XOR payloads, and changes to item identity or lifecycle.
- [x] Reject LWW field updates in `patch`; route their writers through `overwrite`. A user edit touching both field classes emits distinct operations, each validated before append.
- [ ] Distinguish omitted values from explicit empty strings and zero values.
- [ ] Route original replacement through overwrite, retaining its expected-current-version/content-hash conflict check.
- [x] Implement the two-pass replay contract: parallel commutative reduction, followed by sequential overwrites in authoritative log order.
- [x] Ensure live application uses the same disjoint field ownership as replay; later patches remain effective on commutative fields regardless of intervening overwrites.
- [x] Verify live application, sequential reference reduction, parallel partition reduction, and full rebuild agree.

## Step 5: explicit clears and value presence

- [ ] Replace empty/zero-as-absent writer handling with explicit field presence for editable values. Omission means unchanged; a supplied empty/zero value is an intentional edit where the field contract permits it.
- [ ] Allow `name` and `comment` to become empty through their byte/length XOR deltas (or the chosen comment representation), not through overwrite assignments. Compute clears from validated current state and omit unchanged inputs.
- [ ] Preserve tag clearing as an explicit empty desired membership, converted to membership XOR deltas; omitted tags remain unchanged.
- [ ] Allow explicit empty strings and numeric zeros on LWW fields through `overwrite`, subject to field validity constraints. Do not permit invalid original references or bypass original-replacement conflict checks.
- [ ] Define nullability explicitly before accepting JSON `null`: current string/integer fields do not represent a distinct nil state. Reject null for non-nullable fields rather than treating it as omission, empty, or zero. Any genuinely nullable field requires a presence-aware event representation, projection support, and a defined reducer before nil assignments are enabled.
- [ ] Keep timestamps upward-only: zero is not a timestamp reset, and clearing/lowering remains unsupported.

## Completion checks

- [ ] No replacement assignments remain in `patch`, and no commutative fields are accepted by `overwrite`.
- [ ] Existing tag membership semantics remain unchanged.
- [ ] Every committed XOR delta is processed exactly once; duplicate delivery remains explicitly unsafe.
- [ ] Encoded events remain smaller than 2,048 bytes and oversized writes fail before append.
- [ ] Run relevant tests and formatting checks without unrelated changes.
