# Branch preview benchmark

Branch previews display at most 160 characters. Previously, building a stored
branch graph normalized whitespace across each entire message before truncating
it. The candidate reads at most 161 normalized characters, bounds individual
word matches, and keeps the existing Unicode, whitespace and ellipsis behavior.
Leading/trailing whitespace still requires trimming; multimodal text joining is
unchanged. This is not a constant-time guarantee for every input.

```sh
dart compile exe tool/benchmarks/chat_branch_preview.dart -o /path/to/preview
/path/to/preview candidate
```

For the baseline, use the same harness and dependencies with
`packages/conduit_core/lib/features/chat/services/chat_branch_service.dart`
restored from `6e51451ef4f4c2d34e8fedb85cb6b16384bb9980`. Restore the candidate
before compiling its executable. The production source is unchanged between
that baseline and the PR base `ceda30aed6d4d966855e72d92fb28701a54be8e0`.

These freshly generated synthetic fixtures contain eight messages each. Five
warmups precede 100 measured graph constructions per fixture, with output checks
outside the timer. Four sequential runs used baseline/candidate/candidate/baseline
order, without concurrent builds. [All 6,000 raw samples](chat_branch_preview_results.json)
include outliers. Nearest-rank p50/p95/p99 use sorted indices 49/94/98.

Dart 3.13.7 native AOT on macOS arm64. Ranges below span both runs of each
variant, in **milliseconds per eight-message graph**:

| Fixture | Message size | Baseline p50 | Candidate p50 | Baseline p99 | Candidate p99 |
| --- | --- | --- | --- | --- | --- |
| prose | 8 KiB | 2.546–2.663 | 0.089–0.136 | 2.848–3.030 | 0.159–0.282 |
| unbroken-token | 8 KiB | 1.712–1.824 | 0.033–0.046 | 1.930–1.968 | 0.038–0.049 |
| leading-whitespace | 8 KiB | 0.828–0.865 | 0.070–0.091 | 0.932–0.967 | 0.082–0.098 |
| trailing-whitespace | 8 KiB | 0.837–0.871 | 0.072–0.085 | 0.935–0.950 | 0.087–0.102 |
| unicode | 8 KiB | 2.965–3.009 | 0.083–0.096 | 3.243–4.421 | 0.121–0.135 |
| prose | 128 KiB | 42.380–44.379 | 0.256–0.258 | 44.411–57.674 | 0.345–0.351 |
| unbroken-token | 128 KiB | 27.096–28.296 | 0.033–0.033 | 27.874–29.784 | 0.037–0.043 |
| leading-whitespace | 128 KiB | 13.337–13.680 | 0.781–0.782 | 14.186–15.841 | 0.828–0.834 |
| trailing-whitespace | 128 KiB | 13.388–13.659 | 0.779–0.789 | 14.897–15.056 | 0.830–0.848 |
| unicode | 128 KiB | 50.284–51.673 | 0.321–0.329 | 53.173–58.375 | 0.416–0.428 |
| prose | 1024 KiB | 351.529–359.155 | 0.749–0.763 | 363.961–375.383 | 0.829–0.892 |
| unbroken-token | 1024 KiB | 222.525–224.735 | 0.033–0.033 | 229.197–233.113 | 0.037–0.042 |
| leading-whitespace | 1024 KiB | 109.247–110.049 | 6.059–6.081 | 115.114–121.177 | 6.197–6.250 |
| trailing-whitespace | 1024 KiB | 108.133–109.002 | 6.086–6.100 | 113.022–115.002 | 6.362–6.387 |
| unicode | 1024 KiB | 415.976–422.698 | 1.354–1.365 | 436.552–437.241 | 1.517–1.593 |

These isolate graph-construction CPU cost; they are not device frame-rate or
end-to-end chat-open measurements. New tests cover exact/truncated boundaries,
long unbroken tokens, Unicode whitespace and surrogate pairs; existing tests
cover graph ownership and multimodal content. A separate deterministic synthetic
comparison checked 30,000 inputs against the previous normalization algorithm.
