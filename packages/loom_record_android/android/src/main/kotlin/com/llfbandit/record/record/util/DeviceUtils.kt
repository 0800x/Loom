package com.llfbandit.record.record.util

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build

class DeviceUtils {
  companion object {
    fun listInputDevicesAsMap(context: Context): List<Map<String, Any>> {
      return listInputDevices(context).map { deviceInfoToMap(it) }
    }

    private fun listInputDevices(context: Context): List<AudioDeviceInfo> {
      val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
      val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)

      return filterSources(devices.asList())
    }

    private fun deviceInfoToMap(device: AudioDeviceInfo): Map<String, Any> {
      return mapOf(
        "id" to "${device.id}",
        "label" to device.productName,
        "type" to typeToInputDeviceType(device.type),
        "sampleRates" to device.sampleRates.toList(),
      )
    }

    private fun typeToInputDeviceType(type: Int): String {
      return when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtIn"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wiredHeadset"
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL,
        AudioDeviceInfo.TYPE_AUX_LINE -> "lineIn"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothSco"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetoothA2dp"
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> "bluetoothLe"
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
        AudioDeviceInfo.TYPE_HDMI,
        AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi"
        else -> "unknown"
      }
    }

    fun deviceInfoFromMap(context: Context, device: Map<String, String>?): AudioDeviceInfo? {
      if (device == null) return null

      return listInputDevices(context).firstOrNull {
        it.id.toString() == device["id"]
      }
    }

    @SuppressLint("MissingPermission")
    fun getDefaultInputDevice(): AudioDeviceInfo? {
      val channelConfig = AudioFormat.CHANNEL_IN_MONO
      val audioFormat = AudioFormat.ENCODING_PCM_16BIT
      val sampleRate = 8000
      val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
      if (bufferSize <= 0) return null

      val probe = try {
        AudioRecord(
          MediaRecorder.AudioSource.DEFAULT,
          sampleRate, channelConfig, audioFormat, bufferSize
        )
      } catch (_: Exception) {
        return null
      }

      if (probe.state != AudioRecord.STATE_INITIALIZED) {
        probe.release()
        return null
      }

      return try {
        probe.startRecording()
        probe.routedDevice
      } catch (_: Exception) {
        null
      } finally {
        try { probe.stop() } catch (_: Exception) {}
        probe.release()
      }
    }

    fun filterSources(devices: List<AudioDeviceInfo>): List<AudioDeviceInfo> {
      return devices.filter {
        it.isSource
          && it.type != 18 // TYPE_TELEPHONY
          && it.type != 25 // TYPE_REMOTE_SUBMIX
          && it.type != 28 // TYPE_ECHO_REFERENCE
      }
    }

    private fun typeToString(type: Int): String {
      return when (type) {
        AudioDeviceInfo.TYPE_UNKNOWN -> "unknown"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "built-in earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "built-in speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired headphones"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "line analog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line digital"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth telephony SCO"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
        AudioDeviceInfo.TYPE_HDMI -> "HDMI"
        AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI audio return channel"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB device"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB accessory"
        AudioDeviceInfo.TYPE_DOCK -> "dock"
        AudioDeviceInfo.TYPE_FM -> "FM"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "built-in microphone"
        AudioDeviceInfo.TYPE_FM_TUNER -> "FM tuner"
        AudioDeviceInfo.TYPE_TV_TUNER -> "TV tuner"
        AudioDeviceInfo.TYPE_TELEPHONY -> "telephony"
        AudioDeviceInfo.TYPE_AUX_LINE -> "auxiliary line-level connectors"
        AudioDeviceInfo.TYPE_IP -> "IP"
        AudioDeviceInfo.TYPE_BUS -> "bus"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB headset"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing aid"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "built-in speaker safe"
        AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "remote submix" // 25
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE speaker"
        28 -> "echo reference" // AudioDeviceInfo.TYPE_ECHO_REFERENCE
        AudioDeviceInfo.TYPE_HDMI_EARC -> "HDMI enhanced ARC"
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> "BLE broadcast"
        else -> "unknown=$type"
      }
    }
  }
}