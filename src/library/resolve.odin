package library

import "core:fmt"
import "core:io"
import "core:os"

Resolve_Status :: enum {
	Ok,
	Not_Found,
	Error,
}

// TODO: Remote/S3 tiers return their own io.Stream (Read_At via range requests) so originals
// are proxied without caching them to disk (originals only resolve on dwell/inspect); add an
// Offline status (-> 503) once a tier can be unreachable.

// TODO(root_id):
// - Add `root_id: int` (omitempty; 0 = managed {library}/images/<id>.<ext>) to Event, Image, and items.
// - Map non-zero `root_id` (1, 2, ...; never reused) to per-machine root URIs (local dir or S3) in roots config.
// - Store relative path (`rel_path`) in `path` and jail local reads under the configured root (no traversal).
// - Distinguish Offline/Unreachable roots (-> 503 / proxy fallback) from Absent files during reconcile/cascade.
// - Pair with `size` + `partial_hash` (== oid when < 128 KB) on Event/items for 4-tier offline move recovery.
// - Once `size` lands, fail resolution when io.size(stream) != img.size (and flag it for reconcile).

// cascade_resolve opens the backing bytes for img across known tiers. On .Ok the caller owns
// `stream` (Read, Read_At, Size, Close) and must io.close it. Content type and size come from
// img, not the stream. Tiers:
// 1. managed original (root_id == 0 -> images/<id>.<ext>)
// 2. external local_ref (root_id + rel_path) [planned]
// 3. remote object (e.g. S3 streamed proxy) [planned]
// 4. local proxy fallback (thumbnails/max/<oid>.webp) [planned]
// TODO: Add a `tiers: bit_set[Resolve_Tier]` param once callers differ: requests stay on
// known locations, thumbnail generation must exclude the proxy fallback (tier 4), and only
// jobs run the full cascade. Report the tier that answered instead of adding a probe flag.
cascade_resolve :: proc(
	s: State,
	img: Image,
	alloc := context.allocator,
) -> (
	stream: io.Stream,
	status: Resolve_Status,
) {
	// 1. Managed local original.
	fp := fmt.aprintf("%s/images/%d.%s", s.library_path, img.id, img.ext, allocator = alloc)
	file, open_err := os.open(fp, {.Read})
	if open_err == nil {return os.to_stream(file), .Ok}
	if open_err != .Not_Exist {return {}, .Error}

	return {}, .Not_Found
}
