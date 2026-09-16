cmake_minimum_required(VERSION 3.18.1)
project(dabnative)

add_library(dabnative SHARED
    dab_native.cpp
    fec/init_rs_char.c
    fec/decode_rs_char.c
)

target_include_directories(dabnative PRIVATE fec)

find_library(log-lib log)
target_link_libraries(dabnative ${log-lib})
