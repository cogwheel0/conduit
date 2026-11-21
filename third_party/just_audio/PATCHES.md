# just_audio 0.10.6, patched

A copy of
[`just_audio` 0.10.6](https://pub.dev/packages/just_audio/versions/0.10.6)
(ryanheise/just_audio, MIT and Apache 2.0, see `LICENSE`), taken from its
pub.dev archive (sha256
`e60aa97b233ddea025e13dfac59195207f528fa5e9e4a4a49a8c0766701e5fe6`, the hash
`pubspec.lock` recorded for 0.10.6), with one change.

## The change

`darwin/just_audio/Sources/just_audio/AudioPlayer.m`, in `onFailToComplete:`:

```diff
 - (void)onFailToComplete:(NSNotification *)notification {
-    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
     //NSLog(@"onFailToComplete");
+    IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
+    if (playerItem != _player.currentItem) return;
+    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
+    [self sendError:@((int)error.code) errorMessage:error.localizedDescription playerItem:playerItem switchToIdle:YES];
+    [_player removeAllItems];
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
