package com.xenu.retroxr.qr

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Build
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
        const val HEADSET_CAMERA = "horizonos.permission.HEADSET_CAMERA"

        const val CAPTURE_WIDTH = 1280
        const val CAPTURE_HEIGHT = 960
        const val PREVIEW_WIDTH = 320
        const val PREVIEW_HEIGHT = 240

        const val DECODE_INTERVAL_MS = 125L   // ~8 Hz
        const val PREVIEW_INTERVAL_MS = 83L   // ~12 Hz

        // Verified against a Quest 3 on Horizon OS: cameras 50 and 51 carry
        // camera_source / position / camera_name / camera_thumbnail. The tag is
        // "position", NOT "camera_position".
        const val META_SOURCE = "com.meta.extra_metadata.camera_source"
        const val META_POSITION = "com.meta.extra_metadata.position"
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

    /**
     * Horizon OS does not expose the passthrough cameras until HEADSET_CAMERA is
     * granted — before that, `cameraIdList` holds one camera with no vendor tags
     * at all. Since the UI that asks for the permission is itself gated on this
     * answer, enumerating first would hide the button forever. So the model
     * answers until the permission exists, and enumeration takes over after.
     */
    @UsedByGodot
    fun isAvailable(): Boolean {
        available?.let { return it }

        if (!hasCameraPermission()) {
            val supported = isPassthroughCameraModel()
            Log.i(TAG, "isAvailable=$supported (no permission yet, by model ${Build.MODEL})")
            return supported   // deliberately not cached: the grant changes it
        }

        val id = findPassthroughCameraId()
        if (id == null) logCameraKeys()
        Log.i(TAG, "isAvailable=${id != null} (enumerated, camera=$id)")
        available = id != null
        return id != null
    }

    private fun hasCameraPermission(): Boolean {
        val act = activity ?: return false
        return act.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
            act.checkSelfPermission(HEADSET_CAMERA) == PackageManager.PERMISSION_GRANTED
    }

    /** Quest 3 and 3S only; Quest 2 and Pro have no passthrough camera access. */
    private fun isPassthroughCameraModel(): Boolean =
        (Build.MODEL ?: "").startsWith("Quest 3", ignoreCase = true)

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
            val passthrough = manager.cameraIdList.filter { id ->
                vendorInt(manager.getCameraCharacteristics(id), META_SOURCE) == SOURCE_PASSTHROUGH
            }
            // Prefer the left eye, but take any passthrough camera if the
            // position tag is missing: that tag has already been renamed once,
            // and losing it should cost the eye choice, not the whole feature.
            passthrough.firstOrNull { id ->
                vendorInt(manager.getCameraCharacteristics(id), META_POSITION) == POSITION_LEFT
            } ?: passthrough.firstOrNull()
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
        // Verified on a Quest 3: these come back as byte[], not as a scalar.
        return when (value) {
            is ByteArray -> if (value.isEmpty()) null else value[0].toInt()
            is Number -> value.toInt()
            else -> null
        }
    }

    /** Makes a vendor-tag rename or a value-encoding surprise diagnosable
     *  instead of looking like missing hardware. */
    private fun logCameraKeys() {
        val manager = cameraManager ?: return
        runCatching {
            for (id in manager.cameraIdList) {
                val characteristics = manager.getCameraCharacteristics(id)
                val described = characteristics.keys
                    .filter { it.name.startsWith("com.meta") }
                    .map { key -> "${key.name}=${vendorInt(characteristics, key.name)}" }
                Log.i(TAG, "camera $id: $described")
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
