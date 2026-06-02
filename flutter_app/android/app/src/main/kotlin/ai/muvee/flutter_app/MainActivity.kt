package ai.muvee.flutter_app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // ama_bridge exports the JNI initAndroidContext below.
            System.loadLibrary("ama_bridge")
        }

        private const val FOREGROUND_CHANNEL = "ama/foreground"
        private const val OVERLAY_CHANNEL = "ama/overlay"
        // Overlay → main command relay. flutter_overlay_window's own shareData
        // CANNOT deliver overlay → main: its native WindowSetup.messenger is a
        // static that the (later-created) overlay engine clobbers, so commands
        // bounce back to the overlay isolate instead of reaching the main one.
        // We relay them ourselves — both engines live in this one process, so a
        // MethodChannel registered on the overlay engine can forward into the
        // main engine's channel. OVERLAY_ENGINE_TAG is the plugin's cached id.
        private const val OVERLAY_CMD_CHANNEL = "ama/overlay_cmd"
        private const val OVERLAY_ENGINE_TAG = "myCachedEngine"
    }

    private external fun initAndroidContext(context: Context)

    // Main-engine side of the relay; the main Dart isolate listens here for the
    // commands forwarded off the overlay engine.
    private var mainCmdChannel: MethodChannel? = null

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

        // The main-engine end of the overlay→main relay. Overlay commands the
        // native relay forwards arrive here as "cmd"; the Dart side routes them.
        mainCmdChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CMD_CHANNEL)

        // Bubble "open full inbox" → bring this activity back to the foreground;
        // plus "attachOverlayRelay" wiring requested once the overlay is shown.
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
                    "attachOverlayRelay" -> {
                        result.success(attachOverlayRelay())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Register a handler on the overlay engine's channel that forwards every
    /// command into the main engine's [mainCmdChannel]. Returns false if the
    /// overlay engine isn't cached yet (the Dart side will retry). Safe to call
    /// repeatedly — it just re-binds the same handler.
    private fun attachOverlayRelay(): Boolean {
        val overlayEngine =
            FlutterEngineCache.getInstance().get(OVERLAY_ENGINE_TAG) ?: return false
        MethodChannel(overlayEngine.dartExecutor.binaryMessenger, OVERLAY_CMD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "cmd") {
                    val payload = call.arguments
                    // Hop to the UI thread to invoke the main engine's channel.
                    runOnUiThread { mainCmdChannel?.invokeMethod("cmd", payload) }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        return true
    }
}
