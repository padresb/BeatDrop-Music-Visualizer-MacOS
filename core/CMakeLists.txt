set(BEATDROP_CORE_SOURCES
    src/AudioRingBuffer.cpp
    src/Contracts.cpp
    src/IniConfigStore.cpp
    src/PresetSession.cpp
    src/ProjectStatus.cpp
    src/RuntimeCoordinator.cpp
)

add_library(beatdrop_core STATIC ${BEATDROP_CORE_SOURCES})

target_compile_features(beatdrop_core PUBLIC cxx_std_17)
target_include_directories(beatdrop_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
