// Package s3 implements AWS Signature Version 4 (SigV4) request signing.
//
// The implementation is deliberately split so that the pure string work is
// separate from the transport: nothing here performs I/O. Given a request and
// a set of credentials it produces the Authorization header value, and it also
// exposes each intermediate stage (canonical request, string to sign, signing
// key) so they can be inspected and tested independently.
//
// SigV4 overview:
//
//	CanonicalRequest = method \n uri \n query \n headers \n signed_headers \n payload_hash
//	StringToSign     = algorithm \n amz_date \n scope \n hex(sha256(CanonicalRequest))
//	SigningKey       = HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")
//	Signature        = hex(HMAC(SigningKey, StringToSign))
//
// The HMAC chain is the only cryptographic part. Everything else is
// canonicalisation, and canonicalisation is where SigV4 implementations
// actually fail: a mismatch in whitespace, encoding, or ordering produces the
// same opaque "SignatureDoesNotMatch" as a wrong secret. The AWS SigV4 test
// suite in tests/ pins every one of those rules down.
//
// Note for S3 specifically: pass normalize_path = false. S3 does not collapse
// redundant slashes in the URI path, unlike other AWS services. See
// tests/testdata/aws-sig-v4-test-suite/normalize-path/normalize-path.txt.
package s3

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:slice"
import "core:strings"

// Algorithm identifier that prefixes both the string to sign and the final
// Authorization header.
ALGORITHM :: "AWS4-HMAC-SHA256"

// Terminator of the credential scope.
AWS4_REQUEST :: "aws4_request"

// Payload hash literal meaning "this request's body is not signed". Valid for
// S3 over HTTPS when the body is large or streamed.
UNSIGNED_PAYLOAD :: "UNSIGNED-PAYLOAD"

// sha256(""), i.e. the payload hash for a request with an empty body.
EMPTY_PAYLOAD_SHA256 :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

SHA256_SIZE :: 32

// Header is one field in wire order. Duplicate names are allowed and are kept
// as separate entries: the canonical form joins them with commas *in the order
// they appear*, so collapsing duplicates before signing changes the signature.
//
// A folded header value (continuation lines) may be passed either as separate
// entries or as one value containing newlines; canonical_headers treats each
// physical line as a separate value either way.
Header :: struct {
	name:  string,
	value: string,
}

// Request is the wire-level request to sign. Path and query are taken verbatim
// from the request target, i.e. still percent-encoded, with query excluding the
// leading '?'.
Request :: struct {
	method:  string,
	path:    string,
	query:   string,
	headers: []Header,
	body:    []byte,
}

// Credentials are long-term or temporary AWS credentials. session_token is not
// used by header-based signing directly; if a request carries
// X-Amz-Security-Token it must already be present in Request.headers so that it
// takes part in the canonical request.
Credentials :: struct {
	access_key:    string,
	secret_key:    string,
	session_token: string,
}

// Options describes everything about a signing operation that is not the
// request itself.
Options :: struct {
	region:  string,
	service: string,
	// amz_date is the request timestamp in the form YYYYMMDDTHHMMSSZ. The
	// caller supplies it (rather than reading the clock here) so that signing
	// stays deterministic and testable. AWS rejects requests whose timestamp is
	// more than 15 minutes off its own clock.
	amz_date:    string,
	credentials: Credentials,
	// normalize_path resolves "." and ".." and collapses repeated slashes.
	// This is required for most AWS services and must be false for S3.
	normalize_path: bool,
	// payload_hash overrides the computed SHA-256 of Request.body. Use
	// UNSIGNED_PAYLOAD, or the hash of the original body when the request body
	// is transformed after signing. Empty means "hash the body".
	payload_hash: string,
}

// ---------------------------------------------------------------------------
// Public signing stages
// ---------------------------------------------------------------------------

// canonical_request builds the canonical request string and the
// semicolon-separated signed headers list. Both are caller-owned.
canonical_request :: proc(
	req: Request,
	opts: Options,
	allocator := context.allocator,
) -> (
	creq: string,
	signed_headers: string,
	err: string,
) {
	if req.method == "" {
		return "", "", "method is required"
	}

	uri := canonical_path(req.path, opts.normalize_path, allocator)
	defer delete(uri)

	query := canonical_query(req.query, allocator)
	defer delete(query)

	headers, signed := canonical_headers(req.headers, allocator)
	defer delete(headers)

	payload := opts.payload_hash
	owned_payload := ""
	if payload == "" {
		owned_payload = sha256_hex(req.body, allocator)
		payload = owned_payload
	}
	defer {
		if owned_payload != "" {
			delete(owned_payload)
		}
	}

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, req.method)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, uri)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, query)
	strings.write_byte(&sb, '\n')
	// headers already terminates each field with '\n', so this write produces
	// the blank line that separates headers from the signed-header list.
	strings.write_string(&sb, headers)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, signed)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, payload)

	return strings.to_string(sb), signed, ""
}

