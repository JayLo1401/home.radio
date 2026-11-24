# video_player_android - Home Media's copy

Copy of [video_player_android](https://pub.dev/packages/video_player_android)
2.13.0 (BSD license, see LICENSE), without its example and tests. Used through
`dependency_overrides` in the app's pubspec.yaml.

The only change: ExoPlayer is built with `mp2/Mp2RenderersFactory` instead of
the default renderers (`texture/TextureVideoPlayer.kt`,
`platformview/PlatformViewVideoPlayer.kt`). It adds a software decoder for
MPEG audio Layer I/II (JLayer, `javazoom:jlayer` in `android/build.gradle.kts`)
behind the device's own decoders - so it only plays when the device has no MP2
decoder. Fire TV has none, and MP2 is the sound of most satellite channels.

Updating: copy the new version over this one (without `example/`,
`android/src/test/`, `test/`, `pigeons/`), then redo the two `ExoPlayer.Builder`
lines and the jlayer dependency.
