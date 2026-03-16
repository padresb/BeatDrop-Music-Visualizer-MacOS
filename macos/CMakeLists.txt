set(BEATDROP_MACOS_SOURCES
    src/MacAudioCaptureService.mm
    src/MacPresetEngine.cpp
    src/MacSyphonOutputPublisher.mm
    src/main.mm
)

set(BEATDROP_PROJECTM_LINK_TARGET "")
set(BEATDROP_PROJECTM_PROVIDER "not-found")
set(BEATDROP_PROJECTM_CONFIGURED OFF)
set(BEATDROP_SYPHON_FRAMEWORK "")
set(BEATDROP_SYPHON_FRAMEWORK_DIR "")
set(BEATDROP_SYPHON_PROVIDER "not-found")
set(BEATDROP_SYPHON_CONFIGURED OFF)

if(BEATDROP_ENABLE_PROJECTM)
    find_package(projectM4 CONFIG QUIET)
    find_package(projectM CONFIG QUIET)
    find_package(libprojectM CONFIG QUIET)

    foreach(candidate
        libprojectM::projectM
        projectM::projectM
        projectM::libprojectM
        libprojectM::projectM
        libprojectM::libprojectM)
        if(NOT BEATDROP_PROJECTM_LINK_TARGET AND TARGET ${candidate})
            set(BEATDROP_PROJECTM_LINK_TARGET ${candidate})
            set(BEATDROP_PROJECTM_PROVIDER "cmake:${candidate}")
        endif()
    endforeach()

    if(NOT BEATDROP_PROJECTM_LINK_TARGET)
        find_package(PkgConfig QUIET)
        if(PkgConfig_FOUND)
            pkg_check_modules(BEATDROP_PROJECTM_LIBPROJECTM4 QUIET IMPORTED_TARGET libprojectM-4)
            pkg_check_modules(BEATDROP_PROJECTM_PROJECTM4 QUIET IMPORTED_TARGET projectM-4)
            pkg_check_modules(BEATDROP_PROJECTM_LIBPROJECTM QUIET IMPORTED_TARGET libprojectM)
            pkg_check_modules(BEATDROP_PROJECTM_PROJECTM QUIET IMPORTED_TARGET projectM)

            if(TARGET PkgConfig::BEATDROP_PROJECTM_LIBPROJECTM4)
                set(BEATDROP_PROJECTM_LINK_TARGET PkgConfig::BEATDROP_PROJECTM_LIBPROJECTM4)
                set(BEATDROP_PROJECTM_PROVIDER "pkg-config:libprojectM-4")
            elseif(TARGET PkgConfig::BEATDROP_PROJECTM_PROJECTM4)
                set(BEATDROP_PROJECTM_LINK_TARGET PkgConfig::BEATDROP_PROJECTM_PROJECTM4)
                set(BEATDROP_PROJECTM_PROVIDER "pkg-config:projectM-4")
            elseif(TARGET PkgConfig::BEATDROP_PROJECTM_LIBPROJECTM)
                set(BEATDROP_PROJECTM_LINK_TARGET PkgConfig::BEATDROP_PROJECTM_LIBPROJECTM)
                set(BEATDROP_PROJECTM_PROVIDER "pkg-config:libprojectM")
            elseif(TARGET PkgConfig::BEATDROP_PROJECTM_PROJECTM)
                set(BEATDROP_PROJECTM_LINK_TARGET PkgConfig::BEATDROP_PROJECTM_PROJECTM)
                set(BEATDROP_PROJECTM_PROVIDER "pkg-config:projectM")
            endif()
        endif()
    endif()
endif()

set(BEATDROP_SYPHON_FRAMEWORK_HINT "${CMAKE_SOURCE_DIR}/third_party/install/syphon/Frameworks")
set(BEATDROP_SYPHON_LOCAL_FRAMEWORK_DIR "${BEATDROP_SYPHON_FRAMEWORK_HINT}/Syphon.framework")
set(BEATDROP_SYPHON_LOCAL_FRAMEWORK_BIN "${BEATDROP_SYPHON_LOCAL_FRAMEWORK_DIR}/Versions/Current/Syphon")

if(EXISTS "${BEATDROP_SYPHON_LOCAL_FRAMEWORK_BIN}")
    set(BEATDROP_SYPHON_FRAMEWORK "${BEATDROP_SYPHON_LOCAL_FRAMEWORK_BIN}")
    set(BEATDROP_SYPHON_FRAMEWORK_DIR "${BEATDROP_SYPHON_LOCAL_FRAMEWORK_DIR}")
