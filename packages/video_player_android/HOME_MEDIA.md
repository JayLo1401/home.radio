# video_player_android - Home Media's copy

Copy of [video_player_android](https://pub.dev/packages/video_player_android)
2.13.0 (BSD license, see LICENSE), without its example and tests. Used through
`dependency_overrides` in the app's pubspec.yaml.

Changes:

1. ExoPlayer is built with `mp2/Mp2RenderersFactory` instead of
the default renderers (`texture/TextureVideoPlayer.kt`,
`platformview/PlatformViewVideoPlayer.kt`). It adds a software decoder for
MPEG audio Layer I/II (JLayer, `javazoom:jlayer` in `android/build.gradle.kts`)
behind the device's own decoders - so it only plays when the device has no MP2
decoder. Fire TV has none, and MP2 is the sound of most satellite channels.

2. A film whose picture ExoPlayer can't show no longer crashes the app, and
   the app learns about it (the films' player then hands the file to libmpv):
   - `ExoPlayerEventListener.kt` (`maybeSendInitialized`, `unplayableVideo`):
     if the stream has video tracks but none is selected (no decoder on the
     device takes them - DivX 3 / MS-MPEG4, WMV, ...), an error event
     ("no decoder for the video (<mime>)") is sent instead of
     "initialized" - ExoPlayer would otherwise play the sound alone.
   - `platformview/PlatformViewExoPlayerEventListener.kt` (`sendInitialized`):
     without a video format (a stream without picture) it reports the size
     0x0 instead of throwing `IllegalStateException("sendInitialized called
     with no video playing")`, which crashed the app. The texture variant
     already reported 0x0 there.

Updating: copy the new version over this one (without `example/`,
`android/src/test/`, `test/`, `pigeons/`), then redo the two `ExoPlayer.Builder`
lines and the jlayer dependency, and the changes of 2. (search for
"Home Media" in the Kotlin files).
