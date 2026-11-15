# libdca（DTS Coherent Acoustics 解码器）+ JNI 包装，编译成 libdtsjni.so
#
# 背景：DTS-CD 抓轨出来的 WAV 只有 RIFF 头是「PCM 16bit/44.1k/2ch」，
# data 里其实是大端 DTS 码流。Android 系统没有 DTS 解码器，
# 直接按 PCM 播就是一片噪音 —— 所以自己带一份解码器。
#
# 源码放在 app 模块下，tv 模块通过 ../app/src/main/cpp/CMakeLists.txt 复用同一份。

cmake_minimum_required(VERSION 3.22.1)

project(dtsjni C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(dtsjni SHARED
    dts_jni.c
    libdca/bitstream.c
    libdca/downmix.c
    libdca/parse.c
)

target_include_directories(dtsjni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/libdca
    ${CMAKE_CURRENT_SOURCE_DIR}/libdca/include
)

target_compile_options(dtsjni PRIVATE
    -O2
    # parse.c / downmix.c 里有大量对 float 缓冲的别名访问，-O2 的严格别名分析会算错
    -fno-strict-aliasing
    -Wno-unused-variable
    -Wno-unused-but-set-variable
    -Wno-sign-compare
)

target_link_libraries(dtsjni PRIVATE m log)