// string_to_sign builds the second-stage string. It is the algorithm, the
// timestamp, the credential scope, and the hash of the canonical request, each
// on its own line.
string_to_sign :: proc(
	creq: string,
	opts: Options,
	allocator := context.allocator,
) -> string {
	scope := credential_scope(opts, allocator)
	defer delete(scope)

	hashed := sha256_hex(as_bytes(creq), allocator)
	defer delete(hashed)

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, ALGORITHM)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, opts.amz_date)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, scope)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, hashed)
	return strings.to_string(sb)
}

// credential_scope is the "date/region/service/aws4_request" tail used both in
// the string to sign and in the Authorization header.
credential_scope :: proc(opts: Options, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, short_date(opts.amz_date))
	strings.write_byte(&sb, '/')
	strings.write_string(&sb, opts.region)
	strings.write_byte(&sb, '/')
	strings.write_string(&sb, opts.service)
	strings.write_byte(&sb, '/')
	strings.write_string(&sb, AWS4_REQUEST)
	return strings.to_string(sb)
}

// signing_key derives the per-request signing key. The chain is four nested
// HMACs, each fed the raw digest of the previous one: no hex encoding happens
// between the steps, which is a common source of quietly wrong signatures.
//
// date is the YYYYMMDD prefix of the request timestamp, not the full timestamp.
signing_key :: proc(
	secret_key: string,
	date: string,
	region: string,
	service: string,
	allocator := context.allocator,
) -> [SHA256_SIZE]byte {
	prefixed := strings.concatenate({"AWS4", secret_key}, allocator)
	defer delete(prefixed)

	k_date := hmac_sha256(as_bytes(prefixed), as_bytes(date))
	k_region := hmac_sha256(k_date[:], as_bytes(region))
	k_service := hmac_sha256(k_region[:], as_bytes(service))
	return hmac_sha256(k_service[:], as_bytes(AWS4_REQUEST))
}

// sign computes the Authorization header value for req. The returned string is
// caller-owned.
//
// err, when non-empty, is a static description and must not be freed: every
// failure path in this package returns a string literal, so there is no
// allocation to release on error.
sign :: proc(
	req: Request,
	opts: Options,
	allocator := context.allocator,
) -> (
	authorization: string,
	err: string,
) {
	if opts.credentials.access_key == "" {
		return "", "credentials.access_key is required"
	}
	if opts.credentials.secret_key == "" {
		return "", "credentials.secret_key is required"
	}
	if opts.region == "" {
		return "", "region is required"
	}
	if opts.service == "" {
		return "", "service is required"
	}
	if len(opts.amz_date) < 8 {
		return "", "amz_date must be of the form YYYYMMDDTHHMMSSZ"
	}

	creq, signed_headers, creq_err := canonical_request(req, opts, allocator)
	if creq_err != "" {
		return "", creq_err
	}
	defer delete(creq)
	defer delete(signed_headers)

	sts := string_to_sign(creq, opts, allocator)
	defer delete(sts)

	key := signing_key(
		opts.credentials.secret_key,
		short_date(opts.amz_date),
		opts.region,
		opts.service,
		allocator,
	)

	tag: [SHA256_SIZE]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], as_bytes(sts), key[:])

	signature := hex_lower(tag[:], allocator)
	defer delete(signature)

	scope := credential_scope(opts, allocator)
	defer delete(scope)

	sb := strings.builder_make(allocator)
	strings.write_string(&sb, ALGORITHM)
	strings.write_string(&sb, " Credential=")
	strings.write_string(&sb, opts.credentials.access_key)
	strings.write_byte(&sb, '/')
	strings.write_string(&sb, scope)
	strings.write_string(&sb, ", SignedHeaders=")
	strings.write_string(&sb, signed_headers)
	strings.write_string(&sb, ", Signature=")
	strings.write_string(&sb, signature)
	return strings.to_string(sb), ""
}

// ---------------------------------------------------------------------------
// Canonicalisation
// ---------------------------------------------------------------------------

