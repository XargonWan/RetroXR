package com.xenu.retroxr.qr

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Reads QR codes through a Meta passthrough camera.
 *
 * Horizon OS exposes the passthrough cameras as ordinary Camera2 devices tagged
 * with vendor metadata, so this is plain Camera2 plus a ZXing decode on the Y
 * plane. Quest 3 / 3S on Horizon OS v74 or newer only.
 *
 * Frames never cross into Godot at capture size: decoding happens here, and the
 * only thing sent over is a 320x240 luma viewfinder.
 */
class QrScannerPlugin(godot: Godot) : GodotPlugin(godot) {

    private companion object {
        const val TAG = "RetroXRQr"

        const val CAPTURE_WIDTH = 1280
        const val CAPTURE_HEIGHT = 960
        const val PREVIEW_WIDTH = 320
        const val PREVIEW_HEIGHT = 240

        const val DECODE_INTERVAL_MS = 125L   // ~8 Hz
        const val PREVIEW_INTERVAL_MS = 83L   // ~12 Hz

        const val META_SOURCE = "com.meta.extra_metadata.camera_source"
        const val META_POSITION = "com.meta.extra_metadata.camera_position"
        const val SOURCE_PASSTHROUGH = 0
        const val POSITION_LEFT = 0

        val SIGNAL_FRAME = SignalInfo("qr_frame", ByteArray::class.java)
        val SIGNAL_DETECTED = SignalInfo("qr_detected", String::class.java)
        val SIGNAL_ERROR = SignalInfo("qr_error", String::class.java)
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null

    @Volatile
    private var running = false
    private var available: Boolean? = null
    private var lastDecodeMs = 0L
    private var lastPreviewMs = 0L

    private val qrReader = QRCodeReader()
    private val hints = mapOf<DecodeHintType, Any>(DecodeHintType.TRY_HARDER to true)

    override fun getPluginName() = "RetroXRQr"

    override fun getPluginSignals(): Set<SignalInfo> =
        setOf(SIGNAL_FRAME, SIGNAL_DETECTED, SIGNAL_ERROR)

    // The camera must not survive the app going to the background: an open
    // handle keeps the Horizon OS privacy indicator lit and drains the battery.
    override fun onMainPause() = stopScan()

    override fun onMainDestroy() = stopScan()

    private val cameraManager: CameraManager?
        get() = activity?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager

    @UsedByGodot
    fun isAvailable(): Boolean {
        available?.let { return it }
        val found = findPassthroughCameraId() != null
        if (!found) logCameraKeys()
        available = found
        return found
    }

    @UsedByGodot
    fun startScan(): Boolean {
        if (running) return true

        val manager = cameraManager
        if (manager == null) {
            fail("No camera service")
            return false
        }

        val id = findPassthroughCameraId()
        if (id == null) {
            fail("No passthrough camera on this device")
            return false
        }

        startThread()

        reader = ImageReader.newInstance(
            CAPTURE_WIDTH, CAPTURE_HEIGHT, ImageFormat.YUV_420_888, 3
        ).apply {
            setOnImageAvailableListener({ r -> onImage(r) }, handler)
        }

        running = true
        lastDecodeMs = 0L
        lastPreviewMs = 0L

        try {
            manager.openCamera(id, deviceCallback, handler)
        } catch (e: SecurityException) {
            fail("Camera permission was not granted")
            stopScan()
            return false
        } catch (e: Exception) {
            fail("Could not open the camera: ${e.message}")
            stopScan()
            return false
        }

        return true
    }

    /** Safe from any thread and at any point in the open sequence. */
    @UsedByGodot
    fun stopScan() {
        running = false

        session?.let { s ->
            runCatching { s.stopRepeating() }
            runCatching { s.close() }
        }
        session = null

        device?.let { d -> runCatching { d.close() } }
        device = null

        reader?.let { r -> runCatching { r.close() } }
        reader = null

        stopThread()
    }

    private val deviceCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(camera: CameraDevice) {
            device = camera
            val surface = reader?.surface
            if (surface == null) {
                fail("Camera opened with no target surface")
                return
            }
            try {
                @Suppress("DEPRECATION")
                camera.createCaptureSession(listOf(surface), sessionCallback, handler)
            } catch (e: Exception) {
                fail("Could not create the capture session: ${e.message}")
            }
        }

        override fun onDisconnected(camera: CameraDevice) {
            fail("Camera disconnected")
            stopScan()
        }

        override fun onError(camera: CameraDevice, error: Int) {
            fail("Camera error $error")
            stopScan()
        }
    }

