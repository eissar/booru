// Package tests drives the AWS Signature Version 4 test suite against the
// signer in the parent package.
//
// The suite is vendored under testdata/aws-sig-v4-test-suite. For each case it
// checks three things independently, which is what makes failures diagnosable:
//
//	.req   -> parsed request (input)
//	.creq  -> expected canonical request
//	.sts   -> expected string to sign
//	.authz -> expected Authorization header
//
// Checking the canonical request first usually localises a failure to
// encoding/sorting/normalisation instead of the HMAC chain.
package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import s3 ".."

// #directory is a compile-time constant for this file's directory, so the tests
// do not depend on the process working directory.
TESTDATA :: #directory + "testdata/aws-sig-v4-test-suite"

// The suite's fixed inputs, as documented alongside it.
TEST_REGION :: "us-east-1"
TEST_SERVICE :: "service"
TEST_ACCESS_KEY :: "AKIDEXAMPLE"
TEST_SECRET_KEY :: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

// The vendored suite (30 upstream cases plus get-header-value-multiline).
EXPECTED_CASES :: 31

@(test)
test_sigv4_suite :: proc(t: ^testing.T) {
	cases := collect_cases(t)
	defer {
		for c in cases {
			delete(c)
		}
		delete(cases)
	}

	testing.expectf(
		t,
		len(cases) == EXPECTED_CASES,
		"found %d cases under %s, expected %d",
		len(cases),
		TESTDATA,
		EXPECTED_CASES,
	)
	if len(cases) != EXPECTED_CASES {
		return
	}

	for base in cases {
		run_case(t, base)
	}
}

// test_known_constants guards the two literals that other code may rely on.
@(test)
test_known_constants :: proc(t: ^testing.T) {
	empty := s3.sha256_hex(nil)
	defer delete(empty)
	testing.expectf(
		t,
		empty == s3.EMPTY_PAYLOAD_SHA256,
		"sha256(\"\") = %s, want %s",
		empty,
		s3.EMPTY_PAYLOAD_SHA256,
	)
}

// ---------------------------------------------------------------------------
// Case running
// ---------------------------------------------------------------------------

@(private)
run_case :: proc(t: ^testing.T, base: string) {
	name := case_name(base)

	req_text, req_ok := read_file(base, ".req")
	if !req_ok {
		failf(t, "%s: cannot read .req", name)
		return
	}
	defer delete(req_text)

	parsed, parse_err := parse_request(req_text)
	defer destroy_parsed(&parsed)
	if parse_err != "" {
		failf(t, "%s: %s", name, parse_err)
		return
	}

	opts := s3.Options {
		region         = TEST_REGION,
		service        = TEST_SERVICE,
		amz_date       = header_value(parsed.headers[:], "x-amz-date"),
		credentials    = s3.Credentials{access_key = TEST_ACCESS_KEY, secret_key = TEST_SECRET_KEY},
		normalize_path = true,
	}

	req := s3.Request {
		method  = parsed.method,
		path    = parsed.path,
		query   = parsed.query,
		headers = parsed.headers[:],
		body    = parsed.body,
	}

	ok := true

	// 1. canonical request
	creq, signed_headers, creq_err := s3.canonical_request(req, opts)
	defer delete(creq)
	defer delete(signed_headers)
	if creq_err != "" {
		failf(t, "%s: canonical_request: %s", name, creq_err)
		ok = false
	} else if want, want_ok := read_file(base, ".creq"); want_ok {
		defer delete(want)
		ok = compare(t, name, "creq", creq, want) && ok
	} else {
		failf(t, "%s: cannot read .creq", name)
		ok = false
	}

	// 2. string to sign
	sts := s3.string_to_sign(creq, opts)
	defer delete(sts)
	if want, want_ok := read_file(base, ".sts"); want_ok {
		defer delete(want)
		ok = compare(t, name, "sts", sts, want) && ok
	} else {
		failf(t, "%s: cannot read .sts", name)
		ok = false
	}

	// 3. authorization header
	authz, authz_err := s3.sign(req, opts)
	defer delete(authz)
	if authz_err != "" {
		failf(t, "%s: sign: %s", name, authz_err)
		ok = false
	} else if want, want_ok := read_file(base, ".authz"); want_ok {
		defer delete(want)
		ok = compare(t, name, "authz", authz, want) && ok
	} else {
		failf(t, "%s: cannot read .authz", name)
		ok = false
	}

	if ok {
		fmt.printfln("ok   %s", name)
	} else {
		fmt.printfln("FAIL %s", name)
	}
}

@(private)
compare :: proc(t: ^testing.T, name, label, got, want: string) -> bool {
	g := strings.trim_right(got, "\r\n")
	w := strings.trim_right(want, "\r\n")
	if g == w {
		return true
	}

	failf(t, "%s: %s mismatch", name, label)
	print_diff(label, g, w)
	return false
}

// print_diff shows the first differing lines of two multi-line strings, which
// is far more useful than dumping both blobs.
@(private)
print_diff :: proc(label, got, want: string) {
	g := strings.split(got, "\n", context.temp_allocator)
	w := strings.split(want, "\n", context.temp_allocator)
	n := max(len(g), len(w))
	shown := 0
	for i in 0 ..< n {
		gs := i < len(g) ? g[i] : "<missing>"
		ws := i < len(w) ? w[i] : "<missing>"
		if gs == ws {
			continue
		}
		fmt.printfln("       %s[%d] got  %q", label, i, gs)
		fmt.printfln("       %s[%d] want %q", label, i, ws)
		shown += 1
		if shown == 6 {
			fmt.printfln("       %s: ... further differences suppressed", label)
			break
		}
	}
}

