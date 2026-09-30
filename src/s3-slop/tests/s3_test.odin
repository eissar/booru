// Tests for behaviour the AWS suite deliberately does not pin down: S3's
// non-normalising path handling, the encoding edge cases, query ordering, and
// the fold/duplicate handling for headers.
//
// The suite's normalize-path/ directory documents why this matters:
//
//	"In exception to this, you do not normalize URI paths for requests to
//	 Amazon S3. For example, if you have a bucket with an object named
//	 my-object//example//photo.user, use that path."
//
// So S3 is the one caller that must pass normalize_path = false, and these
// tests keep that switch honest.
package tests

import s3 ".."
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_canonical_path_modes :: proc(t: ^testing.T) {
	Cases :: struct {
		input:      string,
		normalized: string,
		s3:         string,
	}

	cases := []Cases {
		{"//example//", "/example/", "//example//"},
		{"/a/./b/../c", "/a/c", "/a/./b/../c"},
		{"/exa mple/", "/exa%20mple/", "/exa%20mple/"},
		{"//", "/", "//"},
		{"/ሴ", "/%E1%88%B4", "/%E1%88%B4"},
		{"/", "/", "/"},
		{"", "/", "/"},
		{"/a/b/", "/a/b/", "/a/b/"},
	}

	for c in cases {
		got_normalized := s3.canonical_path(c.input, true)
		defer delete(got_normalized)
		got_s3 := s3.canonical_path(c.input, false)
		defer delete(got_s3)

		expect_str(
			t,
			fmt.tprintf("canonical_path(%q, normalize=true)", c.input),
			got_normalized,
			c.normalized,
		)
		expect_str(t, fmt.tprintf("canonical_path(%q, normalize=false)", c.input), got_s3, c.s3)
	}
}

@(test)
test_uri_encode :: proc(t: ^testing.T) {
	Cases :: struct {
		input: string,
		want:  string,
	}

	cases := []Cases {
		{"", ""},
		{"abc-._~0123456789", "abc-._~0123456789"},
		{"a b", "a%20b"},
		// Not form encoding: '+' is a literal plus, not a space.
		{"a+b", "a%2Bb"},
		// Existing escapes are canonicalised, never double-encoded.
		{"%2f", "%2F"},
		{"a%2Fb", "a%2Fb"},
		{"ሴ", "%E1%88%B4"},
		// '/' is reserved here because path segments are encoded separately.
		{"/", "%2F"},
		// A lone '%' is literal data.
		{"100%", "100%25"},
		{"%zz", "%25zz"},
	}

	for c in cases {
		got := s3.uri_encode(c.input)
		defer delete(got)
		expect_str(t, fmt.tprintf("uri_encode(%q)", c.input), got, c.want)
	}
}

@(test)
test_canonical_query :: proc(t: ^testing.T) {
	Cases :: struct {
		input: string,
		want:  string,
	}

	cases := []Cases {
		{"", ""},
		{"b=2&a=1", "a=1&b=2"},
		// Sorting is byte-wise on the encoded forms, so uppercase first.
		{"a=2&a=1", "a=1&a=2"},
		{"Param1=value2&Param1=Value1", "Param1=Value1&Param1=value2"},
		{"a=1&a=", "a=&a=1"},
		// A bare key canonicalises with an empty value.
		{"Param1", "Param1="},
		{"flag&a=1", "a=1&flag="},
		{"ሴ=bar", "%E1%88%B4=bar"},
		// Trailing and doubled separators are ignored.
		{"a=1&", "a=1"},
		{"a=1&&b=2", "a=1&b=2"},
	}

	for c in cases {
		got := s3.canonical_query(c.input)
		defer delete(got)
		expect_str(t, fmt.tprintf("canonical_query(%q)", c.input), got, c.want)
	}
}

@(test)
test_canonical_headers :: proc(t: ^testing.T) {
	// A folded value and the equivalent split entries must canonicalise the
	// same way: one comma-joined value per name.
	folded := []s3.Header{{name = "My-Header1", value = "value1\n  value2\n     value3"}}
	split := []s3.Header {
		{name = "My-Header1", value = "value1"},
		{name = "My-Header1", value = "value2"},
		{name = "My-Header1", value = "value3"},
	}

	folded_block, folded_signed := s3.canonical_headers(folded)
	defer delete(folded_block)
	defer delete(folded_signed)
	split_block, split_signed := s3.canonical_headers(split)
	defer delete(split_block)
	defer delete(split_signed)

	expect_str(t, "folded block", folded_block, "my-header1:value1,value2,value3\n")
	expect_str(t, "folded block == split block", folded_block, split_block)
	expect_str(t, "folded signed == split signed", folded_signed, split_signed)

	// Repeated headers keep their wire order and are not sorted by value.
	duplicates := []s3.Header {
		{name = "b", value = "2"},
		{name = "a", value = "z"},
		{name = "b", value = "1"},
	}
	dup_block, dup_signed := s3.canonical_headers(duplicates)
	defer delete(dup_block)
	defer delete(dup_signed)
	expect_str(t, "duplicate block", dup_block, "a:z\nb:2,1\n")
	expect_str(t, "duplicate signed", dup_signed, "a;b")

	// Values are trimmed and internal whitespace runs collapse to one space.
	padded := []s3.Header{{name = "X", value = "  a \t  b  "}}
	pad_block, pad_signed := s3.canonical_headers(padded)
	defer delete(pad_block)
	defer delete(pad_signed)
	expect_str(t, "padded block", pad_block, "x:a b\n")
	expect_str(t, "padded signed", pad_signed, "x")
}

