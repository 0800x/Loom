package app.loom.messenger

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import io.flutter.plugin.common.EventChannel
import kotlin.math.PI

/** Fused gyro orientation, no permission or background sampling. */
class LoomWallpaperMotion(private val activity: Activity) : EventChannel.StreamHandler, SensorEventListener {
    private val manager = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private var neutral: FloatArray? = null
    private var lastTick = 0L
    private var lastRotation = -1
    private val matrix = FloatArray(9)
    private val mapped = FloatArray(9)
    private val angles = FloatArray(3)
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        sink = events
        start()
    }
    fun start() {
        if (sink == null) return
        manager.unregisterListener(this)
        neutral = null
        lastTick = 0L
        val sensor = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        if (sensor == null || !manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)) {
            sink?.endOfStream()
            sink = null
        }
    }
    fun pause() { manager.unregisterListener(this); neutral = null }
    fun stop() { pause(); sink = null }
    override fun onCancel(arguments: Any?) = stop()
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    override fun onSensorChanged(event: SensorEvent) {
        if (sink == null || event.timestamp - lastTick < 33_000_000L) return
        lastTick = event.timestamp
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        @Suppress("DEPRECATION")
        val rotation = activity.windowManager.defaultDisplay.rotation
        if (rotation != lastRotation) { neutral = null; lastRotation = rotation }
        val axes = when (rotation) {
            Surface.ROTATION_90 -> Pair(SensorManager.AXIS_Y, SensorManager.AXIS_MINUS_X)
            Surface.ROTATION_180 -> Pair(SensorManager.AXIS_MINUS_X, SensorManager.AXIS_MINUS_Y)
            Surface.ROTATION_270 -> Pair(SensorManager.AXIS_MINUS_Y, SensorManager.AXIS_X)
            else -> Pair(SensorManager.AXIS_X, SensorManager.AXIS_Y)
        }
        SensorManager.remapCoordinateSystem(matrix, axes.first, axes.second, mapped)
        SensorManager.getOrientation(mapped, angles)
        val origin = neutral ?: angles.copyOf().also { neutral = it }
        fun tilt(index: Int): Double {
            var delta = (angles[index] - origin[index]).toDouble()
            while (delta > PI) delta -= 2 * PI
            while (delta < -PI) delta += 2 * PI
            return (delta / .4).coerceIn(-1.0, 1.0)
        }
        sink?.success(listOf(tilt(2), -tilt(1)))
    }
}
