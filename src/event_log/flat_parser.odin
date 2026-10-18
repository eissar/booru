package event_log

// UNREVIEWED GENERATED CODE
/*
    CONSIDERATIONS:
    The top-level value must be exactly one JSON object. Top-level arrays, strings, numbers, booleans, and null are rejected.

    Objects must be flat. Fields may contain scalars or arrays of scalars. Nested objects and nested arrays panic.

    Arrays may mix scalar types. Enforcing homogeneous arrays is the handler’s responsibility.

    Keys must match [a-z][a-z0-9_]*. They must start with a lowercase ASCII letter and contain only lowercase ASCII letters, digits, and underscores.

    Consecutive and trailing underscores are currently allowed. This is an identifier rule, not strict enforcement of single-underscore-separated words.

    Empty keys, uppercase letters, leading digits, spaces, punctuation other than underscores, and non-ASCII keys are rejected.

    Escapes in keys are forbidden, even when they would decode to an otherwise valid key. For example, "content\u0054ype" is ASCII-encoded valid JSON, but it violates the key rules.

    Event keys must use lower snake_case; thumbnailOid must be changed in writers and development logs before using this parser.

    Invalid keys are rejected rather than normalized. The parser does not lowercase names or replace punctuation.

    Duplicate keys are rejected using exact byte comparison.

    String values must contain ASCII bytes. Non-ASCII characters must be represented using JSON Unicode escapes. Unescaped control characters are rejected.

    ASCII-only does not mean escaped values are decoded. A value containing \u00e9 remains those raw ASCII bytes until the consumer decodes it.

    String escapes are validated but not decoded. Unicode surrogate pairs are checked, and unpaired surrogates are rejected.

    Token text preserves the original JSON spelling. String tokens include surrounding quotes and escape sequences. Number tokens remain text.

    has_escapes records whether a string contains escapes. Unescaped strings can be borrowed after removing their quotes. Escaped strings need decoding when the consumer requires actual text.

    Decoded strings may contain null bytes and control characters. Use explicit lengths when passing them to SQLite or other APIs; do not assume null-terminated C-string semantics.

    Number syntax is validated, but numeric range is not. A valid numeric token may overflow i64 or floating-point storage. Conversion and range checks belong to the consumer.

    Negative numbers are accepted. Whether an ID or dimension may be negative is a schema decision, not a parser decision.

    Fractional and exponent forms are classified as Float, even when mathematically integral. For example, 1e3 is not classified as Integer.

    The parser accepts standard JSON whitespace before, after, and between tokens, including newlines. Enforcing one physical line per NDJSON record belongs to the reader.

    Empty input and whitespace-only input panic. Skipping blank lines is the reader’s responsibility.

    Trailing commas, comments, multiple objects in one record, trailing garbage, NaN, and Infinity are rejected.

    A byte-order mark is rejected. There is no BOM handling.

    The current byte limit is strictly fewer than 2,048 bytes. Exactly 2,048 bytes is rejected. The limit counts encoded bytes, including whitespace and escapes, rather than decoded content.

    Unicode escaping expands records. A Unicode character may require six ASCII bytes, or twelve for a surrogate pair, and reaches the byte limit sooner.

    MAX_RECORD also determines the fixed token-buffer capacity. Increasing it enlarges every Record, even when actual events are small. Separate byte and token limits before substantially increasing it.

    The record-size panic message hardcodes 2048. Changing the constant alone leaves that message incorrect.

    There is no explicit token-capacity check before writing the token array. The current shared byte/token limit leaves ample token capacity, but separating those limits requires an explicit overflow check.

    Field storage uses a dynamic array. Parsing can allocate when its capacity is insufficient. The existing comment claiming no allocator calls is not unconditionally true.

    Reserve field capacity before parsing if allocation-free operation is required within that capacity. Wider records may still trigger growth.

    At each record’s start, clear resets the dynamic field array’s length while retaining capacity. It does not free or zero the backing allocation.

    The caller owns the dynamic field allocation and must free it. The token array is embedded in the Record.

    Keys and token text borrow the input buffer. Modifying, reusing, or freeing that buffer invalidates those views.

    Field.values slices point into the Record’s token array. Parsing another record into the same Record overwrites the previous values.

    The previous record must be fully consumed before the Record or input buffer is reused. Copy any data that must outlive either one.

    Copying a populated Record by value does not produce an independent result. Its slices and dynamic-array header still reference existing storage, creating aliasing and ownership hazards.

    Do not move or resize storage containing populated Records while consumers retain views into their embedded token arrays.

    A Record is not safe for concurrent parsing or concurrent reuse. Each in-flight result needs exclusive output storage and stable input until consumption finishes.

    Duplicate-key detection compares each key against all previous keys. Its cost is quadratic in field count and may become significant for very wide objects.

    There are no independent policies for maximum field count, key length, string length, or array length beyond the overall record limit and available storage.

    The parser is operation-independent. New event operations do not require parser changes if they stay within the supported flat format.

    The parser does not validate event schemas. Unknown keys, unknown operations, missing IDs, inappropriate nulls, and wrong field types may all pass structural parsing.

    Empty objects are accepted, but need not be valid events.

    Operation handlers must enforce required fields, allowed fields, types, numeric ranges, and operation-specific rules.

    The parser does not enforce tag uniqueness, item existence, patch semantics, foreign keys, or other database constraints.

    It does not read files, split NDJSON, assemble partial records, track replay offsets, dispatch events, manage transactions, or persist cursors.

    A buffered reader must retain incomplete records across reads and reject oversized records without unbounded buffer growth.

    When SQLite bindings borrow input or decoded scratch, that memory must remain valid until the binding is cleared, replaced, or finalized. Resetting a statement alone does not release its bindings.

    Parsing failures panic rather than return an error. Continuing with later events after a failure is not a supported recovery path.

    A failed parse can leave partially populated output. Do not treat it as a valid record.

    Errors currently omit filename, record number, byte offset, and offending key. Additional context is needed for practical corruption diagnostics.

    The helper names are generic and live in the event_log package. Names such as next, expect, Token, and Record may collide with other package declarations.

    The parser still depends on core:encoding/json for token-kind definitions, although its byte scanner is custom.

    The parser is a prototype with limited checks exercised so far, not an exhaustively verified implementation. It needs boundary tests, fuzzing, and comparison against a standard parser while accounting for its deliberately stricter format.
*/

