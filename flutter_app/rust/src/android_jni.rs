//! Android JNI glue.
//!
//! iroh's network watcher reads the Android `ConnectivityManager` through the
//! `ndk_context` global, which must hold the app's JavaVM + Context *before* any
//! iroh use. Without it, `Inbox::create` panics with "android context was not
//! initialized". `MainActivity` calls [`Java_ai_muvee_flutter_1app_MainActivity_initAndroidContext`]
//! once at startup (before the Dart side runs) to register it. See M4 P1.
use std::os::raw::c_void;

use jni::objects::{JClass, JObject};
use jni::JNIEnv;

/// `MainActivity.initAndroidContext(context)` — store the JavaVM and a global ref
/// to the application Context in `ndk_context`.
#[no_mangle]
pub extern "system" fn Java_ai_muvee_flutter_1app_MainActivity_initAndroidContext<'local>(
    env: JNIEnv<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) {
    let Ok(vm) = env.get_java_vm() else {
        return;
    };
    let Ok(global) = env.new_global_ref(&context) else {
        return;
    };
    // ndk_context wants a jobject pointer that outlives every iroh call, so leak
    // the global ref for the process lifetime.
    let context_ptr = global.as_obj().as_raw() as *mut c_void;
    std::mem::forget(global);
    unsafe {
        ndk_context::initialize_android_context(
            vm.get_java_vm_pointer() as *mut c_void,
            context_ptr,
        );
    }
}
