package com.example.muse_grid

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val AUDIO_PERMISSIONS_CHANNEL = "musegrid/audio_permissions"
    private const val RECORD_AUDIO_REQUEST_CODE = 1001
  }

  private var pendingRecordAudioResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      AUDIO_PERMISSIONS_CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "ensureRecordAudioPermission" -> handleEnsureRecordAudioPermission(result)
        else -> result.notImplemented()
      }
    }
  }

  private fun handleEnsureRecordAudioPermission(result: MethodChannel.Result) {
    val status = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
    if (status == PackageManager.PERMISSION_GRANTED) {
      result.success(true)
      return
    }
    if (pendingRecordAudioResult != null) {
      result.error(
        "PERMISSION_REQUEST_IN_FLIGHT",
        "A RECORD_AUDIO permission request is already in progress.",
        null,
      )
      return
    }
    pendingRecordAudioResult = result
    ActivityCompat.requestPermissions(
      this,
      arrayOf(Manifest.permission.RECORD_AUDIO),
      RECORD_AUDIO_REQUEST_CODE,
    )
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ) {
    if (requestCode == RECORD_AUDIO_REQUEST_CODE) {
      val result = pendingRecordAudioResult
      pendingRecordAudioResult = null
      if (result != null) {
        val granted =
          grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(granted)
      }
      return
    }
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
  }
}
