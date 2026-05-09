# cmake/uniffi_bindgen_cpp.cmake
#
# Builds and installs `uniffi-bindgen-cpp` from a vendored fork at
# vendor/uniffi-bindgen-cpp/. The fork carries a one-line patch to the C++
# topological sort that skips self-edges (Loro's `LoroValue` enum
# self-references via `List(sequence<LoroValue>)` and `Map(record<…,
# LoroValue>)`, which trips the upstream cycle check).
#
# Generation runs in *UDL* mode against `loro.udl` from the loro-ffi crate
# source. UDL mode side-steps a `goblin` archive-parser failure in
# `--library` mode where rustc's `.rcgu.o` archive members trip the
# parser; pinning the shim crate to `codegen-units = 1` mitigates the
# trigger but UDL mode avoids the code path entirely.

set(UNIFFI_BINDGEN_CPP_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../vendor/uniffi-bindgen-cpp"
    CACHE PATH "Path to vendored uniffi-bindgen-cpp checkout (with loro-cpp patches)")

set(UNIFFI_BINDGEN_CPP_ROOT "${CMAKE_BINARY_DIR}/uniffi-bindgen-cpp"
    CACHE PATH "cargo install --root for uniffi-bindgen-cpp")

# `WIN32` alone misses MSYS2 cmake (sets `MSYS=1` and `WIN32=` empty even
# though it runs on Windows and cargo writes a .exe). Cover both.
if(WIN32 OR MSYS)
    set(UNIFFI_BINDGEN_CPP_EXE "${UNIFFI_BINDGEN_CPP_ROOT}/bin/uniffi-bindgen-cpp.exe")
else()
    set(UNIFFI_BINDGEN_CPP_EXE "${UNIFFI_BINDGEN_CPP_ROOT}/bin/uniffi-bindgen-cpp")
endif()

# Stamp file invalidates whenever the vendored sources change.
file(GLOB_RECURSE _uniffi_src_files
     CONFIGURE_DEPENDS
     "${UNIFFI_BINDGEN_CPP_SOURCE_DIR}/bindgen/*.rs"
     "${UNIFFI_BINDGEN_CPP_SOURCE_DIR}/bindgen/Cargo.toml"
     "${UNIFFI_BINDGEN_CPP_SOURCE_DIR}/Cargo.lock")
string(SHA1 _uniffi_src_hash "${_uniffi_src_files}")
set(_uniffi_stamp "${UNIFFI_BINDGEN_CPP_ROOT}/.installed-${_uniffi_src_hash}")

if(NOT EXISTS "${UNIFFI_BINDGEN_CPP_EXE}" OR NOT EXISTS "${_uniffi_stamp}")
    message(STATUS "Building vendored uniffi-bindgen-cpp from ${UNIFFI_BINDGEN_CPP_SOURCE_DIR}")
    execute_process(
        COMMAND cargo install
            --path   "${UNIFFI_BINDGEN_CPP_SOURCE_DIR}/bindgen"
            --root   "${UNIFFI_BINDGEN_CPP_ROOT}"
            --locked
            --force
        RESULT_VARIABLE _uniffi_install_rc
    )
    if(NOT _uniffi_install_rc EQUAL 0)
        message(FATAL_ERROR
            "cargo install of vendored uniffi-bindgen-cpp failed "
            "(exit code ${_uniffi_install_rc}). Source: ${UNIFFI_BINDGEN_CPP_SOURCE_DIR}")
    endif()
    file(REMOVE_RECURSE "${UNIFFI_BINDGEN_CPP_ROOT}")  # purge old stamps
    file(MAKE_DIRECTORY "${UNIFFI_BINDGEN_CPP_ROOT}/bin")
    # The cargo install above already wrote the binary; recreate the stamp.
    # Note: `--force` already overwrote, but we may have purged. Re-install if needed.
    if(NOT EXISTS "${UNIFFI_BINDGEN_CPP_EXE}")
        execute_process(
            COMMAND cargo install
                --path   "${UNIFFI_BINDGEN_CPP_SOURCE_DIR}/bindgen"
                --root   "${UNIFFI_BINDGEN_CPP_ROOT}"
                --locked
            RESULT_VARIABLE _uniffi_install_rc
        )
        if(NOT _uniffi_install_rc EQUAL 0)
            message(FATAL_ERROR "Re-install of uniffi-bindgen-cpp failed")
        endif()
    endif()
    file(WRITE "${_uniffi_stamp}" "${_uniffi_src_hash}\n")
