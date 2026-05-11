package com.example.fruityvens_app

import android.app.ActivityManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterFragmentActivity() {
    private val reportChannel = "fruityvens_app/report_saver"
    private val deviceProfileChannel = "fruityvens_app/device_profile"
    private val createPdfRequestCode = 2407
    private var pendingPdfResult: MethodChannel.Result? = null
    private var pendingPdfBytes: ByteArray? = null
    private var pendingPdfFileName: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, reportChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "savePdfWithPicker" -> {
                        val fileName = call.argument<String>("fileName")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName.isNullOrBlank() || bytes == null) {
                            result.error(
                                "bad_args",
                                "Missing PDF file name or bytes.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        openPdfSavePicker(fileName, bytes, result)
                    }

                    "savePdfToDownloads" -> {
                        val fileName = call.argument<String>("fileName")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName.isNullOrBlank() || bytes == null) {
                            result.error(
                                "bad_args",
                                "Missing PDF file name or bytes.",
                                null,
                            )
                            return@setMethodCallHandler
                        }

                        try {
                            result.success(savePdfToDownloads(fileName, bytes))
                        } catch (error: Exception) {
                            result.error(
                                "save_failed",
                                error.message ?: "Unable to save PDF report.",
                                null,
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceProfileChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceProfile" -> result.success(getDeviceProfile())
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == createPdfRequestCode) {
            val result = pendingPdfResult
            val bytes = pendingPdfBytes
            pendingPdfResult = null
            pendingPdfBytes = null
            pendingPdfFileName = null

            if (result == null || bytes == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }

            if (resultCode != RESULT_OK) {
                result.success(null)
                return
            }

            val uri = data?.data
            if (uri == null) {
                result.error("save_cancelled", "No destination was selected.", null)
                return
            }

            try {
                contentResolver.openOutputStream(uri, "w")?.use { output ->
                    output.write(bytes)
                } ?: throw IllegalStateException("Unable to open selected file.")
                result.success(uri.toString())
            } catch (error: Exception) {
                result.error(
                    "save_failed",
                    error.message ?: "Unable to save PDF report.",
                    null,
                )
            }
            return
        }

        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun getDeviceProfile(): Map<String, Any> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)
        val ramMb = memoryInfo.totalMem / (1024L * 1024L)
        val cores = Runtime.getRuntime().availableProcessors()
        val tier = when {
            ramMb >= 7000 && cores >= 8 -> "high"
            ramMb >= 3500 && cores >= 6 -> "mid"
            else -> "low"
        }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "model" to Build.MODEL.orEmpty(),
            "sdk" to Build.VERSION.SDK_INT,
            "ramMb" to ramMb,
            "cpuCores" to cores,
            "tier" to tier,
        )
    }

    private fun openPdfSavePicker(
        fileName: String,
        bytes: ByteArray,
        result: MethodChannel.Result,
    ) {
        if (pendingPdfResult != null) {
            result.error("busy", "Another report save is already open.", null)
            return
        }

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }

        try {
            pendingPdfResult = result
            pendingPdfBytes = bytes
            pendingPdfFileName = fileName
            startActivityForResult(intent, createPdfRequestCode)
        } catch (error: Exception) {
            pendingPdfResult = null
            pendingPdfBytes = null
            pendingPdfFileName = null
            result.error(
                "picker_unavailable",
                error.message ?: "File manager is not available.",
                null,
            )
        }
    }

    private fun savePdfToDownloads(fileName: String, bytes: ByteArray): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("Downloads folder is not available.")

            resolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
            } ?: throw IllegalStateException("Unable to open Downloads output stream.")

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }

        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!downloads.exists()) {
            downloads.mkdirs()
        }
        val file = File(downloads, fileName)
        FileOutputStream(file).use { output ->
            output.write(bytes)
        }
        return file.absolutePath
    }
}