@(private)
failf :: proc(t: ^testing.T, format: string, args: ..any) {
	testing.expectf(t, false, format, ..args)
}

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

@(private)
collect_cases :: proc(t: ^testing.T) -> [dynamic]string {
	cases := make([dynamic]string)
	walk_err := filepath.walk(TESTDATA, collect_walk, &cases)
	if walk_err != nil {
		failf(t, "walking %s: %v", TESTDATA, walk_err)
	}
	slice.sort(cases[:])
	return cases
}

@(private)
collect_walk :: proc(
	info: os.File_Info,
	in_err: os.Error,
	user_data: rawptr,
) -> (
	err: os.Error,
	skip_dir: bool,
) {
	if in_err != nil {
		return in_err, false
	}
	if info.is_dir || !strings.has_suffix(info.name, ".req") {
		return nil, false
	}
	cases := cast(^[dynamic]string)user_data
	// fullpath is owned by the walker's temp allocator, so it must be copied.
	base := strings.clone(strings.trim_suffix(info.fullpath, ".req"))
	append(cases, base)
	return nil, false
}

// case_name renders "dir/base" for display. It aliases base, which lives for the
// duration of the test, so it allocates nothing.
@(private)
case_name :: proc(base: string) -> string {
	return strings.trim_prefix(base, TESTDATA + "/")
}

// read_file reads base + ext. The path is built with the temp allocator and
// freed on return; the file contents are caller-owned.
@(private)
read_file :: proc(base, ext: string) -> (text: string, ok: bool) {
	path := strings.concatenate({base, ext}, context.allocator)
	defer delete(path)

	data, read_ok := os.read_entire_file(path, context.allocator)
	if !read_ok {
		return "", false
	}
	return string(data), true
}

// ---------------------------------------------------------------------------
// Request parsing
// ---------------------------------------------------------------------------

@(private)
Parsed :: struct {
	method:  string,
	path:    string,
	query:   string,
	headers: [dynamic]s3.Header,
	// body aliases the input text; it is only valid while that text is alive.
	body:    []byte,
}

@(private)
destroy_parsed :: proc(p: ^Parsed) {
	delete(p.method)
	delete(p.path)
	delete(p.query)
	for h in p.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(p.headers)
	p^ = {}
}

// parse_request reads the suite's .req format: a request line, headers (with
// possible folded continuation lines), a blank line, then an optional body.
//
// Continuation lines are kept inside the owning header's value separated by
// '\n', which is how a real HTTP parser would surface them; the signer is then
// responsible for unfolding. That keeps the get-header-value-multiline case
// testing the library rather than the test harness.
@(private)
parse_request :: proc(data: string, allocator := context.allocator) -> (p: Parsed, err: string) {
	head := data
	var_body: []byte

	if blank := strings.index(data, "\n\n"); blank != -1 {
		head = data[:blank]
		var_body = transmute([]byte)data[blank + 2:]
	}

	lines := strings.split(head, "\n", context.temp_allocator)
	if len(lines) == 0 || strings.trim_space(lines[0]) == "" {
		return {}, "empty request"
	}

	request_line := strings.trim_right(lines[0], "\r")
	method, _, rest := strings.partition(request_line, " ")
	// The target is everything between the first and the last space: a raw
	// space inside the path is legal input for the signer (the get-space case),
	// so only the trailing " HTTP/1.1" may be stripped.
	target := rest
	if last := strings.last_index(rest, " "); last != -1 {
		target = rest[:last]
	}
	if method == "" || target == "" {
		return {}, fmt.tprintf("malformed request line %q", request_line)
	}

	target_path, _, target_query := strings.partition(target, "?")
	p.method = strings.clone(method, allocator)
	p.path = strings.clone(target_path, allocator)
	p.query = strings.clone(target_query, allocator)

	for i := 1; i < len(lines); i += 1 {
		line := strings.trim_right(lines[i], "\r")
		if line == "" {
			continue
		}

		if line[0] == ' ' || line[0] == '\t' {
			if len(p.headers) == 0 {
				return {}, fmt.tprintf("continuation line with no header: %q", line)
			}
			last := &p.headers[len(p.headers) - 1]
			previous := last.value
			last.value = strings.concatenate({previous, "\n", line}, allocator)
			delete(previous)
			continue
		}

		name, _, value := strings.partition(line, ":")
		append(
			&p.headers,
			s3.Header {
				name = strings.clone(name, allocator),
				value = strings.clone(value, allocator),
			},
		)
	}

	if length := header_value(p.headers[:], "content-length"); length != "" {
		if n, n_ok := strconv.parse_int(length); n_ok && n <= len(var_body) {
			var_body = var_body[:n]
		}
	}
	p.body = var_body

	return p, ""
}

@(private)
header_value :: proc(headers: []s3.Header, name: string) -> string {
	for h in headers {
		if strings.equal_fold(h.name, name) {
			return strings.trim_space(h.value)
		}
	}
	return ""
}