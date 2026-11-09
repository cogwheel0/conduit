# Clipboard and footer benchmarks

The assistant footer checks whether a response has shareable text when a row
mounts. The first optimization below avoids unnecessary sanitizer passes. The
second avoids preparing the clipboard text at all for ordinary footer content. `sanitizeForClipboard` previously masked and restored every code span
for each removal rule, even when that rule had no matches. Rejecting a rule
before masking skips those scans and temporary copies; actual matches still
use the existing code-protected transformation.

Run the freshly generated synthetic fixtures without a server:

```sh
dart compile exe tool/benchmarks/markdown_sanitize.dart -o /path/to/sanitize
/path/to/sanitize candidate
```

For a comparison, use the same harness and dependencies in both builds, restoring
`packages/conduit_markdown/lib/src/markdown_preprocessor.dart` from baseline
`6e51451ef4f4c2d34e8fedb85cb6b16384bb9980` for the baseline executable, then
restoring the candidate file. Run baseline/candidate/candidate/baseline on the
same machine without recording or concurrent builds. Each fixture has five
warmups and fifty measured calls. Whole units are repeated so fences and tags
remain complete; output equality is checked outside the timer.

These initial measurements cover the no-match guard alone, before the footer
predicate was added; their source hash records that intermediate source.
The measured no-reference clipboard paths and guard are unchanged in the final
implementation. Redundant presence checks at already-guarded call sites were
also removed; those call sites are not exercised by these initial fixtures.

[All 3,000 raw samples](markdown_sanitize_results.json) were collected with
Dart 3.13.7 native AOT on macOS arm64. Values below are milliseconds per call;
ranges span the two runs of each variant.

| Fixture | Target size | Baseline p50 | Candidate p50 | Baseline p95 | Candidate p95 |
| --- | --- | --- | --- | --- | --- |
| Prose | 8 KiB | 1.224–1.447 | 0.543–0.553 | 1.312–1.679 | 0.574–0.589 |
| Code | 8 KiB | 1.139–1.389 | 0.524–0.540 | 1.196–1.500 | 0.551–0.577 |
| Prose | 128 KiB | 18.839–19.677 | 8.894–9.003 | 19.777–20.381 | 9.415–9.440 |
| Code | 128 KiB | 18.145–18.402 | 8.528–8.589 | 18.899–19.026 | 8.824–8.860 |
| Prose | 1 MiB | 154.210–158.544 | 71.900–77.371 | 159.569–161.246 | 73.405–90.020 |
| Code | 1 MiB | 151.781–156.187 | 69.416–73.949 | 154.009–184.099 | 71.144–86.431 |
| Reasoning + code | 1 MiB | 121.583–126.358 | 94.388–103.965 | 123.902–144.990 | 100.438–119.693 |
| Tool markup + code | 1 MiB | 145.085–152.320 | 103.245–111.918 | 146.847–181.861 | 113.827–133.823 |
| Literal markup in code | 1 MiB | 106.843–115.909 | 107.063–107.291 | 108.819–161.726 | 108.709–108.791 |

These are sanitizer CPU measurements, not phone frame-rate measurements. The
literal-markup control still needs code masking and has no consistent median
gain; its 128 KiB candidate median was slightly higher (13.569–14.498 ms versus
13.069–13.474 ms). Tails vary: the candidate tool-markup 1 MiB maximum was
245.377 ms in one run versus a baseline maximum of 206.591 ms. All outliers are
retained. With fifty samples, nearest-rank p99 is the maximum; p50 and p95 use
sorted indices 24 and 47. The JSON includes every size, fixture and percentile.

A regression test verifies that unchanged code-rich clipboard text reuses its
input string; the previous implementation returns an unnecessary copy. Existing
copy/share tests still verify reasoning-only responses, tool removal, literal
code examples, grouped answers, version selection and platform failures.

## Footer eligibility

The footer now caches a boolean instead of a sanitized copy of the response.
Ordinary leading text survives clipboard cleanup, so it can establish eligibility
without transforming the whole response. For markup-prefixed responses, a plain final line can also establish eligibility
when no closing block delimiter follows its text. Ambiguous endings, reference
definitions, entities and reasoning-only responses fall back to full sanitization. Copy and Share still generate their text
through `sanitizeForClipboard` when invoked. Indented reference definitions are
passed intact to the fallback.

```sh
dart compile exe tool/benchmarks/clipboard_eligibility.dart -o /path/to/eligibility
/path/to/eligibility
```

This second benchmark uses the **final candidate sanitizer** for both paths; it
measures the incremental eligibility improvement after the no-match guard. Five
1 MiB synthetic fixtures, five warmups and 100 calls per variant, in
full/predicate/predicate/full order. [All 2,000 samples](clipboard_eligibility_results.json)
include source provenance and outliers. Times below are milliseconds per call;
p50/p95/p99 are nearest-rank sorted indices 49/94/98.

| Fixture | Full sanitize p50 | Predicate p50 | Full sanitize p99 | Predicate p99 |
| --- | --- | --- | --- | --- |
| ordinary-code | 68.110458–69.044167 | 0.000000–0.000000 | 71.850000–73.385416 | 0.000042–0.000042 |
| leading-whitespace | 68.299833–68.694291 | 0.083708–0.085250 | 70.742000–75.419250 | 0.132542–0.181208 |
| reasoning-prefix | 121.160083–121.832542 | 0.084167–0.086959 | 124.556583–125.204584 | 0.137959–0.142917 |
| reasoning-only | 44.764250–45.042750 | 44.764375–44.909416 | 47.757334–47.902750 | 46.680709–47.135833 |
| reference-prefix | 161.511500–161.948541 | 0.085583–0.086542 | 164.612917–168.703500 | 0.133667–0.136916 |

The ordinary-code predicate median is below the stopwatch tick resolution
(about 0.000042 ms); recorded zero ticks do not mean zero execution time.
The reasoning-only control intentionally retains full cleanup, with no promised
gain and normal timing variation. These CPU benchmarks do not measure phone FPS.
Focused tests cover empty/whitespace/entity/markup prefixes and existing grouped
answers, version selection, Copy and Share behavior. A deterministic comparison
also checked eligibility and five transforms against the previous implementation
on 12,000 fresh synthetic inputs (72,000 comparisons).
