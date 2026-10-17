package app.loom.messenger

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class LoomMapLauncher(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "choose") { result.notImplemented(); return }
        val lat = call.argument<Number>("lat")?.toDouble()
        val lon = call.argument<Number>("lon")?.toDouble()
        if (lat == null || lon == null || !lat.isFinite() || !lon.isFinite() ||
            kotlin.math.abs(lat) > 90 || kotlin.math.abs(lon) > 180) {
            result.error("invalid_coordinates", "Invalid coordinates", null); return
        }
        val geo = Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lon?q=$lat,$lon"))
        val packages = mutableSetOf<String>()
        val targets = mutableListOf<Intent>()
        @Suppress("DEPRECATION")
        fun include(intent: Intent) {
            for (info in activity.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)) {
                if (packages.add(info.activityInfo.packageName)) {
                    targets.add(Intent(intent).setComponent(ComponentName(info.activityInfo.packageName, info.activityInfo.name)))
                }
            }
        }
        include(geo)
        // Waze can advertise only its own scheme on some releases.
        include(Intent(Intent.ACTION_VIEW, Uri.parse("waze://?ll=$lat,$lon&navigate=yes")))
        include(Intent(Intent.ACTION_VIEW, Uri.parse("https://nshn.ir?lat=$lat&lng=$lon"))
            .setPackage("org.rajman.neshan.traffic.tehran.navigator"))
        if (targets.isEmpty()) { result.success(false); return }
        try {
            val chooser = Intent.createChooser(targets.first(), call.argument<String>("title") ?: "Maps")
            chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, targets.drop(1).toTypedArray())
            activity.startActivity(chooser)
            result.success(true)
        } catch (_: android.content.ActivityNotFoundException) { result.success(false) }
          catch (_: SecurityException) { result.success(false) }
    }
}
