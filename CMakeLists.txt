cmake_minimum_required(VERSION 3.22)
project(loro-cpp LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)  # defines BUILD_TESTING (default ON) and runs enable_testing()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---------------------------------------------------------------------------
# 1. Pull Corrosion (Rust ⇆ CMake) and import the shim staticlib.
# ---------------------------------------------------------------------------
include(FetchContent)
FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG        v0.5.1
)
FetchContent_MakeAvailable(Corrosion)

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

# On Windows MSVC, rust 1.95+'s `getrandom` references `BCryptGenRandom`
# through `bcryptprimitives.dll` (a forwarder DLL). Corrosion populates
# `Rust_CARGO_TARGET_LINK_NATIVE_LIBS` from rustc's `--print
# native-static-libs` output, but that list omits `bcrypt` for
# bcryptprimitives-using builds — so we add it explicitly here.
if(WIN32)
    target_link_libraries(loro PUBLIC bcrypt)
endif()

# Force-load notes:
#
# UniFFI scaffolding (`uniffi_loro_ffi_fn_…`, `ffi_loro_ffi_…`) is `#[no_mangle]`
# extern "C" and gets *referenced by name* from the generated C++ source.
# That gives the linker enough work to pull each scaffolding object in;
# whole-archive coverage is therefore not strictly required.
#
# On Windows MSVC, applying `/WHOLEARCHIVE` to the rust staticlib causes
# LNK2005 duplicate-symbol errors against the COFF import descriptors for
# `bcryptprimitives.dll` (rust ships them as archive members, and the
# linker dedups them per archive — but `/WHOLEARCHIVE` re-adds the same
# archive a second time, breaking that dedup).
#
# We can revisit this in M2 if any dynamically-resolved scaffolding symbol
# (e.g. callback vtables initialized lazily) turns up missing.

# ---------------------------------------------------------------------------
# 4. Tests
# ---------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
