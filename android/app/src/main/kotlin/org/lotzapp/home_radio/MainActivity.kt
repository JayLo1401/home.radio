package org.lotzapp.home_radio

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import org.lotzapp.home_radio.dab.DabUsbPlugin

// AudioServiceActivity (extends FlutterActivity) is required by the
// audio_service plugin for its MediaSession/notification integration.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(DabUsbPlugin())
    }
}
