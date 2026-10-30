package com.seqpoint.seqpoint_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.seqpoint.syncthing.mobile.Mobile
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val engineQueue = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "seqpoint/syncthing")
            .setMethodCallHandler { call, result ->
                if (call.method != "start" && call.method != "stop") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val home = call.argument<String>("home")
                val address = call.argument<String>("address")
                val key = call.argument<String>("apiKey")
                if (call.method == "start" && (home == null || address == null || key == null)) {
                    result.error("arguments", "Missing engine configuration", null)
                    return@setMethodCallHandler
                }
                engineQueue.execute {
                    try {
                        if (call.method == "start") Mobile.start(home, address, key) else Mobile.stop()
                        runOnUiThread { result.success(null) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("engine", "Syncthing operation failed", null) }
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        engineQueue.execute {
            try { Mobile.stop() }
            catch (error: Exception) { android.util.Log.w("SeqPoint", "Syncthing shutdown failed") }
        }
        engineQueue.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
