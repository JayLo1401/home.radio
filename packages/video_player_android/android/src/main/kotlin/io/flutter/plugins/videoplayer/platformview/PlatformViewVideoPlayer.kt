// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
package io.flutter.plugins.videoplayer.platformview

import android.content.Context
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import io.flutter.plugins.videoplayer.ExoPlayerEventListener
import io.flutter.plugins.videoplayer.VideoAsset
import io.flutter.plugins.videoplayer.VideoPlayer
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks
import io.flutter.plugins.videoplayer.VideoPlayerOptions
import io.flutter.plugins.videoplayer.mp2.Mp2RenderersFactory
import io.flutter.view.TextureRegistry.SurfaceProducer
import kotlin.math.min

/**
 * A subclass of [VideoPlayer] that adds functionality related to platform view as a way of
 * displaying the video in the app.
 */
internal class PlatformViewVideoPlayer // TODO: Migrate to stable API, see
// https://github.com/flutter/flutter/issues/147039.
@OptIn(UnstableApi::class)
@VisibleForTesting
constructor(
    events: VideoPlayerCallbacks,
    mediaItem: MediaItem,
    options: VideoPlayerOptions,
    exoPlayerProvider: () -> ExoPlayer
) : VideoPlayer(events, mediaItem, options, /* surfaceProducer */ null, exoPlayerProvider) {
  override fun createExoPlayerEventListener(
      exoPlayer: ExoPlayer,
      surfaceProducer: SurfaceProducer?
  ): ExoPlayerEventListener {
    return PlatformViewExoPlayerEventListener(exoPlayer, videoPlayerEvents)
  }

  companion object {
    /**
     * Creates a platform view video player.
     *
     * @param context application context.
     * @param events event callbacks.
     * @param asset asset to play.
     * @param options options for playback.
     * @return a video player instance.
     */
    // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
    @OptIn(UnstableApi::class)
    fun create(
        context: Context,
        events: VideoPlayerCallbacks,
        asset: VideoAsset,
        options: VideoPlayerOptions
    ): PlatformViewVideoPlayer {
      return PlatformViewVideoPlayer(events, asset.mediaItem, options) {
        // Home Media: + software MP2 sound (see mp2/Mp2RenderersFactory.kt).
        val builder = ExoPlayer.Builder(context, Mp2RenderersFactory(context))
        // Home Media: playback starts after 0.5 s of picture instead of
        // ExoPlayer's 2.5 s - live TV comes in real time, so every channel
        // switch waited those 2.5 s (after a stall: 2 s instead of 5 s).
        val loadControl =
            DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                    DefaultLoadControl.DEFAULT_MIN_BUFFER_MS,
                    DefaultLoadControl.DEFAULT_MAX_BUFFER_MS,
                    /* bufferForPlaybackMs= */ 500,
                    /* bufferForPlaybackAfterRebufferMs= */ 2000)
        val backBufferDurationMs = options.backBufferDurationMs
        if (backBufferDurationMs != null) {
          require(backBufferDurationMs >= 0) { "backBufferDurationMs must be at least 0" }
          if (backBufferDurationMs > 0) {
            // Clamp the value to ensure it fits within the int range expected by
            // DefaultLoadControl.
            val backBufferInt = min(backBufferDurationMs, Int.MAX_VALUE.toLong()).toInt()
            loadControl.setBackBuffer(backBufferInt, /* retainBackBufferFromKeyframe= */ true)
          }
        }
        builder.setLoadControl(loadControl.build())
        val trackSelector = DefaultTrackSelector(context)
        builder
            .setTrackSelector(trackSelector)
            .setMediaSourceFactory(asset.getMediaSourceFactory(context))
        builder.build()
      }
    }
  }
}
