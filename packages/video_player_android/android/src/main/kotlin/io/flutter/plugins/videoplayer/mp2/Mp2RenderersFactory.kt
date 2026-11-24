// Home Media addition (not part of the upstream plugin): software MPEG audio
// Layer I/II decoding for devices without such a MediaCodec decoder.
package io.flutter.plugins.videoplayer.mp2

import android.content.Context
import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.decoder.CryptoConfig
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DecoderAudioRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector

/**
 * ExoPlayer's renderers plus [Mp2AudioRenderer] at the end: it only plays
 * what no MediaCodec decoder of the device can - Fire TV has none for MP2,
 * the sound of most satellite channels, which then stayed silent.
 */
@OptIn(UnstableApi::class)
class Mp2RenderersFactory(context: Context) : DefaultRenderersFactory(context) {
  override fun buildAudioRenderers(
      context: Context,
      extensionRendererMode: Int,
      mediaCodecSelector: MediaCodecSelector,
      enableDecoderFallback: Boolean,
      audioSink: AudioSink,
      eventHandler: Handler,
      eventListener: AudioRendererEventListener,
      out: ArrayList<Renderer>
  ) {
    super.buildAudioRenderers(
        context, extensionRendererMode, mediaCodecSelector, enableDecoderFallback, audioSink, eventHandler, eventListener, out)
    out.add(Mp2AudioRenderer(eventHandler, eventListener, audioSink))
  }
}

@OptIn(UnstableApi::class)
internal class Mp2AudioRenderer(handler: Handler?, listener: AudioRendererEventListener?, sink: AudioSink) :
    DecoderAudioRenderer<Mp2Decoder>(handler, listener, sink) {

  override fun getName() = "Mp2AudioRenderer"

  override fun supportsFormatInternal(format: Format): Int {
    val mime = format.sampleMimeType
    if (mime != MimeTypes.AUDIO_MPEG_L1 && mime != MimeTypes.AUDIO_MPEG_L2) return C.FORMAT_UNSUPPORTED_TYPE
    val pcm = Util.getPcmFormat(C.ENCODING_PCM_16BIT, format.channelCount.coerceAtLeast(1), format.sampleRate.coerceAtLeast(1))
    return if (sinkSupportsFormat(pcm)) C.FORMAT_HANDLED else C.FORMAT_UNSUPPORTED_SUBTYPE
  }

  override fun createDecoder(format: Format, cryptoConfig: CryptoConfig?): Mp2Decoder {
    val decoder = Mp2Decoder(if (format.maxInputSize != Format.NO_VALUE) format.maxInputSize else 4096)
    if (format.channelCount != Format.NO_VALUE) decoder.channels = format.channelCount
    if (format.sampleRate != Format.NO_VALUE) decoder.sampleRate = format.sampleRate
    return decoder
  }

  override fun getOutputFormat(decoder: Mp2Decoder): Format =
      Util.getPcmFormat(C.ENCODING_PCM_16BIT, decoder.channels, decoder.sampleRate)
}
