cmake_minimum_required(VERSION 3.13.0)
project(flutter_sangfor)

set(CMAKE_CXX_STANDARD 17)

add_library(flutter_sangfor SHARED fd_pass.cpp)

target_link_libraries(flutter_sangfor PUBLIC libace_napi.z.so)