else()
    find_library(
        BEATDROP_SYPHON_FRAMEWORK
        NAMES Syphon
        PATHS "${BEATDROP_SYPHON_FRAMEWORK_HINT}"
        NO_DEFAULT_PATH)
    if(BEATDROP_SYPHON_FRAMEWORK)
        get_filename_component(BEATDROP_SYPHON_FRAMEWORK_DIR "${BEATDROP_SYPHON_FRAMEWORK}" DIRECTORY)
    else()
        find_library(BEATDROP_SYPHON_FRAMEWORK NAMES Syphon)
        if(BEATDROP_SYPHON_FRAMEWORK MATCHES "\\.framework")
            set(BEATDROP_SYPHON_FRAMEWORK_DIR "${BEATDROP_SYPHON_FRAMEWORK}")
        endif()
    endif()
endif()

if(BEATDROP_SYPHON_FRAMEWORK)
    set(BEATDROP_SYPHON_CONFIGURED ON)
    if(BEATDROP_SYPHON_FRAMEWORK MATCHES "^${BEATDROP_SYPHON_FRAMEWORK_HINT}")
        set(BEATDROP_SYPHON_PROVIDER "local-framework")
    else()
        set(BEATDROP_SYPHON_PROVIDER "system-framework")
    endif()
    message(STATUS "BeatDrop macOS: Syphon detected via ${BEATDROP_SYPHON_PROVIDER}")
else()
    message(STATUS "BeatDrop macOS: Syphon not detected yet.")
endif()

if(BEATDROP_PROJECTM_LINK_TARGET)
    set(BEATDROP_PROJECTM_CONFIGURED ON)
    message(STATUS "BeatDrop macOS: libprojectM detected via ${BEATDROP_PROJECTM_PROVIDER}")
else()
    message(STATUS "BeatDrop macOS: libprojectM not detected; building native fallback renderer.")
endif()

add_executable(BeatDropMacBootstrap MACOSX_BUNDLE ${BEATDROP_MACOS_SOURCES})

target_compile_features(BeatDropMacBootstrap PRIVATE cxx_std_17)
target_compile_definitions(
    BeatDropMacBootstrap
    PRIVATE
    BEATDROP_SOURCE_DIR="${CMAKE_SOURCE_DIR}"
    BEATDROP_PROJECTM_CONFIGURED=$<BOOL:${BEATDROP_PROJECTM_CONFIGURED}>
    BEATDROP_PROJECTM_PROVIDER="${BEATDROP_PROJECTM_PROVIDER}"
    BEATDROP_SYPHON_CONFIGURED=$<BOOL:${BEATDROP_SYPHON_CONFIGURED}>
    BEATDROP_SYPHON_PROVIDER="${BEATDROP_SYPHON_PROVIDER}"
    GL_SILENCE_DEPRECATION=1
)
target_compile_options(
    BeatDropMacBootstrap
    PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
)

find_library(COCOA_FRAMEWORK Cocoa REQUIRED)
find_library(AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(AVFAUDIO_FRAMEWORK AVFAudio REQUIRED)
find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(SCREENCAPTUREKIT_FRAMEWORK ScreenCaptureKit REQUIRED)
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)

target_link_libraries(
    BeatDropMacBootstrap
    PRIVATE
    beatdrop_core
    ${COCOA_FRAMEWORK}
    ${AVFOUNDATION_FRAMEWORK}
    ${AVFAUDIO_FRAMEWORK}
    ${COREAUDIO_FRAMEWORK}
    ${COREGRAPHICS_FRAMEWORK}
    ${COREMEDIA_FRAMEWORK}
    ${SCREENCAPTUREKIT_FRAMEWORK}
    ${ACCELERATE_FRAMEWORK})

if(BEATDROP_PROJECTM_LINK_TARGET)
    target_link_libraries(BeatDropMacBootstrap PRIVATE ${BEATDROP_PROJECTM_LINK_TARGET})
endif()

if(BEATDROP_SYPHON_FRAMEWORK)
    target_link_libraries(BeatDropMacBootstrap PRIVATE ${BEATDROP_SYPHON_FRAMEWORK})
endif()

set_target_properties(
    BeatDropMacBootstrap
    PROPERTIES
    OUTPUT_NAME "BeatDrop Mac"
    MACOSX_BUNDLE_BUNDLE_NAME "BeatDrop Mac"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.beatdrop.macos.bootstrap"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
)
