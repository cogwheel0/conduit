<!--
Read CONTRIBUTING.md before opening a PR. Solve one problem. The same rules
apply to drafts. Title: one plain sentence saying what changes for the person
using the app, such as "Keep the top bars clear of a side safe area".
-->

## Problem

<!-- The problem in a sentence or two. Include what you expected and how to
reproduce it: platform, app version, and the kind of server or connection. -->

## Change

<!-- How this fixes it. If it touches more than one platform, backend, or
package, say why each part belongs to the same fix. -->

## Scope

<!-- A bug fix: link the issue, or say why an obvious small fix needs none.
A feature: link the issue or discussion where the maintainer agreed to it. -->

## Verification

<!-- The focused tests or manual checks you ran and what you saw, and anything
you could not check. "Tests pass" alone is not enough.

UI changes need before and after screenshots; add a short recording when the
change is about motion or timing. Upload them here. Do not commit them. -->

## Checklist

- [ ] Nothing in the diff, this description, or the attachments shows a real
      chat, prompt, server address, credential, or other personal detail. All
      example content is invented.
- [ ] `dart run tool/check_changed.dart` passes.
- [ ] I agree to the
      [licensing terms](https://github.com/cogwheel0/conduit/blob/main/CONTRIBUTING.md#licensing)
      for this contribution.

<!-- If an AI agent wrote any of this code, end with the model and the tool
that ran it. -->
