cmake_minimum_required(VERSION 3.10)
project(PhoneMicNr)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(entry_nr SHARED
    napi_init.cpp
    nr_pipeline.cpp
)

# NAPI、hilog 与 OHAudioSuite 引擎都在 sysroot 中，toolchain 已带 sysroot 搜索路径
target_link_libraries(entry_nr PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libohaudiosuite.so
)
