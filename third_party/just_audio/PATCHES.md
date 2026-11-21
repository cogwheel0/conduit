# just_audio 0.10.6, patched

A copy of
[`just_audio` 0.10.6](https://pub.dev/packages/just_audio/versions/0.10.6)
(ryanheise/just_audio, MIT and Apache 2.0, see `LICENSE`), taken from its
pub.dev archive (sha256
`e60aa97b233ddea025e13dfac59195207f528fa5e9e4a4a49a8c0766701e5fe6`, the hash
`pubspec.lock` recorded for 0.10.6), with one change.

## The change

`darwin/just_audio/Sources/just_audio/AudioPlayer.m`, in `onFailToComplete:` and a
new `failToComplete:error:`:

```diff
 - (void)onFailToComplete:(NSNotification *)notification {
-    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
     //NSLog(@"onFailToComplete");
+    IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
+    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
+    // AVFoundation may post this on a background thread, and Flutter events
+    // must be sent from the main thread.
+    __weak __typeof__(self) weakSelf = self;
+    dispatch_async(dispatch_get_main_queue(), ^{
+        [weakSelf failToComplete:playerItem error:error];
+    });
+}
+
+- (void)failToComplete:(IndexedPlayerItem *)playerItem error:(NSError *)error {
+    if (playerItem != _player.currentItem) return;
+    [self sendError:@((int)error.code) errorMessage:error.localizedDescription playerItem:playerItem switchToIdle:YES];
+    [_player removeAllItems];
+    // Once idle, dispose no longer ends a pending play request.
+    if (_playResult) {
+        _playResult(@{});
+        _playResult = nil;
+    }
 }
```

## Why

When AVFoundation can't decode a file part way through, it stops the player
and posts `AVPlayerItemFailedToPlayToEndTimeNotification`. Upstream observes
that notification but its handler is empty, so nothing reaches Dart:
`errorStream` stays silent, `playerStateStream` still says playing, and the
position keeps being extrapolated to the end. An embed's audio row
(`lib/shared/widgets/web_embed_media_player.dart`) then stays on Pause instead
of showing its failure with Retry.

The handler now reports the failure the way the plugin already reports an
item whose status turns to failed (`sendErrorForItem:`): an error with the
AVFoundation error code and message, the idle state, and the queue emptied.

Apple allows this notification to be posted on a thread other than the one
that registered for it, and `BetterEventChannel` calls its Flutter sink
directly, so the handler moves to the main queue first. It holds the player
weakly, and once there it does nothing if the player is gone, disposed (its
`player` is then nil), or has moved on to another item.

It also ends a pending `play()` request, as pausing and completing do. Without
that, `play()` would never return: the player is idle after the failure, and
`dispose` only ends the request when the player is not idle.

Emptying the queue matches the existing failed-status path
(`sendErrorForItem:`), so a playlist behaves as it does when an item fails to
load. With `maxSkipsOnError`, neither path can then skip to the next item,
because `seek:` refuses while idle. Conduit never sets `maxSkipsOnError`.

Android is not patched; ExoPlayer already reports such failures.

## What was left out

`README.md`, `example/` and `test/`. Everything Conduit builds from is here
unchanged apart from the lines above: `lib/`, `android/`, `darwin/` and
`pubspec.yaml`.

## Updating

If upstream reports `AVPlayerItemFailedToPlayToEndTimeNotification` as an
error, delete this directory and depend on the published package again.
Otherwise copy the new version from its pub.dev archive and apply the change
above.
