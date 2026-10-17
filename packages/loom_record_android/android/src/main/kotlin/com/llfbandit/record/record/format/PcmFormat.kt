package com.llfbandit.record.record.format

import android.media.MediaFormat
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.container.RawContainer

class PcmFormat : Format() {
  override val mimeTypeAudio: String = MediaFormat.MIMETYPE_AUDIO_RAW

  override fun supportsStream(config: RecordConfig): Boolean = true

  override fun getMediaFormat(config: RecordConfig): MediaFormat {
    val frameSize = config.numChannels * 16 / 8

    return MediaFormat().apply {
      setString(MediaFormat.KEY_MIME, mimeTypeAudio)
      setInteger(MediaFormat.KEY_SAMPLE_RATE, config.sampleRate)
      setInteger(MediaFormat.KEY_CHANNEL_COUNT, config.numChannels)
      setInteger(KEY_X_FRAME_SIZE_IN_BYTES, frameSize)
    }
  }

  override fun createWriter(mediaFormat: MediaFormat, path: String?): IContainerWriter {
    return RawContainer(path)
  }
}