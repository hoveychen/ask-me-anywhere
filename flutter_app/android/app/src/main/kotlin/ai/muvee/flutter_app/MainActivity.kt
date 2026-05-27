package ai.muvee.flutter_app

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // ama_bridge exports the JNI initAndroidContext below.
            System.loadLibrary("ama_bridge")
        }
    }

    private external fun initAndroidContext(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        // iroh's network watcher needs the Android context registered in
        // ndk_context before the Dart side calls InboxHandle.create; otherwise
        // Inbox::create panics. Do it before the Flutter engine starts Dart.
        initAndroidContext(applicationContext)
        super.onCreate(savedInstanceState)
    }
}
