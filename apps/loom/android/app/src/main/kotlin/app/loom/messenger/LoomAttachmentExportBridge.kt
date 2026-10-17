package app.loom.messenger

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Saves a decrypted attachment only to a destination selected by the user. */
class LoomAttachmentExportBridge(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var bytes: ByteArray? = null
    @Volatile private var generation = 0

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") { result.notImplemented(); return }
        if (pending != null) { result.error("busy", "Save dialog already open", null); return }
        val content = call.argument<ByteArray>("bytes")
        val name = call.argument<String>("name")
        if (content == null || content.isEmpty() || content.size > 128 * 1024 * 1024 ||
            name == null || name.isBlank() || name.length > 200 || name.any { it < ' ' || it in "\\/:*?\"<>|" }) {
            content?.fill(0)
            result.error("invalid_attachment", "Invalid attachment", null); return
        }
        pending = result
        bytes = content
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name)
            }, REQUEST)
        } catch (_: Exception) {
            cancel()
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
        val epoch = generation
        Thread {
            try {
                check(epoch == generation)
                activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    var offset = 0
                    while (offset < content.size) {
                        check(epoch == generation)
                        val count = minOf(65536, content.size - offset)
                        output.write(content, offset, count)
                        offset += count
                    }
                } ?: throw IllegalStateException("Cannot write document")
                activity.runOnUiThread { result.success(epoch == generation) }
            } catch (_: Exception) {
                activity.runOnUiThread { result.error("save_failed", "Could not save attachment", null) }
            } finally {
                content.fill(0)
            }
        }.start()
        return true
    }

    fun cancel() {
        generation++
        val result = pending
        pending = null
        bytes?.fill(0)
        bytes = null
        result?.success(false)
    }

    companion object { private const val REQUEST = 9073 }
}