import "core:encoding/json"

Token :: struct {
	kind:        json.Token_Kind,
	text:        string,
	has_escapes: bool,
}

// Tokens borrow the input, including quotes/escapes on string values.
// The consumer decodes only values that it actually needs.
Field :: struct {
	key:      string,
	is_array: bool,
	values:   []Token,
}
Record :: struct {
	fields:      [dynamic]Field,
	values:      [MAX_RECORD]Token,
	field_count: int,
	value_count: int,
}

Scanner :: struct {
	data: string,
	pos:  int,
}

hex4 :: proc(t: ^Scanner) -> int {
	value := 0
	for _ in 0 ..< 4 {
		if t.pos >= len(t.data) {panic("Cannot parse event: truncated Unicode escape")}
		b := t.data[t.pos]; t.pos += 1
		digit := -1
		if b >= '0' && b <= '9' {digit = int(b - '0')}
		if b >= 'a' && b <= 'f' {digit = int(b - 'a') + 10}
		if b >= 'A' && b <= 'F' {digit = int(b - 'A') + 10}
		if digit < 0 {panic("Cannot parse event: invalid Unicode escape")}
		value = value * 16 + digit
	}
	return value
}

next :: proc(t: ^Scanner) -> Token {
	for t.pos < len(t.data) {
		b := t.data[t.pos]
		if b != ' ' && b != '\t' && b != '\r' && b != '\n' {break}
		t.pos += 1
	}
	if t.pos == len(t.data) {return Token{kind = .EOF}}
	start := t.pos
	b := t.data[t.pos]; t.pos += 1
	kind: json.Token_Kind
	has_escapes := false
	switch b {
	case '{':
		kind = .Open_Brace
	case '}':
		kind = .Close_Brace
	case '[':
		kind = .Open_Bracket
	case ']':
		kind = .Close_Bracket
	case ':':
		kind = .Colon
	case ',':
		kind = .Comma
	case '"':
		kind = .String
		closed := false
		for t.pos < len(t.data) {
			ch := t.data[t.pos]; t.pos += 1
			if ch == '"' {closed = true; break}
			if ch < 32 ||
			   ch >= 128 {panic("Cannot parse event: expected printable ASCII string bytes")}
			if ch == '\\' {
				has_escapes = true
				if t.pos == len(t.data) {panic("Cannot parse event: truncated escape")}
				esc := t.data[t.pos]; t.pos += 1
				switch esc {
				case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				case 'u':
					cp := hex4(t)
					if cp >= 0xD800 && cp <= 0xDBFF {
						if t.pos + 2 >
						   len(t.data) {panic("Cannot parse event: missing low surrogate")}
						if t.data[t.pos:t.pos +
						   2] !=
						   "\\u" {panic("Cannot parse event: missing low surrogate")}
						t.pos += 2
						low := hex4(t)
						if low < 0xDC00 ||
						   low > 0xDFFF {panic("Cannot parse event: invalid low surrogate")}
					} else if cp >= 0xDC00 &&
					   cp <= 0xDFFF {panic("Cannot parse event: unpaired low surrogate")}
				case:
					panic("Cannot parse event: invalid escape")
				}
			}
		}
		if !closed {panic("Cannot parse event: unterminated string")}
	case 't', 'f', 'n':
		literal := "true"
		kind = .True
		if b == 'f' {literal = "false"; kind = .False}
		if b == 'n' {literal = "null"; kind = .Null}
		end := start + len(literal)
		if end > len(t.data) {panic("Cannot parse event: truncated literal")}
		if t.data[start:end] != literal {panic("Cannot parse event: invalid literal")}
		t.pos = end
	case:
		t.pos = start
		if b == '-' {t.pos += 1}
		if t.pos == len(t.data) {panic("Cannot parse event: truncated number")}
		if t.data[t.pos] == '0' {t.pos += 1} else {
			if t.data[t.pos] < '1' ||
			   t.data[t.pos] > '9' {panic("Cannot parse event: invalid number or non-ASCII byte")}
			for t.pos < len(t.data) && t.data[t.pos] >= '0' && t.data[t.pos] <= '9' {t.pos += 1}
		}
		kind = .Integer
		if t.pos < len(t.data) && t.data[t.pos] == '.' {
			kind = .Float; t.pos += 1
			digits := t.pos
			for t.pos < len(t.data) && t.data[t.pos] >= '0' && t.data[t.pos] <= '9' {t.pos += 1}
			if t.pos == digits {panic("Cannot parse event: missing fractional digits")}
		}
		if t.pos < len(t.data) && (t.data[t.pos] == 'e' || t.data[t.pos] == 'E') {
			kind = .Float; t.pos += 1
			if t.pos < len(t.data) && (t.data[t.pos] == '+' || t.data[t.pos] == '-') {t.pos += 1}
			digits := t.pos
			for t.pos < len(t.data) && t.data[t.pos] >= '0' && t.data[t.pos] <= '9' {t.pos += 1}
			if t.pos == digits {panic("Cannot parse event: missing exponent digits")}
		}
	}
	return Token{kind = kind, text = t.data[start:t.pos], has_escapes = has_escapes}
}

