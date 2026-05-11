# loro-cpp

C++20 bindings for [Loro](https://loro.dev), a high-performance CRDT library
written in Rust. The bindings are generated from the upstream
[`loro-ffi`](https://crates.io/crates/loro-ffi) UDL via
[uniffi-bindgen-cpp](https://github.com/NordSecurity/uniffi-bindgen-cpp), with
a small hand-written ergonomics layer ([`include/loro/loro_ext.hpp`](include/loro/loro_ext.hpp))
on top.

CMake drives the whole pipeline: it builds the Rust staticlib via Corrosion,
runs uniffi-bindgen-cpp against the pinned `loro.udl`, and exposes a single
`loro::loro` target.

## Status

- Loro pinned to `loro-ffi 1.10.3` (see [loro-cpp-rs/Cargo.toml](loro-cpp-rs/Cargo.toml))
- Tested on Linux (clang), macOS (clang), and Windows MSYS2 CLANG64 — see
  [.github/workflows/release.yml](.github/workflows/release.yml)
- 31 surface tests + 16 ergonomics tests, all green

## Quickstart

```cpp
#include <loro.hpp>
#include <loro/loro_ext.hpp>

#include <iostream>

namespace ext = loro::ext;

int main() {
    auto doc  = loro::LoroDoc::init();
    auto text = doc->get_text(ext::root("body"));
    text->insert(0, "hello");
    text->insert(5, ", world");

    auto snapshot = doc->export_snapshot();

    auto fresh = loro::LoroDoc::init();
    fresh->import(snapshot);
    std::cout << fresh->get_text(ext::root("body"))->to_string() << "\n";
}
```

More samples: [examples/basic_text.cpp](examples/basic_text.cpp),
[examples/sync_two_docs.cpp](examples/sync_two_docs.cpp),
[examples/subscribe_events.cpp](examples/subscribe_events.cpp).

## Requirements

- CMake ≥ 3.22, Ninja recommended
- A C++20 compiler (clang ≥ 14, gcc ≥ 12, MSVC 19.36+)
- A Rust toolchain (stable) on `PATH` — Corrosion drives `cargo` to build the
  staticlib on first configure
- On MSYS2: install `mingw-w64-clang-x86_64-{clang,cmake,ninja,pkgconf}`. The
  top-level [CMakeLists.txt](CMakeLists.txt) auto-selects the matching Rust
  target (`gnullvm` on CLANG64, `gnu` on UCRT64/MINGW64), so a bare
  `cmake -B build -G Ninja` works.

## Build, test, install

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure

cmake --install build                       # install to CMAKE_INSTALL_PREFIX
cmake --install build --prefix /opt/loro    # ...or a custom prefix
```

Default `CMAKE_INSTALL_PREFIX` is `/usr/local` on Linux/macOS and
`C:/Program Files/loro-cpp` on Windows; set it at configure time
(`-DCMAKE_INSTALL_PREFIX=…`) or override per-install with `--prefix`.

The install tree uses [GNUInstallDirs](https://cmake.org/cmake/help/latest/module/GNUInstallDirs.html)
(so `lib/` may be `lib64/` on some Linux distros) and contains:

```
<prefix>/include/loro.hpp                       # generated bindings
<prefix>/include/loro_scaffolding.hpp           # generated FFI scaffolding
<prefix>/include/loro/loro_ext.hpp              # ergonomics layer
<prefix>/lib/<rust-archive>                     # Rust staticlib (libloro_cpp_rs.a / loro_cpp_rs.lib)
<prefix>/lib/libloro.a                          # C++ wrapper (loro.lib on MSVC)
<prefix>/lib/cmake/loro/loroConfig.cmake
<prefix>/lib/cmake/loro/loroConfigVersion.cmake
<prefix>/lib/cmake/loro/loroTargets.cmake
<prefix>/share/licenses/loro-cpp/LICENSE
```

## Using it from another project

### Option 1 — `find_package` against an installed tree

```cmake
cmake_minimum_required(VERSION 3.22)
project(myapp LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)

find_package(loro CONFIG REQUIRED)

add_executable(myapp main.cpp)
target_link_libraries(myapp PRIVATE loro::loro)
```

Configure with `-DCMAKE_PREFIX_PATH=/opt/loro`. The `loro::loro` target carries
include dirs, the Rust archive, and platform link deps (e.g. `bcrypt` on
Windows) — see [cmake/loroConfig.cmake.in](cmake/loroConfig.cmake.in).

### Option 2 — `FetchContent` (no install step)

```cmake
include(FetchContent)
FetchContent_Declare(loro
    GIT_REPOSITORY https://github.com/<you>/loro-cpp.git
    GIT_TAG        main)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LORO_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(loro)

target_link_libraries(myapp PRIVATE loro::loro)
```

Both paths are exercised end-to-end in CI via
[examples/consumer-fetchcontent/](examples/consumer-fetchcontent/).

## The ergonomics layer

`<loro/loro_ext.hpp>` papers over UniFFI-flavored corners of the generated API.
It is header-only and optional — everything in `loro.hpp` works on its own.

| Helper | Purpose |
| --- | --- |
| `ext::root("name")` | `ContainerIdLike` for a root container, usable from `get_text` / `get_map` / `get_list` / ... |
| `ext::value_from(...)` | Build a `LoroValue` from `bool`/`int`/`double`/`string`/`vector`/`map`/... |
| `ext::value_as_*(v)` | Inspection accessors returning `std::optional<T>` |
| `ext::insert_container<LoroText>(map, key)` | Type-dispatched container insertion across `LoroMap` / `LoroList` / `LoroMovableList` |
| `ext::subscribe_root(doc, lambda)`, `ext::subscribe(container, lambda)` | Lambda → callback-interface adapters around the doc/container subscribe APIs |
| `ext::try_call([&]{ ... })` | Wraps a fallible call and returns `Result<T>` instead of throwing |

Mirrors what
[`loro-cs`](https://github.com/loro-dev/loro-cs)
adds on top of its UniFFI base.

## Project layout

```
CMakeLists.txt          top-level build: Corrosion + uniffi-bindgen-cpp + install
cmake/
  loroConfig.cmake.in   downstream find_package(loro) entry
  uniffi_bindgen_cpp.cmake  fetches & invokes the bindgen tool
include/loro/loro_ext.hpp ergonomics header
loro-cpp-rs/            Rust shim crate (re-exports loro-ffi as a staticlib)
vendor/corrosion/       vendored Corrosion v0.6.1 with one MSYS2 path patch
examples/               runnable samples + CMake consumer smoke project
tests/                  surface tests for generated bindings + ergonomics
```

## License

Loro itself is MIT — see https://loro.dev. This wrapper inherits the same
terms; consult the upstream `loro-ffi` license for distribution requirements
of the embedded staticlib.
