package app.loom.messenger

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** User-selected Storage Access Framework destination; no cache or sharing. */
class LoomRecoveryExportBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var bytes: ByteArray? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") { result.notImplemented(); return }
        if (pending != null) { result.error("busy", "Export already open", null); return }
        val content = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime")
        if (content == null || content.size > 512 * 1024 ||
            name !in setOf("Loom-recovery.pdf", "Loom-recovery.loom") ||
            mime !in setOf("application/pdf", "application/json")) {
            result.error("invalid_export", "Invalid recovery export", null); return
        }
        pending = result
        bytes = content
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
                putExtra(Intent.EXTRA_TITLE, name)
            }, REQUEST)
        } catch (_: Exception) {
            clear()
            result.error("save_unavailable", "Cannot open the save dialog", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val result = pending ?: return true
        val content = bytes
        pending = null
        bytes = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || content == null) {
            content?.fill(0)
            result.success(false)
            return true
        }
        Thread {
            try {
                activity.contentResolver.openOutputStream(uri, "wt")?.use { it.write(content) }
                    ?: throw IllegalStateException("Cannot write document")
                activity.runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                activity.runOnUiThread { result.error("save_failed", "Could not save recovery file", null) }
            } finally {
                content.fill(0)
            }
        }.start()
        return true
    }

    fun dispose() {
        val result = pending
        clear()
        result?.error("cancelled", "Export cancelled", null)
    }

    private fun clear() { bytes?.fill(0); bytes = null; pending = null }
    companion object {
        private const val REQUEST = 9072
    }
}
