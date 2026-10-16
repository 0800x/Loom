package com.llfbandit.record.record.recorder

import com.llfbandit.record.record.util.Utils
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.encoder.IEncoder
import com.llfbandit.record.record.format.Format
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean


class RecordThread(
  private val config: RecordConfig,
  private val recorderListener: OnAudioRecordListener
) : EncoderListener {
  // Signals whether a recording is in progress (true) or not (false).
  private val mIsRecording = AtomicBoolean(false)
  // Signals whether a recording is paused (true) or not (false).
  private val mIsPaused = AtomicBoolean(false)
  private val mIsPausedSem = Semaphore(0, true)
  @Volatile private var mHasBeenCanceled = false

  private var mRecordThread: Thread? = null
  // Bridge for on-demand amplitude
  @Volatile private var mPcmReaderRef: PCMReader? = null

  override fun onEncoderFailure(ex: Exception) {
    stopRecording()
    recorderListener.onFailure(ex)
  }

  override fun onEncoderStream(bytes: ByteArray) {
    recorderListener.onAudioChunk(bytes)
  }

  fun isRecording(): Boolean {
    return mRecordThread != null && mIsRecording.get()
  }

  fun isPaused(): Boolean {
    return mRecordThread != null && mIsPaused.get()
  }

  fun pauseRecording() {
    if (isRecording()) {
      pauseState()
    }
  }

  fun resumeRecording() {
    if (isPaused()) {
      recordState()
    }
  }

  fun stopRecording() {
    if (isRecording()) {
      mIsRecording.set(false)
      mIsPaused.set(false)
      mIsPausedSem.release()
    }
  }

  fun cancelRecording() {
    mHasBeenCanceled = true

    if (isRecording()) {
      stopRecording()
    } else if (mRecordThread == null) {
      // Thread never started or has fully finished. stopAndRelease() won't run again.
      Utils.deleteFile(config.path)
    }
  }

  fun getAmplitude(): Double = mPcmReaderRef?.getAmplitude() ?: -160.0

  @Throws(Exception::class)
  fun startRecording() {
    Format.checkStreamSupport(config)

    val startLatch = CountDownLatch(1)

    mRecordThread = Thread {
      var pcmReader: PCMReader? = null
      var encoder: IEncoder? = null

      try {
        val (encoderImpl, format) = Format.createEncoder(config, this)

        pcmReader = PCMReader(config, format)
        pcmReader.start()

        encoder = encoderImpl
        encoder.startEncoding()

        // Publish PCMReader reference for on-demand amplitude
        mPcmReaderRef = pcmReader

        recordState()

        startLatch.countDown()

        while (isRecording()) {
          if (isPaused()) {
            recorderListener.onPause()
            mIsPausedSem.acquire()
          } else {
            val buffer = pcmReader.read()
            if (buffer.isNotEmpty()) {
              encoder.encode(buffer)
            }
          }
        }
      } catch (ex: Exception) {
        recorderListener.onFailure(ex)
      } finally {
        startLatch.countDown()
        mPcmReaderRef = null
        stopAndRelease(pcmReader, encoder)
      }
    }.apply {
      name = "RecordThread-${config.path}"
      isDaemon = true
      start()
    }

    startLatch.await()
  }

  private fun stopAndRelease(pcmReader: PCMReader?, encoder: IEncoder?) {
    try {
      try {
        pcmReader?.stop()
        pcmReader?.release()
      } catch (ex: Exception) {
        recorderListener.onFailure(ex)
      }

      try {
        encoder?.stopEncoding()
      } catch (ex: Exception) {
        recorderListener.onFailure(ex)
      }

      if (mHasBeenCanceled) {
        Utils.deleteFile(config.path)
      }
    } catch (ex: Exception) {
      recorderListener.onFailure(ex)
    } finally {
      mRecordThread = null
      recorderListener.onStop()
    }
  }

  private fun pauseState() {
    mIsRecording.set(true)
    mIsPaused.set(true)

    // pause event is fired in recording loop
  }

  private fun recordState() {
    mIsRecording.set(true)
    val wasPaused = mIsPaused.getAndSet(false)

    if (wasPaused) {
      mIsPausedSem.release()
    }

    recorderListener.onRecord()
  }
}