    private val sessionCallback = object : CameraCaptureSession.StateCallback() {
        override fun onConfigured(configured: CameraCaptureSession) {
            session = configured
            val dev = device ?: return
            val surface = reader?.surface ?: return
            try {
                val request = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                request.addTarget(surface)
                configured.setRepeatingRequest(request.build(), null, handler)
            } catch (e: Exception) {
                fail("Could not start the capture: ${e.message}")
            }
        }

        override fun onConfigureFailed(configured: CameraCaptureSession) {
            fail("Camera session configuration failed")
        }
    }

    private fun onImage(from: ImageReader) {
        val image = try {
            from.acquireLatestImage()
        } catch (e: Exception) {
            null
        } ?: return

        try {
            if (!running) return

            val plane = image.planes[0]
            val buffer = plane.buffer
            val luma = ByteArray(buffer.remaining())
            buffer.get(luma)

            val stride = plane.rowStride
            val width = image.width
            val height = image.height
            val now = SystemClock.elapsedRealtime()

            if (now - lastPreviewMs >= PREVIEW_INTERVAL_MS) {
                lastPreviewMs = now
                emitSignal(SIGNAL_FRAME.name, downsample(luma, stride, width, height))
            }

            if (now - lastDecodeMs >= DECODE_INTERVAL_MS) {
                lastDecodeMs = now
                decode(luma, stride, width, height)?.let { text ->
                    emitSignal(SIGNAL_DETECTED.name, text)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "frame handling failed", e)
        } finally {
            // Skipping this stalls the reader after `maxImages` frames.
            runCatching { image.close() }
        }
    }

    /** Null on every frame that holds no readable code — the normal case. */
    private fun decode(luma: ByteArray, stride: Int, width: Int, height: Int): String? {
        if (luma.size < stride * height) return null
        return try {
            val source = PlanarYUVLuminanceSource(
                luma, stride, height, 0, 0, width, height, false
            )
            qrReader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
        } catch (e: Exception) {
            null
        } finally {
            qrReader.reset()
        }
    }

    /**
     * Nearest-neighbour: this is an aiming aid, and the decode above always runs
     * on the full-resolution plane regardless of what the preview looks like.
     */
    private fun downsample(luma: ByteArray, stride: Int, width: Int, height: Int): ByteArray {
        val out = ByteArray(PREVIEW_WIDTH * PREVIEW_HEIGHT)
        var at = 0
        for (py in 0 until PREVIEW_HEIGHT) {
            val row = (py * height / PREVIEW_HEIGHT) * stride
            for (px in 0 until PREVIEW_WIDTH) {
                val index = row + (px * width / PREVIEW_WIDTH)
                out[at++] = if (index < luma.size) luma[index] else 0
            }
        }
        return out
    }

    private fun findPassthroughCameraId(): String? {
        val manager = cameraManager ?: return null
        return try {
            manager.cameraIdList.firstOrNull { id ->
                val characteristics = manager.getCameraCharacteristics(id)
                vendorInt(characteristics, META_SOURCE) == SOURCE_PASSTHROUGH &&
                    vendorInt(characteristics, META_POSITION) == POSITION_LEFT
            }
        } catch (e: Exception) {
            Log.w(TAG, "camera enumeration failed", e)
            null
        }
    }

    /**
     * CameraCharacteristics.Key has no public constructor, so the Meta vendor
     * tags are matched by name against the keys the device actually reports.
     */
    private fun vendorInt(characteristics: CameraCharacteristics, name: String): Int? {
        val key = characteristics.keys.firstOrNull { it.name == name } ?: return null
        @Suppress("UNCHECKED_CAST")
        val value = characteristics.get(key as CameraCharacteristics.Key<Any>) ?: return null
        return (value as? Number)?.toInt()
    }

    /** Makes a vendor-tag rename diagnosable instead of looking like missing hardware. */
    private fun logCameraKeys() {
        val manager = cameraManager ?: return
        runCatching {
            for (id in manager.cameraIdList) {
                val names = manager.getCameraCharacteristics(id).keys
                    .map { it.name }
                    .filter { it.startsWith("com.meta") }
                Log.i(TAG, "camera $id meta keys: $names")
            }
        }
    }

    private fun startThread() {
        if (thread != null) return
        thread = HandlerThread("RetroXRQr").apply { start() }
        handler = Handler(thread!!.looper)
    }

    private fun stopThread() {
        val t = thread ?: return
        thread = null
        handler = null
        t.quitSafely()
        // Joining from the camera thread itself would deadlock.
        if (Thread.currentThread() !== t) {
            runCatching { t.join(1000) }
        }
    }

    private fun fail(message: String) {
        Log.w(TAG, message)
        emitSignal(SIGNAL_ERROR.name, message)
    }
}
