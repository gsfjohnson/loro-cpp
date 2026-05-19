cmake_minimum_required(VERSION 3.22)
project(loro-cpp LANGUAGES CXX VERSION 0.1.1)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)  # defines BUILD_TESTING (default ON) and runs enable_testing()
include(GNUInstallDirs)  # define CMAKE_INSTALL_{LIB,INCLUDE,BIN}DIR before any
                         # target_include_directories(... INSTALL_INTERFACE) call

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---------------------------------------------------------------------------
# MSYS2 cmake defaults — make MSYS2 builds work with a bare
# `cmake -B build -G Ninja` instead of needing a wall of `-D` flags.
#
# Two distinct concerns, each with a different scope:
#
#  1. Rust_CARGO_TARGET (gated on $MSYSTEM): pick the Rust target triple that
#     matches the MSYS2 environment's runtime/CRT (CLANG64/CLANGARM64 → gnullvm;
#     UCRT64 / MINGW64 → gnu, both UCRT in modern rustc). This applies whether
#     the active cmake is msys/cmake (CMAKE_HOST_SYSTEM_NAME=MSYS) or the
#     environment-prefixed mingw-w64-<env>-cmake (CMAKE_HOST_SYSTEM_NAME=
#     Windows) — both produce binaries linked against the MSYSTEM toolchain
#     and must match the Rust ABI accordingly. Without this, rustup falls back
#     to its default (typically …-msvc) and the staticlib won't link.
#
#  2. Rust_COMPILER / Rust_CARGO / Rust_RESOLVE_RUSTUP_TOOLCHAINS=OFF (gated on
#     CMAKE_HOST_SYSTEM_NAME=MSYS only): Corrosion's FindRust resolves rustup's
#     reported toolchain path (`C:\Users\…\.rustup\toolchains\…`) via
#     `find_program(... HINTS …)`, which fails on MSYS2-base cmake because the
#     backslashes don't survive the HINTS lookup. The Windows-native cmake
#     (mingw-w64-<env>-cmake) doesn't hit the bug, so leave its rustup
#     resolution alone.
# ---------------------------------------------------------------------------
if(DEFINED ENV{MSYSTEM} AND NOT DEFINED Rust_CARGO_TARGET)
    if("$ENV{MSYSTEM}" STREQUAL "CLANG64")
        set(Rust_CARGO_TARGET "x86_64-pc-windows-gnullvm" CACHE STRING "")
    elseif("$ENV{MSYSTEM}" STREQUAL "CLANGARM64")
        set(Rust_CARGO_TARGET "aarch64-pc-windows-gnullvm" CACHE STRING "")
    elseif("$ENV{MSYSTEM}" STREQUAL "UCRT64" OR "$ENV{MSYSTEM}" STREQUAL "MINGW64")
        set(Rust_CARGO_TARGET "x86_64-pc-windows-gnu" CACHE STRING "")
    endif()
endif()

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
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
# loro_cpp_rs is a Corrosion-imported INTERFACE target — only valid in this
# build tree. For installed consumers, the equivalent IMPORTED static target
# `loro::loro_cpp_rs` is recreated by loroConfig.cmake.
target_link_libraries(loro PUBLIC $<BUILD_INTERFACE:loro_cpp_rs>)
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
# 4. Install rules + loroConfig package (M4)
# ---------------------------------------------------------------------------
include(CMakePackageConfigHelpers)

# Capture variables that loroConfig.cmake.in needs at configure-time of the
# *consumer*: the rust staticlib filename and its native-deps link list.
# Corrosion sets IMPORTED_LOCATION via cmake_language(DEFER), so reading it
# at this point yields NOTFOUND. The `COR_FILE_NAME` property is populated
# eagerly with the bare archive filename — use that instead.
get_target_property(LORO_RUST_ARCHIVE_NAME loro_cpp_rs-static COR_FILE_NAME)
if(NOT LORO_RUST_ARCHIVE_NAME)
    message(FATAL_ERROR
        "loro_cpp_rs-static is missing the COR_FILE_NAME property — "
        "Corrosion may have changed its API.")
endif()

