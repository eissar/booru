package replay_bench

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

EVENTS_PATH :: ".test-data/events-epoch-100k.ndjson"
EVENTS_COUNT :: 100_000

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

// Generates EVENTS_COUNT `add` events once; reuses the file afterwards.
ensure_events_file :: proc() -> bool {
	// tests run in parallel; only one may write the file
	sync.guard(&events_mu)
	if os.exists(EVENTS_PATH) {return true}
	adjectives := [?]string {
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
	extras := [?]string {
		"at dawn",
		"in winter",
		"from above",
		"after rain",
		"at night",
		"in bloom",
		"under fog",
		"at noon",
		"in autumn",
		"by the sea",
	}
	tags := [?]string {
		"lorem",
		"ipsum",
		"dolor",
		"sit",
		"amet",
		"consectetur",
		"adipiscing",
		"elit",
		"sed",
		"eiusmod",
	}
	formats := [?][2]string {
		{"jpg", "image/jpeg"},
		{"png", "image/png"},
		{"webp", "image/webp"},
		{"avif", "image/avif"},
	}

	if err := os.mkdir_all(".test-data", os.Permissions_Default_Directory);
	   err != nil && err != .Exist {
		return false
	}
	tmp_path := EVENTS_PATH + ".tmp"
	file, open_err := os.open(tmp_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {return false}
	defer os.close(file)

	rng: u64 = 0xB00
	base_ms: i64 = 1_577_836_800_000 // 2020-01-01
	span_ms :: 6 * 365 * 86_400_000
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	for id in 1 ..= EVENTS_COUNT {
		f := formats[rand_below(&rng, len(formats))]
		added := base_ms + i64(rand_below(&rng, span_ms))
		mtime := added - i64(rand_below(&rng, 86_400_000))
		digest: [sha2.DIGEST_SIZE_256]u8
		sha_ctx: sha2.Context_256
		sha2.init_256(&sha_ctx)
		sha2.update(&sha_ctx, transmute([]u8)fmt.tprintf("oid-%d", id))
		sha2.final(&sha_ctx, digest[:])
		oid_hex := hex.encode(digest[:], context.temp_allocator)
		fmt.sbprintf(
			&b,
			`{{"added_at":%d,"content_type":"%s","ext":"%s","height":%d,"id":%d,"mtime":%d,"name":"%s %s %s #%d","oid":"%s","op":"add","path":"","tags":[`,
			added,
			f[1],
			f[0],
			64 + rand_below(&rng, 4032),
			id,
			mtime,
			adjectives[rand_below(&rng, len(adjectives))],
			nouns[rand_below(&rng, len(nouns))],
			extras[rand_below(&rng, len(extras))],
			id,
			string(oid_hex),
		)
		first := rand_below(&rng, len(tags))
		for k in 0 ..< rand_below(&rng, 4) {
			if k > 0 {strings.write_byte(&b, ',')}
			fmt.sbprintf(&b, `"%s"`, tags[(first + k) % len(tags)])
		}
		fmt.sbprintf(&b, `],"width":%d}}`, 64 + rand_below(&rng, 4032))
		strings.write_byte(&b, '\n')
		if strings.builder_len(b) >= 1 << 20 {
			if _, err := os.write(file, b.buf[:]); err != nil {return false}
			strings.builder_reset(&b)
			free_all(context.temp_allocator)
		}
	}
	if _, err := os.write(file, b.buf[:]); err != nil {return false}
	if os.sync(file) != nil {return false}
	return os.rename(tmp_path, EVENTS_PATH) == nil
}
