cmake_minimum_required(VERSION 3.20)

project(hical_benchmark LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)

set(HICAL_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(HICAL_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(HICAL_WITH_DATABASE OFF CACHE BOOL "" FORCE)
set(HICAL_WITH_OPENAPI OFF CACHE BOOL "" FORCE)
set(HICAL_ENABLE_MEMORY_TRACKING OFF CACHE BOOL "" FORCE)
set(HICAL_ENABLE_MIDDLEWARE_PROFILING OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
  hical
  GIT_REPOSITORY https://github.com/Hical61/Hical.git
  GIT_TAG main
  GIT_SHALLOW TRUE
)

FetchContent_MakeAvailable(hical)

add_executable(hical_benchmark_server hical_server.cpp)
target_link_libraries(hical_benchmark_server PRIVATE hical::hical_core)
target_compile_features(hical_benchmark_server PRIVATE cxx_std_20)
