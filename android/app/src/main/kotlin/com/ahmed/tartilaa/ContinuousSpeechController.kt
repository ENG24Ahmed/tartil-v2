package com.ahmed.tartilaa

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicReference

/**
 * Keeps a single, truly-continuous audio capture running for the whole session
 * and rotates the underlying [SpeechRecognizer] transparently whenever it
 * completes or times-out internally.
 *
 * On Android 13+ (API 33) we use `RecognizerIntent.EXTRA_AUDIO_SOURCE` to pipe a
 * [AudioRecord]-driven stream into the recognizer. This means the microphone
 * hardware is NEVER re-configured between rotations, eliminating the audible
 * "cut" and the flood of `AidlConversionCppNdk` warnings.
 *
 * On older devices we transparently fall back to the classic `startListening`
 * rotation approach (same behavior as before).
 */
class ContinuousSpeechController(
    private val context: Context,
    private val onEvent: (Map<String, Any?>) -> Unit,
) {

    companion object {
        private const val SAMPLE_RATE = 16_000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_ENCODING = AudioFormat.ENCODING_PCM_16BIT

        /**
         * Hints to [SpeechRecognizer] so pauses (e.g. between ayahs) rarely finalize
         * an utterance. OEMs may cap or ignore.
         */
        private const val CONTINUOUS_COMPLETE_SILENCE_MS = 180_000L
        private const val CONTINUOUS_POSSIBLE_SILENCE_MS = 180_000L
        private const val CONTINUOUS_MIN_SPEECH_LENGTH_MS = 400L

        /** Legacy path: restart listening as soon as the main looper allows. */
        private const val LEGACY_RESTART_AFTER_RESULTS_MS = 16L
        private const val LEGACY_RESTART_SOFT_ERROR_MS = 48L
        private const val LEGACY_RESTART_BUSY_MS = 80L
        private const val LEGACY_RESTART_HARD_ERROR_MS = 240L
        private const val LEGACY_RESTART_RETRY_MS = 400L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    // ---- Session state -----------------------------------------------------
    @Volatile private var continuousMode: Boolean = false
    @Volatile private var manualStopRequested: Boolean = false
    @Volatile private var listeningStatusSent: Boolean = false

    private var locale: String = "ar"
    private var partialResults: Boolean = true

    // ---- Recognizer --------------------------------------------------------
    private var speechRecognizer: SpeechRecognizer? = null
    private var lastListeningIntent: Intent? = null
    @Volatile private var rotationInFlight: Boolean = false
    @Volatile private var pendingPipeRotation: Boolean = false
    private val pipeRotationLock = Any()
    @Volatile private var usingAudioPipe: Boolean = false

    // ---- Continuous audio capture (API 33+) --------------------------------
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing: Boolean = false
    private val currentWriter = AtomicReference<OutputStream?>(null)
    private var currentReadFd: ParcelFileDescriptor? = null

    // Used by the fallback (API < 33) path
    private val restartHandler = Handler(Looper.getMainLooper())
    @Volatile private var restartScheduled = false
    @Volatile private var pendingLegacyRestart: Boolean = false
    private val legacyRestartLock = Any()

    // ----------------------------------------------------------------------
    //                              PUBLIC API
    // ----------------------------------------------------------------------
    fun isAvailable(): Boolean = SpeechRecognizer.isRecognitionAvailable(context)

    fun hasPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Starts a new recognition session. Any prior session is torn down first.
     * Returns `null` on success or a Flutter-facing error code on failure.
     */
    fun start(locale: String, partialResults: Boolean, continuous: Boolean): Pair<String, String>? {
        if (!isAvailable()) return "not_available" to "Speech recognition is unavailable."
        if (!hasPermission()) return "missing_permission" to "Microphone permission not granted."

        this.locale = locale
        this.partialResults = partialResults
        this.continuousMode = continuous
        this.manualStopRequested = false
        this.listeningStatusSent = false

        // Kill any prior state first (both paths).
        teardownInternal(notifyStopped = false)

        val useNativePipe = continuous && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        usingAudioPipe = useNativePipe
        return if (useNativePipe) {
            try {
                startContinuousCapture()
                rotateRecognizerWithPipe(firstStart = true)
                null
            } catch (e: Exception) {
                teardownInternal(notifyStopped = false)
                "start_failed" to (e.localizedMessage ?: "Failed to start continuous capture.")
            }
        } else {
            try {
                startLegacyRecognition()
                null
            } catch (e: Exception) {
                teardownInternal(notifyStopped = false)
                "start_failed" to (e.localizedMessage ?: "Failed to start speech recognition.")
            }
        }
    }

    fun stop() {
        manualStopRequested = true
        continuousMode = false
        try {
            speechRecognizer?.stopListening()
        } catch (_: Exception) {}
        teardownInternal(notifyStopped = true)
    }

    fun cancel() {
        manualStopRequested = true
        continuousMode = false
        try {
            speechRecognizer?.cancel()
        } catch (_: Exception) {}
        teardownInternal(notifyStopped = true)
    }

    fun destroy() {
        manualStopRequested = true
        continuousMode = false
        teardownInternal(notifyStopped = false)
    }

    // ----------------------------------------------------------------------
    //                       NATIVE PIPE PATH (API 33+)
    // ----------------------------------------------------------------------
    @SuppressLint("MissingPermission")
    private fun startContinuousCapture() {
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_ENCODING)
        if (minBuf <= 0) throw IllegalStateException("Unsupported audio configuration")
        val bufferSize = (minBuf * 4).coerceAtLeast(8_192)

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_ENCODING,
            bufferSize,
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("AudioRecord failed to initialize")
        }
        record.startRecording()
        audioRecord = record

        capturing = true
        captureThread = Thread({
            val buf = ByteArray(bufferSize)
            while (capturing) {
                val read = try {
                    record.read(buf, 0, buf.size)
                } catch (_: Exception) {
                    -1
                }
                if (read <= 0) continue
                val writer = currentWriter.get() ?: continue
                try {
                    writer.write(buf, 0, read)
                    writer.flush()
                } catch (_: Exception) {
                    // The pipe was closed because we're rotating. Just keep reading.
                }
            }
        }, "ContinuousSpeechCapture").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopContinuousCapture() {
        capturing = false
        captureThread?.let {
            try { it.join(250) } catch (_: Exception) {}
        }
        captureThread = null
        audioRecord?.let {
            try { it.stop() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        audioRecord = null
        currentWriter.getAndSet(null)?.let {
            try { it.close() } catch (_: Exception) {}
        }
        currentReadFd?.let {
            try { it.close() } catch (_: Exception) {}
        }
        currentReadFd = null
    }

    /**
     * Creates a fresh pipe + [SpeechRecognizer] pair and hot-swaps the capture
     * writer to the new pipe. The previous writer is closed so the old recognizer
     * receives EOF and finalizes naturally.
     */
    private fun rotateRecognizerWithPipe(firstStart: Boolean) {
        if (!continuousMode || manualStopRequested || !usingAudioPipe) return
        synchronized(pipeRotationLock) {
            if (rotationInFlight) {
                pendingPipeRotation = true
                return
            }
            rotationInFlight = true
        }

        mainHandler.postAtFrontOfQueue {
            try {
                if (!continuousMode || manualStopRequested || !usingAudioPipe) return@postAtFrontOfQueue

                val pipe = ParcelFileDescriptor.createPipe()
                val readFd = pipe[0]
                val writeFd = pipe[1]

                val newWriter = ParcelFileDescriptor.AutoCloseOutputStream(writeFd)
                val oldWriter = currentWriter.getAndSet(newWriter)
                // Close old writer so the previous recognizer sees EOF
                try { oldWriter?.close() } catch (_: Exception) {}
                // Keep the read descriptor alive while this recognizer is active.
                val oldReadFd = currentReadFd
                currentReadFd = readFd

                // Tear down old recognizer instance (its final result – if any –
                // was already surfaced via onResults before we arrived here).
                try { speechRecognizer?.destroy() } catch (_: Exception) {}
                try { oldReadFd?.close() } catch (_: Exception) {}

                val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
                recognizer.setRecognitionListener(createPipeListener())
                speechRecognizer = recognizer

                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
                    putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, partialResults)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                    putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readFd)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AUDIO_ENCODING)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
                    putExtra(
                        RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                        CONTINUOUS_COMPLETE_SILENCE_MS,
                    )
                    putExtra(
                        RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                        CONTINUOUS_POSSIBLE_SILENCE_MS,
                    )
                    putExtra(
                        RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                        CONTINUOUS_MIN_SPEECH_LENGTH_MS,
                    )
                }
                lastListeningIntent = intent

                recognizer.startListening(intent)

                if (firstStart && !listeningStatusSent) {
                    listeningStatusSent = true
                    sendStatus("listening")
                }
            } catch (e: Exception) {
                fallbackToLegacyFromPipe("rotate_failed", e.localizedMessage)
            } finally {
                val needsAnother: Boolean
                synchronized(pipeRotationLock) {
                    rotationInFlight = false
                    needsAnother = pendingPipeRotation
                    pendingPipeRotation = false
                }
                if (needsAnother && continuousMode && !manualStopRequested && usingAudioPipe) {
                    rotateRecognizerWithPipe(firstStart = false)
                }
            }
        }
    }

    private fun createPipeListener(): RecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (!listeningStatusSent) {
                listeningStatusSent = true
                sendStatus("listening")
            }
        }

        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit

        override fun onError(error: Int) {
            if (manualStopRequested || !continuousMode) return
            // Soft errors (no match / speech timeout / client / busy) simply trigger
            // a silent rotation. We DO NOT surface them to Flutter so the UI never
            // flickers. Hard errors are surfaced but we still try to recover.
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                SpeechRecognizer.ERROR_CLIENT,
                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                SpeechRecognizer.ERROR_SERVER,
                SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> {
                    rotateRecognizerWithPipe(firstStart = false)
                }
                else -> {
                    // Some vendors fail with unknown/non-standard errors when
                    // EXTRA_AUDIO_SOURCE is used. Fall back to legacy path.
                    fallbackToLegacyFromPipe(errorCodeName(error), errorMessage(error))
                }
            }
        }

        override fun onResults(results: Bundle?) {
            emitRecognitionResult(results, isFinal = true)
            if (!manualStopRequested && continuousMode) {
                rotateRecognizerWithPipe(firstStart = false)
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            emitRecognitionResult(partialResults, isFinal = false)
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    // ----------------------------------------------------------------------
    //                          LEGACY PATH (API < 33)
    // ----------------------------------------------------------------------
    private fun startLegacyRecognition() {
        usingAudioPipe = false
        val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer.setRecognitionListener(createLegacyListener())
        speechRecognizer = recognizer

        val intent = buildLegacyIntent()
        lastListeningIntent = intent
        recognizer.startListening(intent)
    }

    private fun buildLegacyIntent(): Intent {
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, partialResults)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            if (continuousMode) {
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                    CONTINUOUS_COMPLETE_SILENCE_MS,
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                    CONTINUOUS_POSSIBLE_SILENCE_MS,
                )
                putExtra(
                    RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                    CONTINUOUS_MIN_SPEECH_LENGTH_MS,
                )
            }
        }
    }

    private fun createLegacyListener(): RecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            if (!listeningStatusSent) {
                listeningStatusSent = true
                sendStatus("listening")
            }
        }
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit

        override fun onError(error: Int) {
            if (manualStopRequested || !continuousMode) return
            val delay = when (error) {
                SpeechRecognizer.ERROR_CLIENT,
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> LEGACY_RESTART_BUSY_MS
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                SpeechRecognizer.ERROR_SERVER,
                SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> LEGACY_RESTART_SOFT_ERROR_MS
                else -> {
                    sendEvent(
                        mapOf(
                            "type" to "error",
                            "code" to errorCodeName(error),
                            "message" to errorMessage(error),
                        )
                    )
                    LEGACY_RESTART_HARD_ERROR_MS
                }
            }
            scheduleLegacyRestart(delay)
        }

        override fun onResults(results: Bundle?) {
            emitRecognitionResult(results, isFinal = true)
            if (!manualStopRequested && continuousMode) {
                scheduleLegacyRestart(LEGACY_RESTART_AFTER_RESULTS_MS)
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            emitRecognitionResult(partialResults, isFinal = false)
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun scheduleLegacyRestart(delayMs: Long) {
        if (!continuousMode || manualStopRequested) return
        if (lastListeningIntent == null) return
        synchronized(legacyRestartLock) {
            if (restartScheduled) {
                pendingLegacyRestart = true
                return
            }
            restartScheduled = true
        }
        restartHandler.postDelayed({
            if (!continuousMode || manualStopRequested) {
                synchronized(legacyRestartLock) {
                    restartScheduled = false
                    pendingLegacyRestart = false
                }
                return@postDelayed
            }
            val intentNow = lastListeningIntent
            if (intentNow == null) {
                synchronized(legacyRestartLock) {
                    restartScheduled = false
                    pendingLegacyRestart = false
                }
                return@postDelayed
            }
            try {
                speechRecognizer?.startListening(intentNow)
            } catch (error: Exception) {
                synchronized(legacyRestartLock) {
                    restartScheduled = false
                }
                sendEvent(
                    mapOf(
                        "type" to "error",
                        "code" to "restart_failed",
                        "message" to (error.localizedMessage ?: "Failed to restart speech recognition."),
                    )
                )
                scheduleLegacyRestart(LEGACY_RESTART_RETRY_MS)
                return@postDelayed
            }
            val chain: Boolean
            synchronized(legacyRestartLock) {
                restartScheduled = false
                chain = pendingLegacyRestart
                pendingLegacyRestart = false
            }
            if (chain && continuousMode && !manualStopRequested) {
                scheduleLegacyRestart(LEGACY_RESTART_AFTER_RESULTS_MS)
            }
        }, delayMs)
    }

    // ----------------------------------------------------------------------
    //                               COMMON
    // ----------------------------------------------------------------------
    private fun fallbackToLegacyFromPipe(code: String, message: String?) {
        if (!continuousMode || manualStopRequested) return
        if (!usingAudioPipe) return

        usingAudioPipe = false
        synchronized(legacyRestartLock) {
            restartScheduled = false
            pendingLegacyRestart = false
        }
        restartHandler.removeCallbacksAndMessages(null)
        synchronized(pipeRotationLock) {
            rotationInFlight = false
            pendingPipeRotation = false
        }

        // Tear down pipe/capture resources cleanly, then continue with legacy mode.
        try { speechRecognizer?.destroy() } catch (_: Exception) {}
        speechRecognizer = null
        lastListeningIntent = null
        currentReadFd?.let {
            try { it.close() } catch (_: Exception) {}
        }
        currentReadFd = null
        stopContinuousCapture()

        try {
            startLegacyRecognition()
        } catch (e: Exception) {
            sendEvent(
                mapOf(
                    "type" to "error",
                    "code" to code,
                    "message" to (message ?: e.localizedMessage ?: "Failed to switch speech mode."),
                )
            )
        }
    }

    private fun teardownInternal(notifyStopped: Boolean) {
        synchronized(legacyRestartLock) {
            restartScheduled = false
            pendingLegacyRestart = false
        }
        restartHandler.removeCallbacksAndMessages(null)
        synchronized(pipeRotationLock) {
            rotationInFlight = false
            pendingPipeRotation = false
        }
        usingAudioPipe = false

        try { speechRecognizer?.destroy() } catch (_: Exception) {}
        speechRecognizer = null
        lastListeningIntent = null
        currentReadFd?.let {
            try { it.close() } catch (_: Exception) {}
        }
        currentReadFd = null

        stopContinuousCapture()

        if (notifyStopped) {
            sendStatus("stopped")
        }
    }

    private fun emitRecognitionResult(bundle: Bundle?, isFinal: Boolean) {
        val texts = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        val text = texts?.firstOrNull()?.trim().orEmpty()
        if (text.isEmpty()) return
        val scores = bundle?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
        val confidence = scores?.firstOrNull()?.toDouble()
        sendEvent(
            buildMap<String, Any?> {
                put("type", "result")
                put("text", text)
                put("isFinal", isFinal)
                if (confidence != null && confidence >= 0.0) {
                    put("confidence", confidence)
                }
            }
        )
    }

    private fun sendStatus(status: String) =
        sendEvent(mapOf("type" to "status", "status" to status))

    private fun sendEvent(event: Map<String, Any?>) {
        mainHandler.post { onEvent(event) }
    }

    private fun errorCodeName(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_CLIENT -> "client"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permissions"
        SpeechRecognizer.ERROR_NETWORK -> "network"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "network_timeout"
        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        SpeechRecognizer.ERROR_SERVER -> "server"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech_timeout"
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "too_many_requests"
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "server_disconnected"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "language_not_supported"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "language_unavailable"
        else -> "unknown"
    }

    private fun errorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "Audio recording error."
        SpeechRecognizer.ERROR_CLIENT -> "Speech recognizer client error."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is missing."
        SpeechRecognizer.ERROR_NETWORK -> "Network error during recognition."
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition network timeout."
        SpeechRecognizer.ERROR_NO_MATCH -> "No spoken match was recognized."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognizer is busy."
        SpeechRecognizer.ERROR_SERVER -> "Speech recognition server error."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input was detected."
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "Too many recognition requests."
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "Speech server disconnected."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "Speech language is not supported."
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Speech language is unavailable."
        else -> "Unknown speech recognition error."
    }
}
