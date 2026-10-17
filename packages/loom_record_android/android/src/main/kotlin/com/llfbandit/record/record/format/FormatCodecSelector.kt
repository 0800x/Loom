package com.llfbandit.record.record.format

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Range
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.util.DeviceUtils
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.encoder.IEncoder
import com.llfbandit.record.record.encoder.MediaCodecEncoder
import com.llfbandit.record.record.encoder.PassthroughEncoder

internal object FormatCodecSelector {
  fun findCodec(
    format: Format,
    config: RecordConfig,
    listener: EncoderListener
  ): Pair<IEncoder, MediaFormat> {

    // Clamp config to device caps.
    adjustToDeviceCapabilities(config)

    // Load MediaFormat from given config and adjust it from codec caps.
    val mediaFormat = format.getMediaFormat(config)

    if (format.mimeTypeAudio == MediaFormat.MIMETYPE_AUDIO_RAW) {
      syncConfig(config, mediaFormat)
      return Pair(PassthroughEncoder(config, format, mediaFormat, listener), mediaFormat)
    }

    val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)

    for (info in codecs.codecInfos) {
      if (!info.isEncoder) continue

      try {
        val caps = info.getCapabilitiesForType(format.mimeTypeAudio)
        if (caps != null && adjustToCapabilities(caps, config, mediaFormat)) {
          return Pair(MediaCodecEncoder(config, format, mediaFormat, listener, info.name), mediaFormat)
        }
      } catch (_: IllegalArgumentException) {
        // type not supported by this codec
      }
    }

    throw Exception("No codec found for given config $mediaFormat. You should try with other values.")
  }

  /**
   * Attempts to adjust [mediaFormat] to fit within device and codec [caps].
   * On success, [config] is updated to reflect the adjusted values.
   * Returns true if the format is supported after adjustment.
   */
  private fun adjustToCapabilities(
    caps: MediaCodecInfo.CodecCapabilities,
    config: RecordConfig,
    mediaFormat: MediaFormat
  ): Boolean {
    var supported = caps.isFormatSupported(mediaFormat)

    if (!supported) {
      val audioCapabilities = caps.audioCapabilities

      if (audioCapabilities != null) {
        mediaFormat.setInteger(
          MediaFormat.KEY_BIT_RATE,
          checkBounds(audioCapabilities.bitrateRange, mediaFormat.getInteger(MediaFormat.KEY_BIT_RATE))
        )
        if (audioCapabilities.supportedSampleRates != null) {
          mediaFormat.setInteger(
            MediaFormat.KEY_SAMPLE_RATE,
            nearestValue(audioCapabilities.supportedSampleRates, mediaFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE))
          )
        }
        mediaFormat.setInteger(
          MediaFormat.KEY_CHANNEL_COUNT,
          checkBounds(Range(1, audioCapabilities.maxInputChannelCount), mediaFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
        )
      }

      supported = caps.isFormatSupported(mediaFormat)
    }

    if (supported) {
      syncConfig(config, mediaFormat)
    }

    return supported
  }

  private fun adjustToDeviceCapabilities(config: RecordConfig) {
    val device = config.device ?: DeviceUtils.getDefaultInputDevice()

    device?.let {
      // PCMReader only supports mono or stereo; ignore any device channel counts above 2.
      val deviceChannelCounts = it.channelCounts.filter { c -> c <= 2 }.toIntArray()
      if (deviceChannelCounts.isNotEmpty()) {
        config.numChannels = nearestValue(deviceChannelCounts, config.numChannels)
      }
    }
  }

  private fun syncConfig(config: RecordConfig, mediaFormat: MediaFormat) {
    config.sampleRate = mediaFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    config.numChannels = mediaFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    if (mediaFormat.containsKey(MediaFormat.KEY_BIT_RATE)) {
      config.bitRate = mediaFormat.getInteger(MediaFormat.KEY_BIT_RATE)
    }
  }

  private fun checkBounds(range: Range<Int>, value: Int): Int {
    if (range.lower > value) return range.lower
    if (range.upper < value) return range.upper
    return value
  }
}
