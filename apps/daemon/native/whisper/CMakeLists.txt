# libconduit_whisper: whisper.cpp and conduit_whisper.c in one shared
# library, for conduitd's local speech recognition. Built by
# desktop/electron/scripts/build-whisper.mjs; set
# FETCHCONTENT_SOURCE_DIR_WHISPER to use a checkout already on disk.
cmake_minimum_required(VERSION 3.16)
project(conduit_whisper C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
# Portable builds: the package runs on machines other than the one that
# built it, so no -march=native.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# ggml's own thread pool rather than OpenMP, whose runtime (libgomp) is not
# on every machine the package lands on.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
  whisper
  GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp
  GIT_TAG v1.9.4
  GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(whisper)

add_library(conduit_whisper SHARED conduit_whisper.c)
target_link_libraries(conduit_whisper PRIVATE whisper)
set_target_properties(conduit_whisper PROPERTIES C_VISIBILITY_PRESET hidden)
