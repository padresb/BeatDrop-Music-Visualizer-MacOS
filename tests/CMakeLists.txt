add_executable(beatdrop_core_smoke tests/core_smoke.cpp)
target_link_libraries(beatdrop_core_smoke PRIVATE beatdrop_core)
target_compile_features(beatdrop_core_smoke PRIVATE cxx_std_17)
target_compile_definitions(beatdrop_core_smoke PRIVATE BEATDROP_SOURCE_DIR="${CMAKE_SOURCE_DIR}")

add_executable(beatdrop_preset_session tests/preset_session.cpp)
target_link_libraries(beatdrop_preset_session PRIVATE beatdrop_core)
target_compile_features(beatdrop_preset_session PRIVATE cxx_std_17)

add_executable(beatdrop_ini_config_store tests/ini_config_store.cpp)
target_link_libraries(beatdrop_ini_config_store PRIVATE beatdrop_core)
target_compile_features(beatdrop_ini_config_store PRIVATE cxx_std_17)

if(APPLE)
    find_package(projectM4 CONFIG QUIET)
    find_package(projectM CONFIG QUIET)
    find_package(libprojectM CONFIG QUIET)
endif()

if(APPLE AND TARGET libprojectM::projectM)
    add_executable(
        beatdrop_macos_projectm_smoke
        tests/macos_projectm_smoke.cpp
        ${CMAKE_SOURCE_DIR}/macos/src/MacPresetEngine.cpp)
    target_link_libraries(beatdrop_macos_projectm_smoke PRIVATE beatdrop_core libprojectM::projectM)
    target_include_directories(beatdrop_macos_projectm_smoke PRIVATE ${CMAKE_SOURCE_DIR}/macos/src)
    target_compile_features(beatdrop_macos_projectm_smoke PRIVATE cxx_std_17)
    target_compile_definitions(
        beatdrop_macos_projectm_smoke
        PRIVATE
        BEATDROP_SOURCE_DIR="${CMAKE_SOURCE_DIR}"
        BEATDROP_PROJECTM_CONFIGURED=1
        BEATDROP_PROJECTM_PROVIDER="test:libprojectM::projectM"
        GL_SILENCE_DEPRECATION=1)
endif()

add_test(NAME beatdrop_core_smoke COMMAND beatdrop_core_smoke)
add_test(NAME beatdrop_preset_session COMMAND beatdrop_preset_session)
add_test(NAME beatdrop_ini_config_store COMMAND beatdrop_ini_config_store)
