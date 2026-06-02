package ai.muvee.flutter_app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // ama_bridge exports the JNI initAndroidContext below.
            System.loadLibrary("ama_bridge")
        }

        private const val FOREGROUND_CHANNEL = "ama/foreground"
        private const val OVERLAY_CHANNEL = "ama/overlay"
    }

    private external fun initAndroidContext(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        // iroh's network watcher needs the Android context registered in
        // ndk_context before the Dart side calls InboxHandle.create; otherwise
        // Inbox::create panics. Do it before the Flutter engine starts Dart.
        initAndroidContext(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // start / stop the background-sync foreground service from Dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOREGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                val intent = Intent(this, ForegroundService::class.java)
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Bubble "open full inbox" → bring this activity back to the foreground.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToFront" -> {
                        val intent = Intent(this, MainActivity::class.java).apply {
                            addFlags(
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                    Intent.FLAG_ACTIVITY_NEW_TASK,
                            )
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