expect :: proc(t: ^Scanner, kind: json.Token_Kind) {
	if next(t).kind != kind {panic("Cannot parse event: unexpected token")}
}

append_scalar :: proc(r: ^Record, token: Token) {
	#partial switch token.kind {
	case .String, .Integer, .Float, .True, .False, .Null:
	// Valid scalar.
	case:
		panic("Cannot parse event: expected a scalar value; nesting is forbidden")
	}
	r.values[r.value_count] = token
	r.value_count += 1
}

// Parses any flat object, independent of field names, order, and operation.
// Arrays may contain scalars only. No recursion or allocator calls.
parse_flat :: proc(line: string, r: ^Record) {
	if len(line) >=
	   MAX_RECORD {panic("Cannot parse event: record must contain fewer than 2048 bytes")}
	clear(&r.fields)
	r.field_count = 0
	r.value_count = 0
	t := Scanner {
		data = line,
	}
	expect(&t, .Open_Brace)
	token := next(&t)
	if token.kind == .Close_Brace {
		expect(&t, .EOF)
		return
	}
	for {
		if token.kind != .String {panic("Cannot parse event: expected a key")}
		key := token.text[1:len(token.text) - 1]
		if token.has_escapes {panic("Cannot parse event: escaped keys are forbidden")}
		if len(key) == 0 {panic("Cannot parse event: key is empty")}
		if key[0] < 'a' || key[0] > 'z' {
			panic("Cannot parse event: key must start with a lowercase ASCII letter")
		}
		for b in key {
			if (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '_' {continue}
			panic(
				"Cannot parse event: key must contain only lowercase ASCII letters, digits, and underscores",
			)
		}
		for i in 0 ..< r.field_count {
			if r.fields[i].key == key {panic("Cannot parse event: duplicate key")}
		}
		expect(&t, .Colon)
		first := r.value_count
		field := Field {
			key = key,
		}
		value := next(&t)
		if value.kind == .Open_Bracket {
			field.is_array = true
			value = next(&t)
			if value.kind != .Close_Bracket {
				for {
					append_scalar(r, value)
					separator := next(&t)
					if separator.kind == .Close_Bracket {break}
					if separator.kind !=
					   .Comma {panic("Cannot parse event: expected an array separator")}
					value = next(&t)
				}
			}
		} else {
			append_scalar(r, value)
		}
		field.values = r.values[first:r.value_count]
		append(&r.fields, field)
		r.field_count += 1
		separator := next(&t)
		if separator.kind == .Close_Brace {break}
		if separator.kind != .Comma {panic("Cannot parse event: expected an object separator")}
		token = next(&t)
	}
	expect(&t, .EOF)
}
