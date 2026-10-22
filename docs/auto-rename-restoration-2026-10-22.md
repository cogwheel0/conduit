# Restore chat Auto rename

The previous Auto rename service and legacy session menu still exist. The compact mobile chat actions used a generic name editor that exposed only manual input, Cancel, and Save. Chat list rows also lacked a long-press handler.

The chat dropdown and chat list's long-press menu now use the same Rename flow. Auto rename requests a title through the existing Hermes one-shot completion and places it in the editable name field. It creates no conversation messages. Save applies the reviewed name to the server and updates the open chat header; Cancel discards the draft. A late suggestion cannot overwrite manual typing or modify a dismissed editor. Connection identity and mutation admission are checked before accepting or saving a result. Errors retain manual editing and retry.

Long conversations use read-only paginated history rather than only the first 40 messages. The title request excludes tool output and takes bounded excerpts across opening, middle, and recent user/assistant exchanges, with at most 80 sampled turns and 12,000 input characters. It does not resume a runtime to generate a suggestion. Explicit Save uses the existing session-title mutation.

The existing compact sheet, 48 dp actions, Cancel/Save behavior, and motion remain. The action row wraps for large text, and the sheet scrolls when keyboard insets or a small viewport require it.

## Verification

The missing control reproduces as zero widgets named Auto rename before the restoration. The long-history regression fails before the history change because the input omits the latest decision. Both regressions pass afterward.

Twenty UI checks pass, including the actual shared menu, long-press entry, generated draft review, Cancel and late completion, suggestion failure, manual edits during generation, active header updates, light/dark rendering, 2x text, keyboard/small-screen scrolling, conversation header/drawer behavior, and compact menu anchoring. Two focused one-shot/history tests pass. Analysis reports no issues in seven affected files.

The broader desktop turn-state file passes 24 tests and fails six bot-registry tests. Running the same six tests with the original title-generation and rename-provider methods restores the same failures. Those bot-registry paths are outside this change and remain unresolved.

Build preparation and physical-device results are recorded separately. Local APKs, device captures, and runtime logs are not part of this source commit.
