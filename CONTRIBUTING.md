# Contributing

Conduit is built in the open and maintained by one person. Review time is the
limit here, not ideas or code: a pull request usually takes longer to review
than it took to write. These rules keep that time for changes that can land.

## The best way to help

- **Report bugs** in
  [Issues](https://github.com/cogwheel0/conduit/issues/new/choose), with the app
  version, the platform, the kind of server or connection, and steps that
  reproduce the problem.
- **Suggest features** in
  [Ideas](https://github.com/cogwheel0/conduit/discussions/categories/ideas).
- **Point out duplicates.** Comment with a link to the original issue or PR.
- **Confirm fixes.** If an open issue no longer happens on the latest release,
  say so and give the version.
- **Test an open PR.** If one covers your bug, try it and comment with what you
  saw. That is worth more than a second PR for the same thing, so search the
  open PRs before you start.

## What a pull request can be

### A bug fix

A crash, a regression, wrong behavior, or a real performance problem. A small
fix for an obvious bug needs no issue. For a larger one, link the issue that
shows the bug.

### A feature the maintainer agreed to

A change to how the app behaves is a feature, even when the PR calls it a fix.
That covers new settings, new screens, new backends or providers, redesigns,
and new platforms. Open an issue or an Ideas discussion first and wait for the
maintainer to say yes there. Link it from the PR. A feature PR without that
agreement will be closed, however good the code is, because the direction has
to be settled before the review starts.

## Rules for every pull request

These apply to drafts too. A PR that follows them can still be declined.

<a id="one-problem"></a>

### One problem per PR

Fix one problem. Include every change that fix needs across the app, the
packages, both platforms, the translations, the tests, and the docs. Cleanup,
refactors, dependency bumps, and a second fix go in their own PRs.

<a id="verification"></a>

### Show that it works

Say how you found the problem, how you checked the fix, and what you saw.
"Tests pass" is not evidence.

- Logic, data, and protocol bugs come with a test that fails without the fix.
  [docs/internals/testing.md](docs/internals/testing.md) says what to test and
  what to leave out.
- UI changes need before and after screenshots. Add a short recording when the
  change is about motion or timing. Upload them to the PR; do not commit them.
- Say which platforms and which kinds of connection you tried, and which you
  could not.
- Run `dart run tool/check_changed.dart` before you push. CI runs the full
  suites.

<a id="privacy"></a>

### Keep private things out

Nothing in the diff, the description, or the attachments may show a real chat,
prompt, response, server address, credential, or other personal detail, yours
or anyone else's. Screenshots, recordings, fixtures, and examples use invented
content.

<a id="ai"></a>

### Say when an agent wrote it

Code written with an AI agent is welcome and held to the same rules. If an
agent wrote any of the code, end the PR description with the model and the tool
that ran it. You are still the author: read the diff, run it, and be ready to
answer questions about it. [AGENTS.md](AGENTS.md) is the guide agents follow in
this repository.

### Keep it mergeable

Rebase on `main` when your PR conflicts, and reply when a review asks for
something. A PR left conflicting or unanswered for a few weeks may be closed;
comment when you pick it up again and it can be reopened.

<a id="licensing"></a>

## Licensing your contribution

Conduit is released under [GPL-3.0](LICENSE). The maintainer also distributes
builds of it under other terms
([Enterprise and white-label](README.md#enterprise-and-white-label)). So that
both stay possible, by opening a pull request you:

- confirm that you wrote the contribution, or have the right to submit it;
- license it to everyone under GPL-3.0, like the rest of the project; and
- grant the maintainer a perpetual, worldwide, non-exclusive, royalty-free,
  irrevocable right to use, modify, sublicense, and distribute it as part of
  Conduit under other license terms as well.

You keep the copyright in your work.

## Security

Do not open an issue for a vulnerability. See the
[security policy](.github/SECURITY.md).

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers cloning, building, and the checks
to run.
