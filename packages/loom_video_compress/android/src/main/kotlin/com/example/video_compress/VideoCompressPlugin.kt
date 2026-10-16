package com.example.video_compress

import android.content.Context
import android.media.MediaFormat
import android.media.MediaCodecInfo
import android.media.MediaMetadataRetriever
import com.otaliastudios.transcoder.common.TrackStatus
import android.net.Uri
import android.util.Log
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.source.TrimDataSource
import com.otaliastudios.transcoder.source.UriDataSource
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import com.otaliastudios.transcoder.strategy.RemoveTrackStrategy
import com.otaliastudios.transcoder.strategy.TrackStrategy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import com.otaliastudios.transcoder.internal.utils.Logger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Future

/**
 * VideoCompressPlugin
 */
class VideoCompressPlugin : MethodCallHandler, FlutterPlugin {


    private var _context: Context? = null
    private var _channel: MethodChannel? = null
    private val TAG = "VideoCompressPlugin"
    private val LOG = Logger(TAG)
    private var transcodeFuture:Future<Void>? = null
    var channelName = "video_compress"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = _context;
        val channel = _channel;

        if (context == null || channel == null) {
            Log.w(TAG, "Calling VideoCompress plugin before initialization")
            return
        }

        when (call.method) {
            "normalizeVideoNote" -> normalizeVideoNote(context, call, result)
            "getByteThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility(channelName).getByteThumbnail(path!!, quality, position.toLong(), result)
            }
            "getFileThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility("video_compress").getFileThumbnail(context, path!!, quality,
                        position.toLong(), result)
            }
            "getMediaInfo" -> {
                val path = call.argument<String>("path")
                result.success(Utility(channelName).getMediaInfoJson(context, path!!).toString())
            }
            "deleteAllCache" -> {
                result.success(Utility(channelName).deleteAllCache(context, result));
            }
            "setLogLevel" -> {
                val logLevel = call.argument<Int>("logLevel")!!
                Logger.setLogLevel(logLevel)
                result.success(true);
            }
            "cancelCompression" -> {
                transcodeFuture?.cancel(true)
                result.success(false);
            }
            "compressVideo" -> {
                val path = call.argument<String>("path")!!
                val quality = call.argument<Int>("quality")!!
                val deleteOrigin = call.argument<Boolean>("deleteOrigin")!!
                val startTime = call.argument<Int>("startTime")
                val duration = call.argument<Int>("duration")
                val includeAudio = call.argument<Boolean>("includeAudio") ?: true
                val frameRate = if (call.argument<Int>("frameRate")==null) 30 else call.argument<Int>("frameRate")

                val tempDir: String = context.getExternalFilesDir("video_compress")!!.absolutePath
                val out = SimpleDateFormat("yyyy-MM-dd hh-mm-ss").format(Date())
                val destPath: String = tempDir + File.separator + "VID_" + out + path.hashCode() + ".mp4"

                var videoTrackStrategy: TrackStrategy = DefaultVideoStrategy.atMost(340).build();
                val audioTrackStrategy: TrackStrategy

                when (quality) {

                    0 -> {
                      videoTrackStrategy = DefaultVideoStrategy.atMost(720).build()
                    }

                    1 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(360).build()
                    }
                    2 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(720).frameRate(frameRate ?: 24).build()
                    }
                    3 -> {

                        assert(value = frameRate != null)
                        videoTrackStrategy = DefaultVideoStrategy.Builder()
                                .keyFrameInterval(3f)
                                .bitRate(1280 * 720 * 4.toLong())
                                .frameRate(frameRate!!) // will be capped to the input frameRate
                                .build()
                    }
                    4 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(480, 640).build()
                    }
                    5 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(540, 960).build()
                    }
                    6 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(720, 1280).build()
                    }
                    7 -> {
                        videoTrackStrategy = DefaultVideoStrategy.atMost(1080, 1920).build()
                    }                    
                }

                audioTrackStrategy = if (includeAudio) {
                    val sampleRate = DefaultAudioStrategy.SAMPLE_RATE_AS_INPUT
                    val channels = DefaultAudioStrategy.CHANNELS_AS_INPUT

                    DefaultAudioStrategy.builder()
                        .channels(channels)
                        .sampleRate(sampleRate)
                        .build()
                } else {
                    RemoveTrackStrategy()
                }

                val sourceUri = if (path.startsWith("content:") || path.startsWith("file:")) {
                    Uri.parse(path)
                } else {
                    Uri.fromFile(File(path))
                }
                val dataSource = if (startTime != null || duration != null){
                    val source = UriDataSource(context, sourceUri)
                    TrimDataSource(source, (1000 * 1000 * (startTime ?: 0)).toLong(), (1000 * 1000 * (duration ?: 0)).toLong())
                }else{
                    UriDataSource(context, sourceUri)
                }


                transcodeFuture = Transcoder.into(destPath!!)
                        .addDataSource(dataSource)
                        .setAudioTrackStrategy(audioTrackStrategy)
                        .setVideoTrackStrategy(videoTrackStrategy)
                        .setListener(object : TranscoderListener {
                            override fun onTranscodeProgress(progress: Double) {
                                channel.invokeMethod("updateProgress", progress * 100.00)
                            }
                            override fun onTranscodeCompleted(successCode: Int) {
                                channel.invokeMethod("updateProgress", 100.00)
                                val json = Utility(channelName).getMediaInfoJson(context, destPath)
                                json.put("isCancel", false)
                                result.success(json.toString())
                                if (deleteOrigin) {
                                    File(path).delete()
                                }
                            }

                            override fun onTranscodeCanceled() {
                                result.success(null)
                            }

                            override fun onTranscodeFailed(exception: Throwable) {
                                result.success(null)
                            }
                        }).transcode()
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    // Isolated from ordinary compression: cropping a note cannot cancel a
    // selected attachment's export. Always encode, including small inputs.
    private val noteJobs = mutableSetOf<Future<Void>>()
    private fun normalizeVideoNote(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: return result.error("invalid_input", "Missing input", null)
        val output = call.argument<String>("output") ?: return result.error("invalid_input", "Missing output", null)
        val destination = File(output)
        val root = File(context.cacheDir, "loom_media_record").canonicalFile
        val target = destination.canonicalFile
        if (!target.path.startsWith(root.path + File.separator) || target == File(path).canonicalFile) {
            return result.error("invalid_output", "Output must be a private recording file", null)
        }
        val video = TrackStrategy { _, format ->
            format.setString(MediaFormat.KEY_MIME, "video/avc")
            format.setInteger(MediaFormat.KEY_WIDTH, 640)
            format.setInteger(MediaFormat.KEY_HEIGHT, 480)
            format.setInteger("rotation-degrees", 0)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            format.setInteger(MediaFormat.KEY_BIT_RATE, 1_200_000)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            TrackStatus.COMPRESSING
        }
        var job: Future<Void>? = null
        fun finish() { job?.let { noteJobs.remove(it) } }
        try {
            job = Transcoder.into(output)
                .addDataSource(context, Uri.fromFile(File(path)))
                .setVideoTrackStrategy(video)
                .setAudioTrackStrategy(DefaultAudioStrategy.builder().build())
                .setListener(object : TranscoderListener {
                    override fun onTranscodeProgress(progress: Double) {}
                    override fun onTranscodeCompleted(successCode: Int) {
                        finish()
                        val metadata = MediaMetadataRetriever()
                        try {
                            metadata.setDataSource(output)
                            val width = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                            val height = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                            val rotation = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                            if (width != 640 || height != 480 || rotation != 0) {
                                destination.delete()
                                result.error("invalid_geometry", "Video note encoder returned unexpected geometry", null)
                            } else result.success(mapOf("path" to output, "width" to width, "height" to height, "rotation" to rotation))
                        } catch (_: Exception) {
                            destination.delete()
                            result.error("invalid_geometry", "Could not verify encoded video", null)
                        } finally { metadata.release() }
                    }
                    override fun onTranscodeCanceled() {
                        finish(); destination.delete()
                        result.error("cancelled", "Video note processing cancelled", null)
                    }
                    override fun onTranscodeFailed(exception: Throwable) {
                        finish(); destination.delete()
                        result.error("encoding_failed", "Could not prepare video note", null)
                    }
                }).transcode()
            noteJobs.add(job!!)
        } catch (_: Exception) {
            destination.delete()
            result.error("encoding_failed", "Could not start video note processing", null)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        init(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        noteJobs.toList().forEach { it.cancel(true) }
        noteJobs.clear()
        _channel?.setMethodCallHandler(null)
        _context = null
        _channel = null
    }

    private fun init(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, channelName)
        channel.setMethodCallHandler(this)
        _context = context
        _channel = channel
    }

    companion object {
        private const val TAG = "video_compress"
    }

}
