// Home Media addition (not part of the upstream plugin): software MPEG audio
// Layer I/II decoding for devices without such a MediaCodec decoder.
package io.flutter.plugins.videoplayer.mp2

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.decoder.DecoderException
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.decoder.SimpleDecoder
import androidx.media3.decoder.SimpleDecoderOutputBuffer
import java.io.InputStream
import java.nio.ByteOrder
import javazoom.jl.decoder.Bitstream
import javazoom.jl.decoder.Decoder
import javazoom.jl.decoder.SampleBuffer

/**
 * Decodes MPEG-1/2 audio Layer I/II ("MP2", the standard sound of DVB
 * channels) with JLayer - one frame per input buffer (as ExoPlayer's
 * MpegAudioReader delivers them) into 16-bit PCM.
 */
@OptIn(UnstableApi::class)
internal class Mp2Decoder(initialInputBufferSize: Int) :
    SimpleDecoder<DecoderInputBuffer, SimpleDecoderOutputBuffer, DecoderException>(
        // Filled by SimpleDecoder through createInputBuffer/createOutputBuffer.
        @Suppress("UNCHECKED_CAST") (arrayOfNulls<DecoderInputBuffer>(BUFFERS) as Array<DecoderInputBuffer>),
        @Suppress("UNCHECKED_CAST") (arrayOfNulls<SimpleDecoderOutputBuffer>(BUFFERS) as Array<SimpleDecoderOutputBuffer>)) {

  // JLayer's layer decoders keep the Bitstream they were made with, so one
  // Bitstream for the whole stream, fed frame by frame through [feed]. The
  // decoder also keeps the synthesis filter's state across frames.
  private var feed = FrameFeed()
  private var bitstream: Bitstream? = null
  private var decoder = Decoder()

  /** What the stream turned out to be - known after the first frame. */
  @Volatile var channels = 2
  @Volatile var sampleRate = 48000

  init {
    setInitialInputBufferSize(initialInputBufferSize)
  }

  override fun getName() = "jlayer-mp2"

  override fun createInputBuffer() = DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_DIRECT)

  override fun createOutputBuffer() = SimpleDecoderOutputBuffer { releaseOutputBuffer(it) }

  override fun createUnexpectedDecodeException(error: Throwable) = DecoderException("MP2 decoding failed", error)

  override fun decode(
      inputBuffer: DecoderInputBuffer,
      outputBuffer: SimpleDecoderOutputBuffer,
      reset: Boolean
  ): DecoderException? {
    if (reset) restart()
    val data = inputBuffer.data ?: return null
    val bytes = ByteArray(data.remaining())
    data.get(bytes)
    feed.set(bytes)
    try {
      // Made with the first frame: its constructor peeks at the start
      // (ID3 tag) and needs data there.
      val stream = bitstream ?: Bitstream(feed).also { bitstream = it }
      val header = stream.readFrame()
      if (header == null) {
        outputBuffer.shouldBeSkipped = true
        return null
      }
      val samples = decoder.decodeFrame(header, stream) as SampleBuffer
      stream.closeFrame()
      channels = samples.channelCount
      sampleRate = samples.sampleFrequency
      val count = samples.bufferLength
      val pcm = samples.buffer
      val out = outputBuffer.init(inputBuffer.timeUs, count * 2)
      out.order(ByteOrder.LITTLE_ENDIAN)
      for (i in 0 until count) out.putShort(pcm[i])
      out.flip()
    } catch (e: LinkageError) {
      // JLayer itself can't start (its tables missing): no sound - but the
      // picture plays on and the app doesn't crash.
      return DecoderException("MP2 decoder not usable", e)
    } catch (e: Exception) {
      // A damaged frame (reception): skipped, and the next one starts clean.
      outputBuffer.shouldBeSkipped = true
      restart()
    }
    return null
  }

  private fun restart() {
    feed = FrameFeed()
    bitstream = null
    decoder = Decoder()
  }

  /**
   * The current frame as a stream - at its end it reports "end of stream",
   * which JLayer takes as a valid frame end (it otherwise wants the next
   * frame's sync word right after it).
   */
  private class FrameFeed : InputStream() {
    private var data = ByteArray(0)
    private var pos = 0
    private var markPos = 0

    fun set(bytes: ByteArray) {
      data = bytes
      pos = 0
      markPos = 0
    }

    override fun read(): Int = if (pos < data.size) data[pos++].toInt() and 0xFF else -1

    override fun read(b: ByteArray, off: Int, len: Int): Int {
      if (len == 0) return 0
      val n = minOf(len, data.size - pos)
      if (n <= 0) return -1
      System.arraycopy(data, pos, b, off, n)
      pos += n
      return n
    }

    override fun available() = data.size - pos

    override fun markSupported() = true

    override fun mark(readlimit: Int) {
      markPos = pos
    }

    override fun reset() {
      pos = markPos
    }
  }

  companion object {
    private const val BUFFERS = 16
  }
}
