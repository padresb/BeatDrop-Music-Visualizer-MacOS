cmake_minimum_required(VERSION 3.25)

project(BeatDrop LANGUAGES C CXX)

option(BEATDROP_BUILD_WINDOWS_APP "Build the original Win32/Direct3D BeatDrop application" ON)
option(BEATDROP_BUILD_MACOS_BOOTSTRAP "Build the native macOS bootstrap application" ON)
option(BEATDROP_BUILD_TESTS "Build BeatDrop tests" ON)
option(BEATDROP_ENABLE_PROJECTM "Enable libprojectM auto-detection for native targets" ON)

set(BEATDROP_LOCAL_PROJECTM_PREFIX "${CMAKE_SOURCE_DIR}/third_party/install/projectm")
if(EXISTS "${BEATDROP_LOCAL_PROJECTM_PREFIX}/lib/cmake/projectM4/projectM4Config.cmake")
    list(PREPEND CMAKE_PREFIX_PATH "${BEATDROP_LOCAL_PROJECTM_PREFIX}")
endif()

add_subdirectory(core)

if(WIN32 AND BEATDROP_BUILD_WINDOWS_APP)
    add_subdirectory(vis_milk2)
endif()

if(APPLE AND BEATDROP_BUILD_MACOS_BOOTSTRAP)
    enable_language(OBJCXX)
    add_subdirectory(macos)
endif()

if(NOT WIN32 AND NOT APPLE)
    message(STATUS "No native BeatDrop target is defined for this platform yet.")
endif()

if(BEATDROP_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
