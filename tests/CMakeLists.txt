# tests/CMakeLists.txt
# Smoke / surface tests for the generated `loro` C++ binding.
# M1 ships a single round-trip test; M2 expands per-interface.

function(loro_cpp_add_test name)
    add_executable(${name} ${name}.cpp)
    target_link_libraries(${name} PRIVATE loro::loro)
    add_test(NAME ${name} COMMAND ${name})
endfunction()

loro_cpp_add_test(test_smoke)
