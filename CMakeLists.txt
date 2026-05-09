cmake_minimum_required(VERSION 3.22)
project(loro-cpp LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)  # defines BUILD_TESTING (default ON) and runs enable_testing()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---------------------------------------------------------------------------
# MSYS2 cmake defaults — only applied when running under an MSYS2 cmake build
# (CMAKE_HOST_SYSTEM_NAME=MSYS) and when the user hasn't already set the
# corresponding variable. Make MSYS2 builds work with a bare
# `cmake -B build -G Ninja` instead of needing a wall of `-D` flags.
#
# Why each default is needed:
#  * Rust_COMPILER / Rust_CARGO / Rust_RESOLVE_RUSTUP_TOOLCHAINS=OFF —
#    Corrosion's FindRust resolves rustup's reported toolchain path
#    (`C:\Users\…\.rustup\toolchains\…`) via `find_program(... HINTS …)`,
#    which fails on MSYS2 cmake (the backslashes don't survive the HINTS
#    lookup). Bypass rustup-resolve and point straight at the active
#    toolchain binaries.
#  * Rust_CARGO_TARGET — pick the Rust target triple that matches the
#    MSYS2 environment's runtime/CRT (CLANG64 → gnullvm; UCRT64 / MINGW64
#    → gnu, both use UCRT in modern rustc).
# ---------------------------------------------------------------------------
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "MSYS")
    if(NOT DEFINED Rust_COMPILER OR NOT DEFINED Rust_CARGO)
        execute_process(
            COMMAND rustup which rustc
            OUTPUT_VARIABLE _loro_rustc
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE _loro_rustc_rc
        )
        execute_process(
            COMMAND rustup which cargo
            OUTPUT_VARIABLE _loro_cargo
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE _loro_cargo_rc
        )
        if(_loro_rustc_rc EQUAL 0 AND _loro_cargo_rc EQUAL 0)
            string(REPLACE "\\" "/" _loro_rustc "${_loro_rustc}")
            string(REPLACE "\\" "/" _loro_cargo "${_loro_cargo}")
            set(Rust_COMPILER "${_loro_rustc}" CACHE FILEPATH "rustc binary")
            set(Rust_CARGO    "${_loro_cargo}" CACHE FILEPATH "cargo binary")
            set(Rust_RESOLVE_RUSTUP_TOOLCHAINS OFF CACHE BOOL
                "Disable rustup-toolchain resolution under MSYS2 cmake")
        endif()
        unset(_loro_rustc)
        unset(_loro_cargo)
        unset(_loro_rustc_rc)
        unset(_loro_cargo_rc)
    endif()
    if(NOT DEFINED Rust_CARGO_TARGET AND DEFINED ENV{MSYSTEM})
        if("$ENV{MSYSTEM}" STREQUAL "CLANG64")
            set(Rust_CARGO_TARGET "x86_64-pc-windows-gnullvm" CACHE STRING "")
        elseif("$ENV{MSYSTEM}" STREQUAL "CLANGARM64")
            set(Rust_CARGO_TARGET "aarch64-pc-windows-gnullvm" CACHE STRING "")
        elseif("$ENV{MSYSTEM}" STREQUAL "UCRT64" OR "$ENV{MSYSTEM}" STREQUAL "MINGW64")
            set(Rust_CARGO_TARGET "x86_64-pc-windows-gnu" CACHE STRING "")
        endif()
    endif()
endif()

# ---------------------------------------------------------------------------
# 1. Add vendored Corrosion (Rust ⇆ CMake) and import the shim staticlib.
#    Vendored at vendor/corrosion/ (v0.6.1) with one local patch:
#    CorrosionGenerator.cmake replaces `file(TO_CMAKE_PATH)` on the cargo-
#    metadata manifest path with a plain `\\`→`/` substitution, because
#    MSYS2 cmake's TO_CMAKE_PATH treats `:` as a list separator and would
#    mangle `C:\Users\…` into `C;/Users/…`.
# ---------------------------------------------------------------------------
add_subdirectory(vendor/corrosion EXCLUDE_FROM_ALL)

corrosion_import_crate(
    MANIFEST_PATH "${CMAKE_CURRENT_SOURCE_DIR}/loro-cpp-rs/Cargo.toml"
    CRATE_TYPES   staticlib
    PROFILE       release
)

# ---------------------------------------------------------------------------
# 2. Install uniffi-bindgen-cpp (pinned tag) and wire it to regenerate
#    loro.hpp/loro.cpp whenever the staticlib changes.
# ---------------------------------------------------------------------------
include(uniffi_bindgen_cpp)

set(LORO_GENERATED_DIR    "${CMAKE_BINARY_DIR}/generated")
set(LORO_GENERATED_HEADER "${LORO_GENERATED_DIR}/loro.hpp")
set(LORO_GENERATED_SOURCE "${LORO_GENERATED_DIR}/loro.cpp")

# UDL-mode generation: locate loro.udl in the cargo registry and feed it
# directly to uniffi-bindgen-cpp. Library mode (parsing the staticlib) is
# avoided because rustc's MSVC `.lib` archives have member names that the
# generator's `goblin` archive parser cannot handle.
loro_locate_udl(LORO_UDL_FILE "${CMAKE_CURRENT_SOURCE_DIR}/loro-cpp-rs")
message(STATUS "Loro UDL: ${LORO_UDL_FILE}")

uniffi_generate_cpp_bindings(
    UDL_FILE      "${LORO_UDL_FILE}"
    OUT_DIR       "${LORO_GENERATED_DIR}"
    OUTPUT_HEADER "${LORO_GENERATED_HEADER}"
    OUTPUT_SOURCE "${LORO_GENERATED_SOURCE}"
)

# ---------------------------------------------------------------------------
# 3. Public C++ library: generated bindings + (later) ergonomics header.
# ---------------------------------------------------------------------------
add_library(loro STATIC "${LORO_GENERATED_SOURCE}")
add_library(loro::loro ALIAS loro)

target_include_directories(loro PUBLIC
    "$<BUILD_INTERFACE:${LORO_GENERATED_DIR}>"
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
)
target_link_libraries(loro PUBLIC loro_cpp_rs)
target_compile_features(loro PUBLIC cxx_std_20)

# Rust 1.95+'s `getrandom` references `BCryptGenRandom` through
# `bcryptprimitives.dll` (a forwarder DLL). Corrosion populates
# `Rust_CARGO_TARGET_LINK_NATIVE_LIBS` from rustc's `--print
# native-static-libs` output, but that list omits `bcrypt` for
# bcryptprimitives-using builds — so we add it explicitly here.
#
# Match against the cargo target rather than `WIN32` because MSYS2 cmake
# sets `MSYS=TRUE` / `WIN32=FALSE` (it identifies its host system as
# `MSYS`, not `Windows`), and `WIN32` would skip the link.
if(Rust_CARGO_TARGET_OS STREQUAL "windows")
    target_link_libraries(loro PUBLIC bcrypt)
endif()

# Note on whole-archive: UniFFI scaffolding (`uniffi_loro_ffi_fn_…`,
# `ffi_loro_ffi_…`) is `#[no_mangle]` extern "C" and gets *referenced by
# name* from the generated C++ source, so the linker pulls each scaffolding
# object in normally; whole-archive coverage is not required. Revisit if a
# lazily-initialized callback vtable ever turns up missing at link time.

# ---------------------------------------------------------------------------
# 4. Tests
# ---------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
