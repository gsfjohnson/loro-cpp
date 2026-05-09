# Standalone consumer project that pulls loro-cpp via FetchContent and links
# against the installed `loro::loro` target. Used by CI as a smoke check that
# our install + loroConfig.cmake produces a usable package.
#
# Usage with a *source* checkout (FetchContent path):
#   cmake -S examples/consumer-fetchcontent -B build/consumer-src \
#         -DLORO_CONSUMER_MODE=fetch -DLORO_CONSUMER_SOURCE_DIR=<repo>
#   cmake --build build/consumer-src
#
# Usage with an *installed* package (find_package path):
#   cmake -S examples/consumer-fetchcontent -B build/consumer-find \
#         -DLORO_CONSUMER_MODE=find -DCMAKE_PREFIX_PATH=<install-prefix>
#   cmake --build build/consumer-find
cmake_minimum_required(VERSION 3.22)
project(loro-consumer LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LORO_CONSUMER_MODE "find" CACHE STRING
    "How to obtain loro: 'find' (find_package) or 'fetch' (FetchContent)")
set_property(CACHE LORO_CONSUMER_MODE PROPERTY STRINGS find fetch)

if(LORO_CONSUMER_MODE STREQUAL "fetch")
    set(LORO_CONSUMER_SOURCE_DIR "" CACHE PATH
        "Path to local loro-cpp checkout used by FetchContent")
    if(NOT LORO_CONSUMER_SOURCE_DIR)
        message(FATAL_ERROR
            "LORO_CONSUMER_MODE=fetch requires LORO_CONSUMER_SOURCE_DIR to point "
            "at a loro-cpp checkout.")
    endif()
    include(FetchContent)
    FetchContent_Declare(loro SOURCE_DIR "${LORO_CONSUMER_SOURCE_DIR}")
    set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
    set(LORO_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(loro)
else()
    find_package(loro CONFIG REQUIRED)
endif()

add_executable(consumer_main main.cpp)
target_link_libraries(consumer_main PRIVATE loro::loro)

enable_testing()
add_test(NAME consumer_main COMMAND consumer_main)
