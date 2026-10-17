package app.loom.messenger

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper

/** Local ringback only. Incoming sound belongs to the system notification. */
class CallRingback {
    private val handler = Handler(Looper.getMainLooper())
    private var tone: ToneGenerator? = null
    private var startedAt = 0L
    private val pulse = object : Runnable {
        override fun run() {
            val generator = tone ?: return
            // Fail closed if Dart is stalled or its engine disappears.
            if (android.os.SystemClock.elapsedRealtime() - startedAt >= 45_000L) {
                stop()
                return
            }
            if (runCatching { generator.startTone(ToneGenerator.TONE_SUP_RINGTONE, 2_000) }.getOrDefault(false).not()) {
                stop()
                return
            }
            handler.postDelayed(this, 6_000L)
        }
    }

    fun setPlaying(playing: Boolean) {
        if (!playing) {
            stop()
            return
        }
        if (tone != null) return
        // Use the call stream; do not change WebRTC's mode, route or volume.
        tone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 60)
        startedAt = android.os.SystemClock.elapsedRealtime()
        handler.post(pulse)
    }

    fun stop() {
        handler.removeCallbacks(pulse)
        val generator = tone
        tone = null
        try {
            generator?.stopTone()
        } finally {
            generator?.release()
        }
    }
}
