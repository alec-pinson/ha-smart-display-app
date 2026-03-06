package com.example.ha_smart_display

/**
 * JNI wrapper around the TFLM microfrontend audio feature extractor.
 *
 * Produces 40 float mel-spectrogram features every [stepSizeMs] milliseconds,
 * matching the ESPHome microWakeWord preprocessing exactly.
 *
 * NOT thread-safe — use one instance per thread.
 */
class MicroFrontend(private val sampleRate: Int = 16000, private val stepSizeMs: Int = 10) {

    private var handle: Long = 0

    init {
        handle = nativeCreate(sampleRate, stepSizeMs)
        if (handle == 0L) error("MicroFrontend: native init failed")
    }

    /**
     * Feed raw 16-bit PCM samples. Returns a list of feature frames;
     * each frame is a FloatArray of 40 mel-spectrogram values.
     */
    fun processSamples(samples: ShortArray): List<FloatArray> {
        check(handle != 0L) { "MicroFrontend already closed" }
        @Suppress("UNCHECKED_CAST")
        return nativeProcessSamples(handle, samples) as List<FloatArray>
    }

    fun reset() {
        if (handle != 0L) nativeReset(handle)
    }

    fun close() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0
        }
    }

    protected fun finalize() = close()

    companion object {
        init {
            System.loadLibrary("microfrontend")
        }

        /** Returns 0 on failure. */
        @JvmStatic external fun nativeCreate(sampleRate: Int, stepSizeMs: Int): Long
        @JvmStatic external fun nativeDestroy(handle: Long)
        @JvmStatic external fun nativeProcessSamples(handle: Long, samples: ShortArray): Any
        @JvmStatic external fun nativeReset(handle: Long)

        /** Returns true if the native library loaded successfully (arm64-v8a / x86_64 only). */
        val isSupported: Boolean by lazy {
            try { System.loadLibrary("microfrontend"); true }
            catch (_: UnsatisfiedLinkError) { false }
        }
    }
}
