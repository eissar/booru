# Import tag baseline

Run from the repository root:

```sh
odin run bench/import-tags -o:speed -out:bin/bench-import-tags
```

Synthetic CPU baseline before tag validation/remediation: JSON-decode Eagle metadata,
retain the decoded event in an arena-backed dynamic array, and consume a checksum.
Eight tags per item, 100,000 items per sample, seven samples after warmup; arena
reset every 256 items. Excludes file I/O, hashing, database work and log encoding.
This is not an end-to-end importer benchmark. The wire struct mirrors
`src/importers/eagle_import.odin`; keep it synchronized when changing that type.
The future validation loop belongs immediately before `append(&events, ev^)`.

Baseline on the current host (`-o:speed`):

| Input | Mean ms / 100k items | Range ms | ns/item | items/s |
| --- | ---: | ---: | ---: | ---: |
| Clean | 515.511 | 509.865–524.583 | 5155.1 | 193982 |
| Unsupported characters | 531.980 | 517.744–539.458 | 5319.8 | 187977 |
| Potential collisions | 515.569 | 504.041–522.485 | 5155.7 | 193960 |

The inputs differ but currently follow the same code path: none is validated or
remediated. These differences are not measurements of remediation overhead.