# Mirror what Corrosion attaches as INTERFACE_LINK_LIBRARIES on the staticlib
# (kernel32, ws2_32, …) plus the bcrypt entry we add ourselves on Windows.
# These propagate to consumers as plain link-line tokens (system libs).
set(LORO_RUST_INTERFACE_LINK_LIBS "${Rust_CARGO_TARGET_LINK_NATIVE_LIBS}")
if(Rust_CARGO_TARGET_OS STREQUAL "windows")
    list(APPEND LORO_RUST_INTERFACE_LINK_LIBS bcrypt)
endif()

# Install the C++ wrapper static library + create the loroTargets export.
install(TARGETS loro
    EXPORT  loroTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
)

# Install headers — generated bindings at <prefix>/include/, hand-written
# ergonomics at <prefix>/include/loro/. The generated header references
# `loro_scaffolding.hpp` via a relative include, so they must sit side-by-side.
install(FILES
        "${LORO_GENERATED_HEADER}"
        "${LORO_GENERATED_DIR}/loro_scaffolding.hpp"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/include/loro"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    FILES_MATCHING PATTERN "*.hpp"
)

# Install the Rust staticlib archive itself. `loro_cpp_rs-static`
# (created by Corrosion) carries the actual archive path via IMPORTED_LOCATION.
install(FILES "$<TARGET_FILE:loro_cpp_rs-static>"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}"
)

# Export loroTargets and write loroConfig + version files.
install(EXPORT loroTargets
    FILE        loroTargets.cmake
    NAMESPACE   loro::
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/loro"
)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/loroConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/loroConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/loro"
    PATH_VARS CMAKE_INSTALL_LIBDIR
)
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/loroConfigVersion.cmake"
    VERSION       "${PROJECT_VERSION}"
    COMPATIBILITY SameMajorVersion
)
install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/loroConfig.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/loroConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/loro"
)

# Install the license alongside the package so distro packagers (MSYS2 pacman,
# Debian, Homebrew) and end users can satisfy attribution requirements without
# pulling files from the source tarball.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE"
    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/licenses/loro-cpp"
)

# ---------------------------------------------------------------------------
# 5. Tests + examples
# ---------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()

option(LORO_BUILD_EXAMPLES "Build loro-cpp examples" ${PROJECT_IS_TOP_LEVEL})
if(LORO_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

# ---------------------------------------------------------------------------
# 6. CPack — produce a platform-appropriate package
#    Linux         → .deb (CPACK_GENERATOR=DEB; requires dpkg-deb on PATH)
#    macOS/Windows → .zip
#
# Only configured when this project is top-level so consumers using
# add_subdirectory()/FetchContent don't inherit our CPack settings.
# ---------------------------------------------------------------------------
if(PROJECT_IS_TOP_LEVEL)
    set(CPACK_PACKAGE_NAME           "loro-cpp")
    set(CPACK_PACKAGE_VERSION        "${PROJECT_VERSION}")
    set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
        "C++ bindings for the Loro CRDT library")
    set(CPACK_PACKAGE_VENDOR         "loro-cpp")
    set(CPACK_PACKAGE_HOMEPAGE_URL
        "https://github.com/gsfjohnson/loro-cpp")
    # Default file name for ZIP (Linux DEB overrides via DEB-DEFAULT below to
    # follow Debian's `name_version_arch.deb` convention).
    set(CPACK_PACKAGE_FILE_NAME
        "${CPACK_PACKAGE_NAME}-${CPACK_PACKAGE_VERSION}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")

    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(CPACK_GENERATOR                "DEB")
        # Rewrite paths inside the .deb to live under /usr instead of the
        # build-time CMAKE_INSTALL_PREFIX (which is a CI-local scratch dir).
        set(CPACK_PACKAGING_INSTALL_PREFIX "/usr")
        set(CPACK_DEBIAN_PACKAGE_MAINTAINER
            "gsfjohnson <gsfjohnson@users.noreply.github.com>")
        set(CPACK_DEBIAN_PACKAGE_SECTION   "libs")
        set(CPACK_DEBIAN_PACKAGE_PRIORITY  "optional")
        set(CPACK_DEBIAN_FILE_NAME         "DEB-DEFAULT")
    else()
        set(CPACK_GENERATOR "ZIP")
    endif()

    include(CPack)
endif()
