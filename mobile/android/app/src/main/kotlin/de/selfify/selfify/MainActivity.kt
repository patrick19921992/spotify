package de.selfify.selfify

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.util.ViewUtils

// AudioServiceActivity: nötig, damit die Wiedergabe im Hintergrund und die Benachrichtigung funktionieren
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // audio_service legt die Engine ohne Activity an – dann kennt Flutter die Bildschirmgröße nicht, und die
        // Hochformat-Sperre (Handy oder Tablet?) müsste das Fenster messen. Die echte Größe hier nachreichen.
        ViewUtils.calculateMaximumDisplayMetrics(this, flutterEngine)
    }
}