// canonical_path produces the URI component of the canonical request.
//
// Each segment is percent-decoded and then re-encoded with the unreserved set,
// so an existing escape (including %2F, which is not a separator) round-trips
// to a canonical spelling rather than being double-encoded or lost.
//
// When normalize is true, empty segments and "." are dropped and ".." pops the
// previous segment; a trailing slash is preserved. When normalize is false the
// slash structure is copied through untouched, which is what S3 requires: S3
// distinguishes "my-object//example//photo.user" from the collapsed form.
canonical_path :: proc(
	path: string,
	normalize: bool,
	allocator := context.allocator,
) -> string {
	target := path
	if target == "" {
		target = "/"
	}

	// S3 mode: copy separators verbatim and encode only the bytes between them.
	// Scanning explicitly (rather than splitting and re-joining) is what keeps
	// both empty segments and the trailing slash intact.
	if !normalize {
		sb := strings.builder_make(allocator)
		start := 0
		for i in 0 ..= len(target) {
			if i != len(target) && target[i] != '/' {
				continue
			}
			if i > start {
				segment := uri_encode(target[start:i], allocator)
				strings.write_string(&sb, segment)
				delete(segment)
			}
			if i < len(target) {
				strings.write_byte(&sb, '/')
			}
			start = i + 1
		}
		return strings.to_string(sb)
	}

	segments := make([dynamic]string, 0, 8, allocator)
	defer {
		for s in segments {
			delete(s)
		}
		delete(segments)
	}

	trailing_slash := strings.has_suffix(target, "/")

	start := 0
	for i in 0 ..= len(target) {
		if i != len(target) && target[i] != '/' {
			continue
		}
		segment := target[start:i]
		start = i + 1

		switch segment {
		case "", ".":
			continue
		case "..":
			if len(segments) > 0 {
				delete(pop(&segments))
			}
			continue
		}
		append(&segments, uri_encode(segment, allocator))
	}

	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '/')
	for segment, i in segments {
		if i > 0 {
			strings.write_byte(&sb, '/')
		}
		strings.write_string(&sb, segment)
	}
	// A lone "/" is already complete; appending would make it "//".
	if trailing_slash && len(segments) > 0 {
		strings.write_byte(&sb, '/')
	}
	return strings.to_string(sb)
}

// canonical_query sorts and re-encodes the query string. Parameters are ordered
// by encoded key and then encoded value, byte-wise, which is why "Value1" sorts
// before "value2": uppercase letters have lower code points.
canonical_query :: proc(query: string, allocator := context.allocator) -> string {
	if query == "" {
		return ""
	}

	Pair :: struct {
		key:   string,
		value: string,
	}

	pairs := make([dynamic]Pair, 0, 8, allocator)
	defer {
		for p in pairs {
			delete(p.key)
			delete(p.value)
		}
		delete(pairs)
	}

	rest := query
	for parameter in strings.split_iterator(&rest, "&") {
		if parameter == "" {
			continue
		}
		key, _, value := strings.partition(parameter, "=")
		append(
			&pairs,
			Pair {
				key = uri_encode(key, allocator),
				value = uri_encode(value, allocator),
			},
		)
	}

	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {
		if a.key != b.key {
			return a.key < b.key
		}
		return a.value < b.value
	})

	sb := strings.builder_make(allocator)
	for p, i in pairs {
		if i > 0 {
			strings.write_byte(&sb, '&')
		}
		strings.write_string(&sb, p.key)
		strings.write_byte(&sb, '=')
		strings.write_string(&sb, p.value)
	}
	return strings.to_string(sb)
}

// canonical_headers lower-cases and sorts header names, canonicalises each
// value, and joins repeated names with commas in their original order.
//
// A value containing newlines (a folded header) is split into one value per
// physical line before joining, so a caller does not have to unfold.
//
// It returns the canonical header block (each line terminated by '\n') and the
// semicolon-separated list of signed header names. Both are caller-owned.
//
// Names are grouped rather than sorted in place because repeated values must
// keep their wire order while the names themselves get sorted, and Odin's
// sort_by is not stable.
canonical_headers :: proc(
	headers: []Header,
	allocator := context.allocator,
) -> (
	block: string,
	signed: string,
) {
	Group :: struct {
		name:   string,
		values: [dynamic]string,
	}

	groups := make([dynamic]Group, 0, len(headers), allocator)
	defer {
		for &g in groups {
			delete(g.name)
			for v in g.values {
				delete(v)
			}
			delete(g.values)
		}
		delete(groups)
	}

	for h in headers {
		name := lower_clone(h.name, allocator)

		// Find the group for this name, creating it if needed. Whoever creates
		// the group hands ownership of name to it.
		index := -1
		for i in 0 ..< len(groups) {
			if groups[i].name == name {
				index = i
				break
			}
		}
		if index == -1 {
			append(
				&groups,
				Group {
					name = name,
					values = make([dynamic]string, 0, 1, allocator),
				},
			)
			index = len(groups) - 1
		} else {
			delete(name)
		}

		rest := h.value
		for line in strings.split_iterator(&rest, "\n") {
			append(&groups[index].values, canonical_header_value(line, allocator))
		}
	}

	slice.sort_by(groups[:], proc(a, b: Group) -> bool {return a.name < b.name})

	block_sb := strings.builder_make(allocator)
	for g in groups {
		strings.write_string(&block_sb, g.name)
		strings.write_byte(&block_sb, ':')
		for v, i in g.values {
			if i > 0 {
				strings.write_byte(&block_sb, ',')
			}
			strings.write_string(&block_sb, v)
		}
		strings.write_byte(&block_sb, '\n')
	}

	signed_sb := strings.builder_make(allocator)
	for g, i in groups {
		if i > 0 {
			strings.write_byte(&signed_sb, ';')
		}
		strings.write_string(&signed_sb, g.name)
	}

	return strings.to_string(block_sb), strings.to_string(signed_sb)
}

