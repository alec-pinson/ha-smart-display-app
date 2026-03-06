cmake_minimum_required(VERSION 3.22.1)
project("microfrontend")

# Optimization flags applied to all targets
add_compile_options(-O3 -ffunction-sections -fdata-sections)
add_link_options(-Wl,--gc-sections)

include(FetchContent)

# ── KissFFT ──────────────────────────────────────────────────────────────────
FetchContent_Declare(
    kissfft
    GIT_REPOSITORY https://github.com/mborgerding/kissfft.git
    GIT_TAG        131.2.0
)
set(KISSFFT_STATIC ON  CACHE BOOL "" FORCE)
set(KISSFFT_TEST   OFF CACHE BOOL "" FORCE)
set(KISSFFT_TOOLS  OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(kissfft)

# ── TensorFlow Lite Micro ─────────────────────────────────────────────────────
# Pinned to same commit used by HA Android companion app (Jan 2026).
FetchContent_Declare(
    tflite_micro
    GIT_REPOSITORY https://github.com/tensorflow/tflite-micro.git
    GIT_TAG        2747abd5c82a95fb1624106a946fc671c31f16e8
)
FetchContent_Populate(tflite_micro)

set(MICROFRONTEND_DIR
    ${tflite_micro_SOURCE_DIR}/tensorflow/lite/experimental/microfrontend/lib)

# TFLM microfrontend expects kiss_fft + kiss_fftr in a tools/ subdirectory.
# kiss_fftr.c #includes kiss_fft.c directly, so all four files must be present.
set(TOOLS_DIR ${MICROFRONTEND_DIR}/tools)
file(MAKE_DIRECTORY ${TOOLS_DIR})
file(COPY ${kissfft_SOURCE_DIR}/kiss_fft.h       DESTINATION ${TOOLS_DIR})
file(COPY ${kissfft_SOURCE_DIR}/kiss_fft.c       DESTINATION ${TOOLS_DIR})
file(COPY ${kissfft_SOURCE_DIR}/_kiss_fft_guts.h DESTINATION ${TOOLS_DIR})
file(COPY ${kissfft_SOURCE_DIR}/kiss_fftr.h      DESTINATION ${TOOLS_DIR})
file(COPY ${kissfft_SOURCE_DIR}/kiss_fftr.c      DESTINATION ${TOOLS_DIR})

# ── tflite_micro_frontend static lib ─────────────────────────────────────────
add_library(tflite_micro_frontend STATIC
    ${MICROFRONTEND_DIR}/fft.cc
    ${MICROFRONTEND_DIR}/fft_util.cc
    ${MICROFRONTEND_DIR}/filterbank.c
    ${MICROFRONTEND_DIR}/filterbank_util.c
    ${MICROFRONTEND_DIR}/frontend.c
    ${MICROFRONTEND_DIR}/frontend_util.c
    ${MICROFRONTEND_DIR}/log_lut.c
    ${MICROFRONTEND_DIR}/log_scale.c
    ${MICROFRONTEND_DIR}/log_scale_util.c
    ${MICROFRONTEND_DIR}/noise_reduction.c
    ${MICROFRONTEND_DIR}/noise_reduction_util.c
    ${MICROFRONTEND_DIR}/pcan_gain_control.c
    ${MICROFRONTEND_DIR}/pcan_gain_control_util.c
    ${MICROFRONTEND_DIR}/window.c
    ${MICROFRONTEND_DIR}/window_util.c
    ${TOOLS_DIR}/kiss_fft.c
    ${TOOLS_DIR}/kiss_fftr.c
)
target_include_directories(tflite_micro_frontend PUBLIC
    ${tflite_micro_SOURCE_DIR}
    ${kissfft_SOURCE_DIR}
)
target_compile_definitions(tflite_micro_frontend PRIVATE FIXED_POINT=16)

# ── JNI shared library ────────────────────────────────────────────────────────
add_library(microfrontend SHARED
    MicroFrontendWrapper.cpp
    MicroFrontend_jni.cpp
)
target_include_directories(microfrontend PRIVATE
    ${tflite_micro_SOURCE_DIR}
)
target_link_libraries(microfrontend
    tflite_micro_frontend
    android
    log
)
