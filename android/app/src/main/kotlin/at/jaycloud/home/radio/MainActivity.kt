package at.jaycloud.home.radio

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import at.jaycloud.home.radio.dab.DabRtlSdrPlugin
import at.jaycloud.home.radio.rtlsdr.RtlSdrPlugin
import at.jaycloud.home.radio.rtlsdr.RtlSdrUsbPlugin

// AudioServiceActivity (extends FlutterActivity) is required by the
// audio_service plugin for its MediaSession/notification integration.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(RtlSdrPlugin())
        flutterEngine.plugins.add(RtlSdrUsbPlugin())
        flutterEngine.plugins.add(DabRtlSdrPlugin())
        flutterEngine.plugins.add(BackupPlugin())
    }
}