endif()

# loro_locate_udl(<output_var> <crate_dir>)
# Resolves the path to `loro-ffi`'s `loro.udl` by reading `cargo metadata`
# of the shim crate. Returns absolute path in <output_var>.
function(loro_locate_udl out_var crate_dir)
    execute_process(
        COMMAND cargo metadata --manifest-path "${crate_dir}/Cargo.toml" --format-version 1
        WORKING_DIRECTORY "${crate_dir}"
        OUTPUT_VARIABLE _meta_json
        RESULT_VARIABLE _meta_rc
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT _meta_rc EQUAL 0)
        message(FATAL_ERROR "cargo metadata failed for ${crate_dir}")
    endif()

    string(JSON _packages_count LENGTH "${_meta_json}" "packages")
    set(_loro_ffi_manifest "")
    math(EXPR _last "${_packages_count} - 1")
    foreach(i RANGE 0 ${_last})
        string(JSON _name GET "${_meta_json}" "packages" ${i} "name")
        if(_name STREQUAL "loro-ffi")
            string(JSON _loro_ffi_manifest GET "${_meta_json}" "packages" ${i} "manifest_path")
            break()
        endif()
    endforeach()
    if(NOT _loro_ffi_manifest)
        message(FATAL_ERROR "Could not locate loro-ffi in cargo metadata for ${crate_dir}")
    endif()

    get_filename_component(_loro_ffi_dir "${_loro_ffi_manifest}" DIRECTORY)
    set(_udl "${_loro_ffi_dir}/src/loro.udl")
    if(NOT EXISTS "${_udl}")
        message(FATAL_ERROR "Expected UDL at ${_udl} not found")
    endif()
    set(${out_var} "${_udl}" PARENT_SCOPE)
endfunction()

# uniffi_generate_cpp_bindings(
#     UDL_FILE        <path to .udl>
#     OUT_DIR         <directory for generated files>
#     OUTPUT_HEADER   <expected .hpp path>
#     OUTPUT_SOURCE   <expected .cpp path>
# )
function(uniffi_generate_cpp_bindings)
    set(options)
    set(oneValueArgs UDL_FILE OUT_DIR OUTPUT_HEADER OUTPUT_SOURCE)
    set(multiValueArgs)
    cmake_parse_arguments(_arg "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    foreach(req UDL_FILE OUT_DIR OUTPUT_HEADER OUTPUT_SOURCE)
        if(NOT _arg_${req})
            message(FATAL_ERROR "uniffi_generate_cpp_bindings: missing required argument ${req}")
        endif()
    endforeach()

    file(MAKE_DIRECTORY "${_arg_OUT_DIR}")

    # The UDL source lives in the cargo registry next to the loro-ffi
    # `Cargo.toml`; uniffi-bindgen-cpp walks up from the UDL to find that
    # crate manifest, so we can't stage it into the build tree. We pass
    # the original path directly to the generator command (Ninja invokes
    # `sh -c …` so the path is just an argument string, no path-rewrite).
    #
    # The same path can't go into DEPENDS though: when this CMakeLists is
    # consumed via add_subdirectory()/FetchContent, Ninja treats the
    # drive-letter prefix as a relative segment and re-roots the path
    # under the inner build dir (`_deps/loro-build/C:/Users/…`). Sidestep
    # this by depending only on the generator binary — for a pinned
    # `loro-ffi` version the registry-side UDL is immutable, so we don't
    # lose meaningful change-tracking.
    add_custom_command(
        OUTPUT  "${_arg_OUTPUT_HEADER}" "${_arg_OUTPUT_SOURCE}"
        COMMAND "${UNIFFI_BINDGEN_CPP_EXE}"
                "${_arg_UDL_FILE}"
                --out-dir "${_arg_OUT_DIR}"
        DEPENDS "${UNIFFI_BINDGEN_CPP_EXE}"
        COMMENT "uniffi-bindgen-cpp: generating C++ bindings from ${_arg_UDL_FILE}"
        VERBATIM
    )

    set_source_files_properties(
        "${_arg_OUTPUT_HEADER}" "${_arg_OUTPUT_SOURCE}"
        PROPERTIES GENERATED TRUE
    )
endfunction()
