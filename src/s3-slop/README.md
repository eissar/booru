# s3-slop

AWS Signature Version 4 request signing, in Odin, with no dependencies beyond
`core`.

`sigv4.odin` performs no I/O. Given a request and credentials it produces the
`Authorization` header value, and it exposes every intermediate stage so the
canonicalisation can be tested and debugged on its own. That makes this the pure
half of an S3 client: the transport (retries, pagination, error codes, clock
skew) can be faked at a separate seam.

## Status

All 31 cases of the AWS SigV4 test suite pass, with no allocation leaks. From
the repository root:

```
task test:s3
```

## Files

```
sigv4.odin              the signer (package s3)
tests/suite_test.odin   runs the vendored AWS SigV4 test suite
tests/s3_test.odin      S3-specific behaviour the suite does not cover
tests/testdata/         vendored aws-sig-v4-test-suite
```

## Usage

```odin
import s3 "s3-slop"   // relative to a file in src/

amz_date :: "20150830T123600Z"

req := s3.Request {
	method  = "GET",
	path    = "/photo.jpg",   // raw, exactly as it goes on the wire
	query   = "",
	headers = []s3.Header {
		{name = "Host", value = "my-bucket.s3.us-east-1.amazonaws.com"},
		{name = "X-Amz-Date", value = amz_date},
	},
}

opts := s3.Options {
	region         = "us-east-1",
	service        = "s3",
	amz_date       = amz_date,   // YYYYMMDDTHHMMSSZ; supplied, not read from the clock
	credentials    = creds,
	normalize_path = false,      // S3 must not normalise paths
}

authz, err := s3.sign(req, opts)
defer delete(authz)
if err != "" {
	// err is a static string; do not free it.
	return
}
// Send req with an Authorization: authz header.
```

Every request header present is signed. If you use temporary credentials, put
`X-Amz-Security-Token` in `req.headers` when the service requires it in the
canonical request, and leave it out when it must be added after signing.

For a request whose body is not hashed (streamed uploads, or a body transformed
after signing), set `opts.payload_hash = s3.UNSIGNED_PAYLOAD`.

## Ownership

Strings returned by this package are allocated with the allocator you pass
(`context.allocator` by default) and are yours to free. Inputs are never taken
over. The one exception is `err`: every failure path returns a string literal,
so `err` is always static and must not be freed.

## S3 is the special case

SigV4 as specified normalises URI paths: `//example//photo.user` becomes
`/example/photo.user`. S3 does not, and normalising the path is how you sign a
request for an object that does not exist. The suite says so itself, in
`tests/testdata/aws-sig-v4-test-suite/normalize-path/normalize-path.txt`.

So:

| caller | `normalize_path` |
| --- | --- |
| S3 | `false` |
| everything else in AWS | `true` |

The suite only exercises the normalising mode. `tests/s3_test.odin` covers the
S3 mode, including that the two produce different signature inputs for a
redundant-slash path.

## Notes on the vendored suite

Provenance: a snapshot of the archived `awslabs/aws-sig-v4-test-suite` taken
after upstream's "two broken test cases" fix (which added the missing
`Content-Length` to the two `x-www-form-urlencoded` cases, changing their
signatures), plus `get-header-value-multiline` from the pre-fix snapshot, which
the later snapshot dropped. `.gitattributes` marks the fixtures `-text` because
some request files deliberately have no trailing newline.

Two upstream cases are degenerate and are left as found:

- `get-vanilla-query` has a request file identical to `get-vanilla`, so it
  passes trivially.
- `get-vanilla-empty-query-key` likewise does not exercise the case its name
  suggests.

Their `.creq`, `.sts` and `.authz` files are mutually consistent, so the tests
still assert something real; they just do not assert what the names imply.
Rewriting them would have meant diverging from the published suite.

`get-header-value-multiline` is the one place the suite contradicts the RFC.
RFC 7230 says a folded header value is unfolded by replacing the line break with
a space; the suite expects the continuation lines joined with **commas**. The
suite is the contract for this code, so folded values join with commas, which is
also what treating each physical line as a separate value produces. Real
requests should never contain obs-fold.

The suite uses fixed inputs: access key `AKIDEXAMPLE`, secret
`wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`, region `us-east-1`, service
`service`.

## Not implemented

- Presigned URLs (query-string signing). The pieces are here:
  `canonical_request`, `signing_key` and `credential_scope` are exactly what a
  presigner needs; it puts the signature in the query instead of a header.
- SigV4A and streaming/chunked signatures.
- Actually sending requests.