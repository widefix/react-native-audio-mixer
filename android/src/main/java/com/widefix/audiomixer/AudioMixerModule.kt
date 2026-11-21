package com.widefix.audiomixer

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.ReturnCode
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.common.ReactConstants.TAG
import kotlinx.coroutines.*
import java.io.File
import java.net.URL
import java.util.concurrent.CountDownLatch

data class AudioTrack(
    val fileName: String,
    val url: URL,
    val internalTrackNumber: Int,
    var volume: Float = 1.0f,
    var pan: Float = 0.0f,
    var amplitudes: MutableList<Float> = MutableList(10) { 0.0f } // Initialize with 10 zeroes
)

class AudioMixerModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    companion object {
        const val NAME = "RNAudioMixer"
        const val downloadsDir = "rnAudioMixer"
    }

    init {
        System.loadLibrary("sound")
    }

    external fun testFunction(): Long
    external fun preparePlayer()
    external fun resetPlayer()
    external fun loadTrack(fileName: String): Int
    external fun getMaxPlaybackDuration(): Float
    external fun prepareStream()
    external fun pauseAudio()
    external fun resumeAudio()
    external fun getCurrentPosition(): Float
    external fun getAmplitudes(): Array<Float>
    external fun setPosition(position: Float)
    external fun setTrackVolume(trackNum: Int, volume: Float)
    external fun setTrackPan(trackNum: Int, pan: Float)

    override fun getName(): String {
        return NAME
    }

    private var isMixPaused = true
    private var audioTracks = mutableListOf<AudioTrack>()
    private var maxPlaybackDuration = 0
    private val audioManager: AudioManager by lazy {
        reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    private val scope = CoroutineScope(Dispatchers.IO)
    private var downloadDeferreds: List<Deferred<Unit>> = emptyList()
    private var amplitudeTimer: Job? = null
    private var progressUpdateTimer: Job? = null
    private var playerPrepared = false

    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> handleAudioFocusLoss()
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> handleAudioFocusLossTransient()
            AudioManager.AUDIOFOCUS_GAIN -> handleAudioFocusGain()
        }
    }

    private val lifecycleEventListener = object : LifecycleEventListener {
        override fun onHostResume() = handleAudioFocusGain()
        override fun onHostPause() = pauseAudio()
        override fun onHostDestroy() = pauseAudio()
    }

    private fun requestAudioFocus(): Boolean {
        val result = audioManager.requestAudioFocus(
            audioFocusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN
        )
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        audioManager.abandonAudioFocus(audioFocusChangeListener)
    }

    private fun handleAudioFocusLoss() {
        pauseForInterruption()
    }

    private fun handleAudioFocusLossTransient() {
        // Resumes on AUDIOFOCUS_GAIN, so JS keeps showing it as playing.
        pauseAudio()
    }

    private fun pauseForInterruption() {
        if (isMixPaused) return
        pauseAudio()
        isMixPaused = true
        amplitudeTimer?.cancel()
        progressUpdateTimer?.cancel()
        sendEvent("PlaybackPaused", null)
    }

    private fun handleAudioFocusGain() {
        if (!isMixPaused) resumeAudio()
    }

    private fun sendEvent(eventName: String, params: Any?) {
        try {
            val reactContext = reactApplicationContext
            val eventEmitter = reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)

            when (params) {
                null -> eventEmitter.emit(eventName, null)
                is String -> eventEmitter.emit(eventName, params)
                is WritableMap -> eventEmitter.emit(eventName, params)
                is WritableArray -> eventEmitter.emit(eventName, params)
                else -> {
                    // Convert other types to a JSON string as a fallback
                    eventEmitter.emit(eventName, params.toString())
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun sendArrayEvent(eventName: String, list: List<Any>) {
        val array = Arguments.createArray()
        list.forEach { item ->
            when (item) {
                is String -> array.pushString(item)
                is Int -> array.pushInt(item)
                is Double -> array.pushDouble(item)
                is Boolean -> array.pushBoolean(item)
                // Add more types as needed
                else -> array.pushString(item.toString())
            }
        }
        sendEvent(eventName, array)
    }

    private fun sendMapEvent(eventName: String, map: Map<String, Any>) {
        val writableMap = Arguments.createMap()
        map.forEach { (key, value) ->
            when (value) {
                is String -> writableMap.putString(key, value)
                is Int -> writableMap.putInt(key, value)
                is Double -> writableMap.putDouble(key, value)
                is Boolean -> writableMap.putBoolean(key, value)
                // Add more types as needed
                else -> writableMap.putString(key, value.toString())
            }
        }
        sendEvent(eventName, writableMap)
    }

    private fun sendGenAppErrors(errors: String) {
        val errorEvent = Arguments.createMap()
        errorEvent.putString("errMsg", errors)
        sendEvent("AppErrorsX", errorEvent)
    }

    private fun sendDownloadErrors(errors: String) {
        val errorEvent = Arguments.createMap()
        errorEvent.putString("errMsg", errors)
        sendEvent("DownloadErrors", errorEvent)
    }

    private fun prepareAudioPlayer() {
        preparePlayer()
    }

    @ReactMethod
    fun addListener(type: String?) {
        // Keep: Required for RN built in Event Emitter Calls.
    }

    @ReactMethod
    fun removeListeners(type: Int?) {
        // Keep: Required for RN built in Event Emitter Calls.
    }

    private fun testLibrary() {
        val expected = 17L
        val actual = testFunction()

        val testResultEvent = Arguments.createMap()
        testResultEvent.putBoolean("cpp link success", expected == actual)
        sendEvent("Library link: true", testResultEvent)
    }

    private fun prepareMixerToPlay() {
        if (requestAudioFocus()) {
            reactApplicationContext.addLifecycleEventListener(lifecycleEventListener);
            prepareStream()
            startAmplitudeUpdate()
            startProgressUpdateTimer()
        } else {
            sendGenAppErrors("Failed to gain audio focus")
        }
    }

    @ReactMethod
    fun downloadAudioFiles(urlStrings: ReadableArray) {
        resetApp()
        sendMapEvent("DownloadStart", mapOf("status" to "DownloadStart"))
        if (!playerPrepared) {
            preparePlayer()
            playerPrepared = true
        }

        var hasErrorOccurred = false

        val urls = urlStrings.toArrayList().map { it.toString() }.map {try { URL(it) } catch (e: Exception) {
            hasErrorOccurred = true
            sendDownloadErrors("Error downloading file: ${e.localizedMessage}")
            null
        } }

        scope.launch {
            downloadDeferreds.forEach { it.cancel() }
            downloadDeferreds = urls.mapIndexed { index, url ->
                async {
                    if (hasErrorOccurred) return@async

                    val file = if (url != null) { downloadFile(url, index) } else { null }

                    if (file == null || url == null) {
                        hasErrorOccurred = true
                        sendDownloadErrors("Failed to download file: ${url?.path}")
                        return@async
                    }

                    val convertedFile = convertAndAddTrack(file, url)
                    if (convertedFile == null) {
                        hasErrorOccurred = true
                        sendDownloadErrors("Failed to convert file: ${file.name}")
                        return@async
                    }
                    sendMapEvent("TrackLoaded", mapOf("name" to convertedFile.absolutePath))
                }
            }

            downloadDeferreds.awaitAll()

            withContext(Dispatchers.Main) {
                if (!hasErrorOccurred) {
                    prepareMixerToPlay()
                    val completeParams = Arguments.createMap()
                    audioTracks.forEach { track ->
                        completeParams.putString(track.url.toString(), track.fileName)
                    }
                    sendEvent("DownloadComplete", completeParams)
                    sendEvent("MixerDurationSet", getMaxPlaybackDuration())
                } else resetApp()
            }
        }
    }

    @ReactMethod
    fun togglePlay() {
        isMixPaused = !isMixPaused

        if (isMixPaused) {
            pauseAudio()
            audioTracks.forEach { track ->
                amplitudeTimer?.cancel() // Stop amplitude update
            }

            progressUpdateTimer?.cancel() // Stop progress update
        } else {
            resumeAudio()
            startAmplitudeUpdate()
            startProgressUpdateTimer()
        }
    }

    @ReactMethod
    fun setVolume(volume: Double, forFileName: String) {
        val track = audioTracks.find { it.fileName == forFileName }
        if (track == null) {
            sendGenAppErrors("Unknown mixer track")
            return
        }
        if (!volume.isFinite()) return
        track.volume = volume.toFloat().coerceIn(0f, 1f)
        setTrackVolume(track.internalTrackNumber, track.volume)
    }

    @ReactMethod
    fun setPan(pan: Double, forFileName: String) {
        val track = audioTracks.find { it.fileName == forFileName }
        if (track == null) {
            sendGenAppErrors("Unknown mixer track")
            return
        }
        // -1 = left, 0 = center, 1 = right, same as iOS.
        if (!pan.isFinite()) return
        track.pan = pan.toFloat().coerceIn(-1f, 1f)
        setTrackPan(track.internalTrackNumber, track.pan)
    }

    @ReactMethod
    fun setPlaybackPosition(progress: Double) {
        if (!progress.isFinite()) return
        setPosition(progress.coerceIn(0.0, 1.0).toFloat())
    }

    private fun startAmplitudeUpdate() {
        amplitudeTimer?.cancel()
        amplitudeTimer = scope.launch {
            while (isActive) {
                updateAmplitudes()
                delay(100) // Update every 100ms
            }
        }
    }

    private fun updateAmplitudes() {
        if (isMixPaused) return

        val amplitudes = getAmplitudes()
        audioTracks.forEachIndexed { index, track ->
            track.amplitudes.removeAt(0)
            track.amplitudes.add(if (amplitudes.getOrNull(index) == null) { 0.0f } else { amplitudes[index] })
        }

        sendTrackAmplitudeUpdates()
    }

    private fun sendTrackAmplitudeUpdates() {
        val eventParams = Arguments.createMap()
        val amplitudesMap = Arguments.createMap()
        audioTracks.forEach {
            amplitudesMap.putDouble(it.fileName, it.amplitudes.last().toDouble())
        }

        eventParams.putMap("amplitudes", amplitudesMap)
        sendEvent("TracksAmplitudes", eventParams)
    }

    private fun startProgressUpdateTimer() {
        progressUpdateTimer?.cancel() // Ensure no duplicate timers
        progressUpdateTimer = scope.launch {
            while (isActive && !isMixPaused) {
                val progress = getCurrentPosition()
                val progressEvent = Arguments.createMap()
                progressEvent.putDouble("progress", progress.toDouble())
                sendEvent("PlaybackProgress", progressEvent)
                delay(100) // Update every 100ms
            }
        }
    }

    @ReactMethod
    fun resetApp() {
        // Stop and release all media players
        resetPlayer()
        // Cancel all ongoing downloads
        downloadDeferreds.forEach { it.cancel() }
        reactApplicationContext.removeLifecycleEventListener(lifecycleEventListener)
        deleteCache(reactApplicationContext)
        audioTracks.clear()

        // Reset internal state variables
        isMixPaused = true
        maxPlaybackDuration = 0

        // Cancel and clear amplitude update timers
        amplitudeTimer?.cancel()
        amplitudeTimer = null

        // Cancel progress update timer
        progressUpdateTimer?.cancel()
        progressUpdateTimer = null

        // Abandon audio focus
        abandonAudioFocus()
    }

    private fun downloadFile(url: URL, index: Int): File? {
        return try {

            val subFolder = File(reactApplicationContext.cacheDir, downloadsDir)

            if (!subFolder.exists()) {
                subFolder.mkdirs()
            }

            val fileName = "track$index.m4a"
            val file = File(subFolder, fileName)
            url.openStream().use { input ->
                file.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            file
        } catch (e: Exception) {
            e.printStackTrace()
            sendDownloadErrors("Error downloading file: ${e.localizedMessage}")
            null
        }
    }

    private fun convertAndAddTrack(file: File, url: URL): File? {
        var convertedFile = convertFile(file)
        if (convertedFile != null) {
            addTrack(convertedFile, url)
            return convertedFile
        } else {
            return null
        }
    }

    private fun addTrack(track: File, url: URL) {
        val trackNum = loadTrack(track.absolutePath)
        if (trackNum != -1) audioTracks.add(
            AudioTrack(track.absolutePath, url, trackNum)
        )
    }

    private fun deleteCache(context: Context) {
        try {
            val downloadsFolder = File(context.cacheDir, downloadsDir)
            if (downloadsFolder.exists()) {
                deleteDir(downloadsFolder)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun deleteDir(dir: File?): Boolean {
        if (dir != null && dir.isDirectory) {
            val children = dir.list()
            for (i in children.indices) {
                val success = deleteDir(File(dir, children[i]))
                if (!success) {
                    return false
                }
            }
            return dir.delete()
        } else if (dir != null && dir.isFile) {
            return dir.delete()
        } else {
            return false
        }
    }

    private fun convertFile(
        file: File
    ): File? {
        val i = file.name.lastIndexOf('.')
        val substr = if (i > 0) { file.name.substring(0, i) } else { file.name }
        val outputFile = File(file.parent, "$substr.wav")
        val session = FFmpegKit.execute("-i $file -ar 48000 $outputFile")
        if (ReturnCode.isSuccess(session.returnCode)) {
            return outputFile
        } else {
            return null
        }
    }
}