// canonical_header_value trims the value and collapses internal runs of
// whitespace to a single space. Values are otherwise left byte-for-byte alone,
// including case and embedded commas.
canonical_header_value :: proc(v: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	pending_space := false

	for i := 0; i < len(v); i += 1 {
		c := v[i]
		if is_whitespace(c) {
			pending_space = true
			continue
		}
		if pending_space && strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, ' ')
		}
		pending_space = false
		strings.write_byte(&sb, c)
	}
	// A trailing run of whitespace only ever sets pending_space, so the value
	// is trimmed on the right for free.
	return strings.to_string(sb)
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

// uri_encode percent-encodes data with the RFC 3986 unreserved set, which SigV4
// requires. Unlike application/x-www-form-urlencoded it encodes a space as %20
// and never as '+', and it leaves '-', '_', '.' and '~' untouched.
//
// Existing escapes are decoded and then re-encoded, so the result is the
// canonical spelling: "%2f" becomes "%2F" rather than "%252f". A '%' that is
// not followed by two hex digits is treated as a literal byte.
uri_encode :: proc(data: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)

	for i := 0; i < len(data); {
		if data[i] == '%' && i + 2 < len(data) {
			hi, hi_ok := hex_digit(data[i + 1])
			lo, lo_ok := hex_digit(data[i + 2])
			if hi_ok && lo_ok {
				write_uri_byte(&sb, hi << 4 | lo)
				i += 3
				continue
			}
		}
		write_uri_byte(&sb, data[i])
		i += 1
	}
	return strings.to_string(sb)
}

// sha256_hex returns the lowercase hex SHA-256 of data.
sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	digest: [SHA256_SIZE]byte
	hash.hash_bytes_to_buffer(hash.Algorithm.SHA256, data, digest[:])
	return hex_lower(digest[:], allocator)
}

@(private)
hmac_sha256 :: proc(key, msg: []byte) -> [SHA256_SIZE]byte {
	tag: [SHA256_SIZE]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], msg, key)
	return tag
}

@(private)
as_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

@(private)
hex_char_lower :: proc(v: byte) -> byte {
	return v < 10 ? '0' + v : 'a' + (v - 10)
}

@(private)
hex_char_upper :: proc(v: byte) -> byte {
	return v < 10 ? '0' + v : 'A' + (v - 10)
}

@(private)
hex_lower :: proc(data: []byte, allocator := context.allocator) -> string {
	buf := make([]byte, len(data) * 2, allocator)
	for b, i in data {
		buf[i * 2] = hex_char_lower(b >> 4)
		buf[i * 2 + 1] = hex_char_lower(b & 0x0f)
	}
	return string(buf)
}

@(private)
hex_digit :: proc(c: byte) -> (value: byte, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

@(private)
write_uri_byte :: proc(sb: ^strings.Builder, b: byte) {
	if is_unreserved(b) {
		strings.write_byte(sb, b)
		return
	}
	strings.write_byte(sb, '%')
	strings.write_byte(sb, hex_char_upper(b >> 4))
	strings.write_byte(sb, hex_char_upper(b & 0x0f))
}

@(private)
is_unreserved :: proc(c: byte) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
		return true
	}
	return false
}

@(private)
is_whitespace :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
lower_clone :: proc(s: string, allocator := context.allocator) -> string {
	buf := make([]byte, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		buf[i] = c
	}
	return string(buf)
}

@(private)
short_date :: proc(amz_date: string) -> string {
	if len(amz_date) < 8 {
		return amz_date
	}
	return amz_date[:8]
}