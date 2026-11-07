package replay_mixed_bench

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"

@(private = "file")
events_mu: sync.Mutex

// Deterministic generator; same bytes on every run.
@(private = "file")
splitmix64 :: proc(state: ^u64) -> u64 {
	state^ += 0x9E3779B97F4A7C15
	z := state^
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
rand_below :: proc(state: ^u64, n: int) -> int {
	return int(splitmix64(state) % u64(n))
}

MIXED_EVENTS_PATH :: ".test-data/events-mixed.ndjson"
MIXED_ADD_COUNT :: 100_000

// Generates a log with every op (add, patch, overwrite, delete) once; reuses
// the file afterwards. Each add is followed by ~1.15 extra events aimed at
// random live items, so one item's events are spread across the log. Keys are
// written in sorted order, like the add-only fixture.
ensure_mixed_events_file :: proc() -> bool {
	sync.guard(&events_mu)
	if os.exists(MIXED_EVENTS_PATH) {return true}
	words := [?]string {
		"amber",
		"blue",
		"crimson",
		"dusty",
		"eager",
		"faded",
		"gentle",
		"hollow",
		"ivory",
		"jolly",
		"kind",
		"lunar",
		"misty",
		"narrow",
		"opal",
		"pale",
		"quiet",
		"rustic",
		"silent",
		"tidy",
		"umber",
		"vivid",
		"waxen",
		"young",
		"zesty",
	}
	nouns := [?]string {
		"harbor",
		"tower",
		"meadow",
		"lantern",
		"orchard",
		"canyon",
		"bridge",
		"garden",
		"window",
		"river",
		"market",
		"glacier",
		"cabin",
		"island",
		"forest",
		"statue",
		"valley",
		"temple",
		"street",
		"desert",
	}
	suffixes := [?]string{" v2", " edit", "!", " (copy)"}
	formats := [?][2]string {
		{"jpg", "image/jpeg"},
		{"png", "image/png"},
		{"webp", "image/webp"},
		{"avif", "image/avif"},
	}
	// 200 distinct tags from word pairs; tags allow only lowercase letters and hyphens.
	tag_count :: 200
	tag_name :: proc(i: int, words, nouns: []string) -> string {
		return fmt.tprintf("%s-%s", words[i % len(words)], nouns[i / len(words) % len(nouns)])
	}
	// Weighted op choice for the extra events.
	Extra :: enum {
		Tags,
		Name,
		Comment,
		Times,
		Overwrite,
		Delete,
	}
	weights := [Extra]int {
		.Tags      = 30,
		.Name      = 20,
		.Comment   = 20,
		.Times     = 20,
		.Overwrite = 15,
		.Delete    = 9,
	}

	if err := os.mkdir_all(".test-data", os.Permissions_Default_Directory);
	   err != nil && err != .Exist {
		return false
	}
	tmp_path := MIXED_EVENTS_PATH + ".tmp"
	file, open_err := os.open(tmp_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {return false}
	defer os.close(file)

	rng: u64 = 0xB01
	base_ms: i64 = 1_577_836_800_000 // 2020-01-01
	span_ms :: 6 * 365 * 86_400_000
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	// Current names/comments outlive the temp-allocator flushes below.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	keep := mem.dynamic_arena_allocator(&arena)
	names := make([]string, MIXED_ADD_COUNT + 1) // current name, for XOR deltas
	comments := make([]string, MIXED_ADD_COUNT + 1) // current comment; "" means none
	defer delete(names)
	defer delete(comments)
	live := make([dynamic]int)
	defer delete(live)

	oid_of :: proc(salt: string, id: int) -> string {
		digest: [sha2.DIGEST_SIZE_256]u8
		sha_ctx: sha2.Context_256
		sha2.init_256(&sha_ctx)
		sha2.update(&sha_ctx, transmute([]u8)fmt.tprintf("%s-%d", salt, id))
		sha2.final(&sha_ctx, digest[:])
		return string(hex.encode(digest[:], context.temp_allocator))
	}
	write_tags :: proc(b: ^strings.Builder, rng: ^u64, words, nouns: []string) {
		first := rand_below(rng, 200)
		for k in 0 ..< 1 + rand_below(rng, 3) {
			if k > 0 {strings.write_byte(b, ',')}
			fmt.sbprintf(b, `"%s"`, tag_name((first + k) % 200, words, nouns))
		}
	}

	weight_total := 0
	for w in weights {weight_total += w}
	debt := 0
	for id in 1 ..= MIXED_ADD_COUNT {
		f := formats[rand_below(&rng, len(formats))]
		added := base_ms + i64(rand_below(&rng, span_ms))
		mtime := added - i64(rand_below(&rng, 86_400_000))
		names[id] = fmt.aprintf(
			"%s %s #%d",
			words[rand_below(&rng, len(words))],
			nouns[rand_below(&rng, len(nouns))],
			id,
			allocator = keep,
		)
		fmt.sbprintf(&b, `{{"added_at":%d,`, added)
		if rand_below(&rng, 10) < 3 {
			comments[id] = fmt.aprintf(
				"note %d about %s",
				id,
				nouns[rand_below(&rng, len(nouns))],
				allocator = keep,
			)
			fmt.sbprintf(&b, `"comment":"%s",`, comments[id])
		}
		fmt.sbprintf(
			&b,
			`"content_type":"%s","ext":"%s","height":%d,"id":%d,"mtime":%d,"name":"%s","oid":"%s","op":"add","tags":[`,
			f[1],
			f[0],
			64 + rand_below(&rng, 4032),
			id,
			mtime,
			names[id],
			oid_of("oid", id),
		)
		write_tags(&b, &rng, words[:], nouns[:])
		fmt.sbprintf(&b, `],"width":%d}}`, 64 + rand_below(&rng, 4032))
		strings.write_byte(&b, '\n')
		append(&live, id)

		debt += 115
		for debt >= 100 && len(live) > 0 {
			debt -= 100
			// Pick a live item and an op; comment ops need an existing comment, so retry.
			idx: int
			target: int
			op: Extra
			for {
				idx = rand_below(&rng, len(live))
				target = live[idx]
				pick := rand_below(&rng, weight_total)
				for w, e in weights {
					if pick < w {op = e; break}
					pick -= w
				}
				if op != .Comment || comments[target] != "" {break}
			}
			switch op {
			case .Tags:
				fmt.sbprintf(&b, `{{"id":%d,"op":"patch","tags":[`, target)
				write_tags(&b, &rng, words[:], nouns[:])
				strings.write_string(&b, "]}")
			case .Name:
				// XOR delta against the current name: zeros over the shared prefix,
				// then the appended suffix bytes.
				suffix := suffixes[rand_below(&rng, len(suffixes))]
				fmt.sbprintf(&b, `{{"id":%d,"name":"`, target)
				for _ in 0 ..< len(names[target]) {strings.write_string(&b, "00")}
				for c in transmute([]u8)suffix {fmt.sbprintf(&b, "%02x", c)}
				strings.write_string(&b, `","op":"patch"}`)
				names[target] = fmt.aprintf("%s%s", names[target], suffix, allocator = keep)
			case .Comment:
				edited := fmt.aprintf("%s edited", comments[target], allocator = keep)
				// \n stays a JSON escape, not a newline, inside the string.
				fmt.sbprintf(
					&b,
					`{{"comment":"@@  @@\n- %s\n+ %s\n","id":%d,"op":"patch"}`,
					comments[target],
					edited,
					target,
				)
				comments[target] = edited
			case .Times:
				fmt.sbprintf(
					&b,
					`{{"added_at":%d,"id":%d,"mtime":%d,"op":"patch"}`,
					base_ms + i64(rand_below(&rng, span_ms)),
					target,
					base_ms + i64(rand_below(&rng, span_ms)),
				)
			case .Overwrite:
				f := formats[rand_below(&rng, len(formats))]
				fmt.sbprintf(
					&b,
					`{{"content_type":"%s","ext":"%s","height":%d,"id":%d,"oid":"%s","op":"overwrite","width":%d}`,
					f[1],
					f[0],
					64 + rand_below(&rng, 4032),
					target,
					oid_of("ow", target),
					64 + rand_below(&rng, 4032),
				)
			case .Delete:
				fmt.sbprintf(&b, `{{"id":%d,"op":"delete"}`, target)
				live[idx] = live[len(live) - 1]
				pop(&live)
			}
			strings.write_byte(&b, '\n')
		}
		if strings.builder_len(b) >= 1 << 20 {
			if _, err := os.write(file, b.buf[:]); err != nil {return false}
			strings.builder_reset(&b)
			free_all(context.temp_allocator)
		}
	}
	if _, err := os.write(file, b.buf[:]); err != nil {return false}
	if os.sync(file) != nil {return false}
	return os.rename(tmp_path, MIXED_EVENTS_PATH) == nil
}
