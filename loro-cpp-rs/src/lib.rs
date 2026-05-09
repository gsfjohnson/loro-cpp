//! Thin staticlib shim around `loro-ffi`.
//!
//! `loro-ffi` is published as an rlib, which cannot be linked into a C++
//! application. Re-exporting it from a `crate-type = ["staticlib"]` crate
//! gives the linker an archive containing all of UniFFI's `#[no_mangle]`
//! scaffolding symbols. The C++ side then force-loads the archive
//! (`/WHOLEARCHIVE`, `-force_load`, or `--whole-archive`) so those
//! symbols survive linker garbage collection.

pub use loro_ffi::*;

// Force the linker to retain at least one referenced symbol from
// `loro-ffi` so the rest of the scaffolding stays anchored. Without
// this, `cargo` may strip transitively-depended FFI symbols when
// producing the staticlib.
#[used]
static FORCE_LINK_LORO_FFI: fn() -> String = loro_ffi::get_version;
