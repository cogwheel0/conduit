# Clipboard eligibility and cleanup benchmarks

The footer caches whether a response has shareable text instead of preparing
and retaining its entire cleaned text. Ordinary leading text, or a plain final
line with no closing block delimiter after its text, proves that cleanup leaves
something to share. Ambiguous endings, references, entities and reasoning-only
responses retain full sanitization. Copy and Share always prepare their actual
text through the clipboard sanitizer when invoked.

Full sanitization also skips code masking when no markup opener is present.
The guard searches for marker characters, not full block patterns in unmasked
code. Literal tags still take the protected path, including repeated opening
tags with no matching closing tags. Already-guarded reference handling avoids
an extra presence check.

## Provenance and method

Candidate source and harnesses: `1ffc2b1e07cb5c710b2802d9b694dfcf1d36a9aa`. Baseline sanitizer:
`6e51451ef4f4c2d34e8fedb85cb6b16384bb9980`. Both use the same harness and dependencies. The production
baseline file is unchanged between that baseline and PR base `ceda30ae`.
Each result file records the source commit/hash, harness hash, dependency-lock
hash, runtime, commands and explicit run indices. Build metadata is recorded
once per file, outside timed code. Executable basenames are recorded; local
artifact directories do not affect the commands' arguments.

Dart 3.13.7 native AOT on macOS arm64. All fixtures are freshly generated
synthetic text, without a server. No recording or concurrent builds ran during
measurements. Correctness checks run outside the stopwatch. All outliers are
retained. Tables show milliseconds per call, with ranges across two runs of
each variant. These are CPU measurements, not phone frame-rate measurements.

## Footer eligibility

```sh
dart compile exe tool/benchmarks/clipboard_eligibility.dart -o /path/to/eligibility
/path/to/eligibility
```

The harness executes full/predicate/predicate/full in one binary. Both paths use
the final candidate sanitizer, isolating the incremental eligibility improvement.
Five 1 MiB fixtures have five warmups and 100 calls per pass.
[All 2,000 samples](clipboard_eligibility_results.json) include p50/p95/p99;
nearest-rank sorted indices are 49/94/98.

| Fixture | Full sanitize p50 | Predicate p50 | Full sanitize p99 | Predicate p99 |
| --- | --- | --- | --- | --- |
| ordinary-code | 66.393458–66.810208 | 0.000000–0.000041 | 68.806792–77.386708 | 0.000042–0.000042 |
| leading-whitespace | 66.369167–66.751000 | 0.080375–0.086000 | 68.144708–68.355500 | 0.158417–0.160917 |
| reasoning-prefix | 121.937333–122.371500 | 0.084042–0.084458 | 124.214208–124.259750 | 0.131333–0.144417 |
| reasoning-only | 44.201167–44.213542 | 44.323083–44.353750 | 45.277750–45.476667 | 45.760042–45.771375 |
| reference-prefix | 160.052166–160.079917 | 0.084500–0.088041 | 162.427125–173.696667 | 0.133292–0.137500 |

The ordinary-code predicate median is below the stopwatch tick resolution
(about 0.000042 ms); zero recorded ticks do not mean zero execution time.
Reasoning-only responses deliberately retain full cleanup, with no promised gain.

## Full clipboard cleanup

```sh
dart compile exe tool/benchmarks/markdown_sanitize.dart -o /path/to/sanitize
/path/to/sanitize candidate
```

Build both executables from the candidate harness. For the baseline, restore
only `packages/conduit_markdown/lib/src/markdown_preprocessor.dart` from the
baseline commit in an isolated checkout, compile, then restore the candidate
source and compile its executable. Preserve the same dependency lock and SDK.
The recorded run order and arguments were:

```sh
./sanitize-marker-baseline a1
./sanitize-marker-candidate b1
./sanitize-marker-candidate b2
./sanitize-marker-baseline a2
```

Six fixtures at three sizes have five warmups and fifty measured calls per run.
Whole units are repeated to keep fences intact. [All 3,600 samples](markdown_sanitize_results.json)
include p50/p95/p99. Nearest-rank indices are 24/47/49, so p99 is the maximum
with fifty samples.

| Fixture | Target size | Baseline p50 | Candidate p50 | Baseline p99 | Candidate p99 |
| --- | --- | --- | --- | --- | --- |
| prose | 8 KiB | 1.231–1.260 | 0.462–0.558 | 1.306–1.541 | 0.500–0.708 |
| code | 8 KiB | 1.109–1.131 | 0.498–0.501 | 1.231–1.250 | 0.553–0.691 |
| reasoning-and-code | 8 KiB | 0.893–0.921 | 0.711–0.718 | 0.984–1.076 | 0.812–0.837 |
| tools-and-code | 8 KiB | 1.053–1.110 | 1.094–1.099 | 1.206–1.220 | 1.179–1.192 |
| literal-markup-in-code | 8 KiB | 0.799–0.837 | 0.828–0.853 | 0.892–0.959 | 0.896–0.917 |
| literal-openers-in-code | 8 KiB | 0.765–0.791 | 0.796–0.799 | 0.893–0.904 | 0.892–0.905 |
| prose | 128 KiB | 18.972–19.531 | 7.450–7.468 | 20.071–27.849 | 7.935–7.977 |
| code | 128 KiB | 17.888–18.569 | 8.041–8.166 | 18.934–19.135 | 8.518–8.566 |
| reasoning-and-code | 128 KiB | 14.433–14.724 | 11.310–11.386 | 15.336–15.855 | 11.781–11.820 |
| tools-and-code | 128 KiB | 17.550–18.015 | 17.761–17.858 | 18.288–18.498 | 18.212–18.341 |
| literal-markup-in-code | 128 KiB | 13.094–13.489 | 13.313–13.385 | 14.094–34.607 | 13.702–13.827 |
| literal-openers-in-code | 128 KiB | 12.488–12.850 | 12.615–12.724 | 13.069–13.365 | 12.958–12.977 |
| prose | 1024 KiB | 153.837–157.022 | 59.810–59.828 | 157.871–160.961 | 61.378–62.064 |
| code | 1024 KiB | 148.119–151.372 | 64.437–64.810 | 151.979–157.008 | 66.929–67.414 |
| reasoning-and-code | 1024 KiB | 119.211–121.282 | 92.769–92.830 | 123.441–123.659 | 94.297–95.807 |
| tools-and-code | 1024 KiB | 143.331–145.686 | 143.534–144.157 | 148.116–183.669 | 146.820–150.582 |
| literal-markup-in-code | 1024 KiB | 105.028–106.937 | 105.786–105.972 | 107.108–162.762 | 108.246–136.888 |
| literal-openers-in-code | 1024 KiB | 99.265–100.706 | 100.322–100.743 | 101.269–102.730 | 102.107–103.995 |

Tool markup and literal-tag controls still need code masking and show no
consistent median improvement. The results retain timing variation and tail
outliers; no uniform speedup is claimed for every input.

Regression coverage includes empty/whitespace/entity/markup prefixes, closing
tags in code, repeated literal openers, reference definitions, grouped answers,
version selection and platform failures. A deterministic comparison checked
eligibility and five transforms against the previous implementation on 12,000
fresh synthetic inputs (72,000 comparisons).
