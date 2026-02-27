package com.example.videocapturingapp

import android.content.ContentValues
import android.media.*
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.app/media_store"
    private val TAG = "VideoSaver"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null) { _, _ -> }
                            result.success(null)
                        } else {
                            result.error("INVALID_PATH", "Path is null", null)
                        }
                    }

                    "stitchVideos" -> {
                        val segments = call.argument<List<String>>("segments")
                        val outputPath = call.argument<String>("output")
                        if (segments == null || outputPath == null) {
                            result.error("INVALID_ARGS", "Missing segments or output", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                stitchVideos(segments, outputPath)
                                result.success(outputPath)
                            } catch (e: Exception) {
                                Log.e(TAG, "Stitch failed: ${e.message}", e)
                                result.success(segments.first())
                            }
                        }.start()
                    }

                    "saveVideoToGallery" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("INVALID_PATH", "Path is null", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val sourceFile = File(path)
                                if (!sourceFile.exists() || sourceFile.length() == 0L) {
                                    result.error("FILE_ERROR", "Source missing or empty", null)
                                    return@Thread
                                }

                                // Compress to 70% before saving
                                val compressedFile = File(cacheDir, "compressed_${System.currentTimeMillis()}.mp4")
                                val compressed = compressVideo(path, compressedFile.absolutePath)
                                val fileToSave = if (compressed && compressedFile.exists() && compressedFile.length() > 0) {
                                    Log.d(TAG, "Using compressed: ${compressedFile.length()} bytes (original: ${sourceFile.length()})")
                                    compressedFile
                                } else {
                                    Log.w(TAG, "Compression failed, using original")
                                    sourceFile
                                }

                                saveToMediaStore(fileToSave)
                                compressedFile.delete()
                                result.success("saved")

                            } catch (e: Exception) {
                                Log.e(TAG, "Save failed: ${e.message}", e)
                                result.error("SAVE_FAILED", e.message, null)
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Compresses video to ~30% of original bitrate (70% size reduction).
     * Uses MediaCodec to fully re-encode video and audio tracks.
     */
    private fun compressVideo(inputPath: String, outputPath: String): Boolean {
        try {
            val extractor = MediaExtractor()
            extractor.setDataSource(inputPath)

            // Find video and audio track info
            var videoTrackIndex = -1
            var audioTrackIndex = -1
            var videoFormat: MediaFormat? = null
            var audioFormat: MediaFormat? = null

            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                when {
                    mime.startsWith("video/") && videoTrackIndex == -1 -> {
                        videoTrackIndex = i
                        videoFormat = format
                    }
                    mime.startsWith("audio/") && audioTrackIndex == -1 -> {
                        audioTrackIndex = i
                        audioFormat = format
                    }
                }
            }

            if (videoTrackIndex == -1 || videoFormat == null) {
                extractor.release()
                return false
            }

            // Read video properties
            val width = videoFormat.getInteger(MediaFormat.KEY_WIDTH)
            val height = videoFormat.getInteger(MediaFormat.KEY_HEIGHT)
            val originalBitrate = if (videoFormat.containsKey(MediaFormat.KEY_BIT_RATE))
                videoFormat.getInteger(MediaFormat.KEY_BIT_RATE) else 4_000_000
            val frameRate = if (videoFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
                videoFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else 30

            // Target bitrate = 30% of original (70% compression)
            val targetBitrate = (originalBitrate * 0.30).toInt().coerceAtLeast(300_000)
            Log.d(TAG, "Video: ${width}x${height} | Original: ${originalBitrate/1000}kbps | Target: ${targetBitrate/1000}kbps")

            val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var muxerStarted = false
            var muxerVideoTrack = -1
            var muxerAudioTrack = -1

            // ── Set up video encoder ──────────────────────────────────────
            val encoderFormat = MediaFormat.createVideoFormat("video/avc", width, height).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, targetBitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            }

            val encoder = MediaCodec.createEncoderByType("video/avc")
            encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val encoderSurface: Surface = encoder.createInputSurface()
            encoder.start()

            // ── Set up video decoder ──────────────────────────────────────
            val decoder = MediaCodec.createDecoderByType(videoFormat.getString(MediaFormat.KEY_MIME)!!)
            decoder.configure(videoFormat, encoderSurface, null, 0)
            decoder.start()

            // ── Transcode video ───────────────────────────────────────────
            extractor.selectTrack(videoTrackIndex)

            val bufferInfo = MediaCodec.BufferInfo()
            var decoderDone = false
            var encoderDone = false
            val timeoutUs = 10_000L

            while (!encoderDone) {
                // Feed decoder
                if (!decoderDone) {
                    val inIndex = decoder.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inIndex)!!
                        val sampleSize = extractor.readSampleData(buffer, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            decoderDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                // Drain decoder output -> feeds encoder surface automatically
                val outIndex = decoder.dequeueOutputBuffer(bufferInfo, timeoutUs)
                if (outIndex >= 0) {
                    val isLast = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    decoder.releaseOutputBuffer(outIndex, true) // render to surface
                    if (isLast) {
                        encoder.signalEndOfInputStream()
                    }
                }

                // Drain encoder
                val encOutIndex = encoder.dequeueOutputBuffer(bufferInfo, timeoutUs)
                when {
                    encOutIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        muxerVideoTrack = muxer.addTrack(encoder.outputFormat)
                        // Add audio track if present (copy directly, no re-encode)
                        if (audioTrackIndex >= 0 && audioFormat != null) {
                            muxerAudioTrack = muxer.addTrack(audioFormat)
                        }
                        muxer.start()
                        muxerStarted = true
                    }
                    encOutIndex >= 0 -> {
                        if (muxerStarted && bufferInfo.size > 0) {
                            val encBuffer = encoder.getOutputBuffer(encOutIndex)!!
                            muxer.writeSampleData(muxerVideoTrack, encBuffer, bufferInfo)
                        }
                        encoder.releaseOutputBuffer(encOutIndex, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            encoderDone = true
                        }
                    }
                }
            }

            decoder.stop(); decoder.release()
            encoder.stop(); encoder.release()
            encoderSurface.release()

            // ── Copy audio track directly (no re-encode needed) ───────────
            if (audioTrackIndex >= 0 && muxerAudioTrack >= 0 && muxerStarted) {
                extractor.unselectTrack(videoTrackIndex)
                extractor.selectTrack(audioTrackIndex)
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                val audioBuffer = ByteBuffer.allocate(512 * 1024)
                val audioBufInfo = MediaCodec.BufferInfo()
                val firstAudioPts = run {
                    val size = extractor.readSampleData(audioBuffer, 0)
                    if (size > 0) extractor.sampleTime else 0L
                }
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

                var lastAudioPts = -1L
                while (true) {
                    audioBufInfo.offset = 0
                    audioBufInfo.size = extractor.readSampleData(audioBuffer, 0)
                    if (audioBufInfo.size < 0) break
                    val pts = extractor.sampleTime - firstAudioPts
                    if (pts > lastAudioPts) {
                        audioBufInfo.presentationTimeUs = pts
                        audioBufInfo.flags = extractor.sampleFlags
                        muxer.writeSampleData(muxerAudioTrack, audioBuffer, audioBufInfo)
                        lastAudioPts = pts
                    }
                    extractor.advance()
                }
            }

            extractor.release()
            if (muxerStarted) { muxer.stop() }
            muxer.release()

            Log.d(TAG, "Compression done. Output size: ${File(outputPath).length()} bytes")
            return true

        } catch (e: Exception) {
            Log.e(TAG, "Compression error: ${e.message}", e)
            return false
        }
    }

    private fun saveToMediaStore(file: File) {
        val fileName = "VID_${System.currentTimeMillis()}.mp4"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, "DCIM/Camera")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("MediaStore insert returned null")
            contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(file).use { it.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } else {
            val dcim = File("/storage/emulated/0/DCIM/Camera")
            if (!dcim.exists()) dcim.mkdirs()
            val dest = File(dcim, fileName)
            file.copyTo(dest, overwrite = true)
            MediaScannerConnection.scanFile(applicationContext, arrayOf(dest.absolutePath), null) { _, _ -> }
        }
    }

    private fun stitchVideos(segments: List<String>, outputPath: String) {
        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var muxerStarted = false
        val muxerTrackMap = mutableMapOf<String, Int>()
        var timeOffsetUs = 0L

        try {
            for ((segIndex, segPath) in segments.withIndex()) {
                val segFile = File(segPath)
                if (!segFile.exists() || segFile.length() == 0L) continue

                val extractor = MediaExtractor()
                try {
                    extractor.setDataSource(segPath)
                    val segTrackMimes = mutableMapOf<Int, String>()

                    for (i in 0 until extractor.trackCount) {
                        val format = extractor.getTrackFormat(i)
                        val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                        if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                            segTrackMimes[i] = mime
                            extractor.selectTrack(i)
                            if (!muxerTrackMap.containsKey(mime)) {
                                muxerTrackMap[mime] = muxer.addTrack(format)
                            }
                        }
                    }

                    if (!muxerStarted) { muxer.start(); muxerStarted = true }

                    val buffer = ByteBuffer.allocate(2 * 1024 * 1024)
                    val bufferInfo = MediaCodec.BufferInfo()
                    val firstPtsMap = mutableMapOf<Int, Long>()
                    val lastPtsMap = mutableMapOf<Int, Long>()
                    var segMaxPts = 0L

                    while (true) {
                        bufferInfo.offset = 0
                        bufferInfo.size = extractor.readSampleData(buffer, 0)
                        if (bufferInfo.size < 0) break

                        val extractorTrack = extractor.sampleTrackIndex
                        val mime = segTrackMimes[extractorTrack] ?: run { extractor.advance(); continue }
                        val muxerTrack = muxerTrackMap[mime] ?: run { extractor.advance(); continue }

                        val rawPts = extractor.sampleTime
                        val firstPts = firstPtsMap.getOrPut(extractorTrack) { rawPts }
                        var normalizedPts = rawPts - firstPts
                        val lastPts = lastPtsMap[muxerTrack] ?: -1L
                        if (normalizedPts <= lastPts) normalizedPts = lastPts + 1
                        lastPtsMap[muxerTrack] = normalizedPts

                        bufferInfo.presentationTimeUs = normalizedPts + timeOffsetUs
                        bufferInfo.flags = extractor.sampleFlags
                        muxer.writeSampleData(muxerTrack, buffer, bufferInfo)
                        if (normalizedPts > segMaxPts) segMaxPts = normalizedPts
                        extractor.advance()
                    }

                    timeOffsetUs += segMaxPts + 33_333L
                } finally {
                    extractor.release()
                }
            }
        } finally {
            if (muxerStarted) { try { muxer.stop() } catch (_: Exception) {} }
            try { muxer.release() } catch (_: Exception) {}
        }
    }
}