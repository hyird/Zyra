cmake_minimum_required(VERSION 3.20)

project(drogon_benchmark LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Drogon CONFIG REQUIRED)

add_executable(drogon_benchmark_server drogon_server.cpp)
target_link_libraries(drogon_benchmark_server PRIVATE Drogon::Drogon)
target_compile_features(drogon_benchmark_server PRIVATE cxx_std_20)
