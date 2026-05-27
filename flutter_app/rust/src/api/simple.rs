/// Runs once on `RustLib.init()` — sets up the FRB error/log plumbing.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
