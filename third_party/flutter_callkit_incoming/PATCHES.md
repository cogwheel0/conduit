# flutter_callkit_incoming 3.1.6, patched

A copy of
[`flutter_callkit_incoming` 3.1.6](https://pub.dev/packages/flutter_callkit_incoming/versions/3.1.6)
(hiennguyen92/flutter_callkit_incoming, MIT, see `LICENSE`), taken from its
pub.dev archive (sha256
`2d47db2e8d32d333e0352d37b0a4e643f606a54f8a541db17af7c42f18c58318`, the hash
`pubspec.lock` recorded for 3.1.6), with one change.

## The change

`ios/flutter_callkit_incoming/Classes/SwiftFlutterCallkitIncomingPlugin.swift`,
in `createConfiguration`:

```diff
-        configuration.supportedHandleTypes = [
-            CXHandle.HandleType.generic,
-            CXHandle.HandleType.emailAddress,
-            CXHandle.HandleType.phoneNumber
-        ]
+        configuration.supportedHandleTypes = [CXHandle.HandleType.generic]
```

## Why

iOS offers a CallKit provider that supports phone-number or email handles in
the call menu of every contact card. Conduit calls a model, with a generic
handle (`IOSParams.handleType: 'generic'`), so picking Conduit there only
opened the app (cogwheel0/conduit#590). Upstream registers all three types,
whatever `handleType` says.

Android is not patched. The plugin's self-managed `PhoneAccount`
(`InAppCallManager.registerPhoneAccount`) names no URI scheme, so
`PhoneAccount.Builder` gives it `tel`. The system dialer does not offer
self-managed accounts, though, so that is not clearly why Conduit showed up in
an Android call menu, and that report is unconfirmed.

## What was left out

`README.md`, `PUSHKIT.md`, `images/`, `example/` and `test/`. Everything
Conduit builds from is here unchanged apart from the line above: `lib/`
(including the generated `*.g.dart` files the package ships, which the root
`.gitignore` lets through), `android/`, `ios/` and `pubspec.yaml`.

## Updating

If upstream stops registering phone-number and email handles for an app that
asks for generic ones, delete this directory and depend on the published
package again. Otherwise copy the new version from its pub.dev archive and
apply the change above.
