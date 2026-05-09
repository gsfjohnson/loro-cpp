# examples/CMakeLists.txt
#
# Buildable end-to-end demos that exercise the public loro::loro target the
# same way a downstream consumer would. Each example is also wired up as a
# CTest entry so CI can confirm they actually run.

function(loro_cpp_add_example name)
    add_executable(${name} ${name}.cpp)
    target_link_libraries(${name} PRIVATE loro::loro)
    if(BUILD_TESTING)
        add_test(NAME example_${name} COMMAND ${name})
    endif()
endfunction()

loro_cpp_add_example(basic_text)
loro_cpp_add_example(sync_two_docs)
loro_cpp_add_example(subscribe_events)
