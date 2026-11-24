# media_kit_libs_android_video - Home System's copy

Copy of [media_kit_libs_android_video](https://pub.dev/packages/media_kit_libs_android_video)
1.3.8 (MIT license, see LICENSE), without its example. Used through
`dependency_overrides` in the app's pubspec.yaml.

The only change (`android/build.gradle`, `downloadDependencies`): Gradle
downloads the **"full"** flavour of
[libmpv-android-video-build](https://github.com/media-kit/libmpv-android-video-build)
**v1.1.11** instead of 1.3.8's "default" flavour of v1.1.7 (new URLs and MD5s).

Why: the films' player must play old files like VLC - RealPlayer downloads
(.rm/.rmvb), 3GP from old phones, QuickTime, AVI with odd codecs. The
"default" flavour builds FFmpeg with a short list of decoders - no RealVideo
(rv10-rv40), no Cook/Sipr (RealAudio), no AMR-NB/WB (3GP sound), no SVQ1/3,
Cinepak, VC-1, Indeo. "full" builds FFmpeg 6.0 with `--enable-decoders
--enable-demuxers --enable-parsers` (all of FFmpeg's own decoders), still
`--disable-gpl --disable-nonfree --enable-version3` (LGPL 3) and mpv
`-Dgpl=false` - same FFmpeg, mpv, libass ... versions as v1.1.7 (between
v1.1.7 and v1.1.11 only build-script fixes). libmpv.so grows from 11.7 to
15.3 MB (armeabi-v7a, uncompressed).

Licences: lib/core/third_party_licenses.dart.

Updating: copy the new version over this one (without `example/`), then put
the "full" URLs and their MD5s (`md5sum full-*.jar`) back into
`android/build.gradle`.