@(test)
test_sign_s3_mode :: proc(t: ^testing.T) {
	headers := []s3.Header {
		{name = "Host", value = "examplebucket.s3.amazonaws.com"},
		{name = "X-Amz-Date", value = "20130524T000000Z"},
	}
	req := s3.Request {
		method  = "GET",
		path    = "//example//photo.user",
		headers = headers,
	}
	opts := s3.Options {
		region = "us-east-1",
		service = "s3",
		amz_date = "20130524T000000Z",
		credentials = s3.Credentials{access_key = TEST_ACCESS_KEY, secret_key = TEST_SECRET_KEY},
		normalize_path = false,
	}

	// S3 keeps the redundant slashes.
	s3_creq, s3_signed, s3_err := s3.canonical_request(req, opts)
	defer delete(s3_creq)
	defer delete(s3_signed)
	testing.expectf(t, s3_err == "", "canonical_request: %s", s3_err)
	expect_str(t, "s3 canonical uri", nth_line(s3_creq, 1), "//example//photo.user")
	expect_str(t, "s3 signed headers", s3_signed, "host;x-amz-date")

	// The generic path collapses them, and the resulting signature input must
	// differ: this is the failure mode the normalize-path note warns about.
	generic := opts
	generic.normalize_path = true
	generic_creq, generic_signed, generic_err := s3.canonical_request(req, generic)
	defer delete(generic_creq)
	defer delete(generic_signed)
	testing.expectf(t, generic_err == "", "canonical_request: %s", generic_err)
	expect_str(t, "generic canonical uri", nth_line(generic_creq, 1), "/example/photo.user")
	testing.expectf(
		t,
		s3_creq != generic_creq,
		"S3 and generic canonical requests must differ for a redundant-slash path",
	)

	authz, authz_err := s3.sign(req, opts)
	defer delete(authz)
	testing.expectf(t, authz_err == "", "sign: %s", authz_err)
	prefix :: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature="
	testing.expectf(
		t,
		strings.has_prefix(authz, prefix),
		"unexpected Authorization header: %s",
		authz,
	)
}

// test_sign_rejects_incomplete_options documents which inputs fail fast rather
// than producing a silently wrong signature.
@(test)
test_sign_rejects_incomplete_options :: proc(t: ^testing.T) {
	req := s3.Request {
		method  = "GET",
		path    = "/",
		headers = []s3.Header{{name = "Host", value = "example.amazonaws.com"}},
	}

	full := s3.Options {
		region = "us-east-1",
		service = "s3",
		amz_date = "20150830T123600Z",
		credentials = s3.Credentials{access_key = "k", secret_key = "s"},
		normalize_path = false,
	}

	Missing :: struct {
		label:  string,
		mutate: proc(o: ^s3.Options),
	}
	mutations := []Missing {
		{"access_key", proc(o: ^s3.Options) {o.credentials.access_key = ""}},
		{"secret_key", proc(o: ^s3.Options) {o.credentials.secret_key = ""}},
		{"region", proc(o: ^s3.Options) {o.region = ""}},
		{"service", proc(o: ^s3.Options) {o.service = ""}},
		{"amz_date", proc(o: ^s3.Options) {o.amz_date = ""}},
	}

	for m in mutations {
		opts := full
		m.mutate(&opts)
		// The error is static, so it is deliberately not freed.
		_, err := s3.sign(req, opts)
		testing.expectf(t, err != "", "sign with empty %s should fail", m.label)
	}
}

@(test)
test_payload_hash_override :: proc(t: ^testing.T) {
	// Streamed or transformed bodies are signed as UNSIGNED-PAYLOAD, so the
	// override must win over the body actually handed to canonical_request.
	body := []byte{'h', 'e', 'l', 'l', 'o'}
	headers := []s3.Header{{name = "Host", value = "example.amazonaws.com"}}
	req := s3.Request {
		method  = "PUT",
		path    = "/key",
		headers = headers,
		body    = body,
	}
	opts := s3.Options {
		region = "us-east-1",
		service = "s3",
		amz_date = "20150830T123600Z",
		credentials = s3.Credentials{access_key = TEST_ACCESS_KEY, secret_key = TEST_SECRET_KEY},
		normalize_path = false,
		payload_hash = s3.UNSIGNED_PAYLOAD,
	}

	creq, signed, err := s3.canonical_request(req, opts)
	defer delete(creq)
	defer delete(signed)
	testing.expectf(t, err == "", "canonical_request: %s", err)
	// lines: method, uri, query, header(s), blank, signed headers, payload hash
	expect_str(t, "payload hash line", nth_line(creq, 6), s3.UNSIGNED_PAYLOAD)

	computed := s3.sha256_hex(body)
	defer delete(computed)
	testing.expectf(
		t,
		computed != s3.UNSIGNED_PAYLOAD,
		"the override must differ from the real body hash for this test to mean anything",
	)
}

@(private)
expect_str :: proc(t: ^testing.T, label, got, want: string) {
	testing.expectf(t, got == want, "%s: got %q, want %q", label, got, want)
}

@(private)
nth_line :: proc(s: string, n: int) -> string {
	rest := s
	i := 0
	for line in strings.split_iterator(&rest, "\n") {
		if i == n {
			return line
		}
		i += 1
	}
	return ""
}
