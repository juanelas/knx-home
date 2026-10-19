package com.juanelas.knx_home

import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.juanelas.knx_home/local_network"
    private val requestCode = 7814
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "requestAccess") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < 37) {
                    result.success(true)
                    return@setMethodCallHandler
                }

                val permission = "android.permission.ACCESS_LOCAL_NETWORK"
                if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
                    result.success(true)
                } else if (permissionResult != null) {
                    result.error("permission_in_progress", "A permission request is already active.", null)
                } else {
                    permissionResult = result
                    requestPermissions(arrayOf(permission), requestCode)
                }
            }
    }

    @Deprecated("Deprecated in Android, retained for Flutter permission callback compatibility")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != this.requestCode) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }
}
