// SPDX-License-Identifier: Apache-2.0
#include "MicroFrontendWrapper.h"
#include <android/log.h>

extern "C" {
#include "tensorflow/lite/experimental/microfrontend/lib/frontend_util.h"
}

#define LOG_TAG "MicroFrontend"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// Configuration matching ESPHome microWakeWord preprocessor_settings.h
namespace {
    constexpr size_t FEATURE_DURATION_MS = 30;
    constexpr int PREPROCESSOR_FEATURE_SIZE = 40;
    constexpr float FILTERBANK_LOWER_BAND_LIMIT = 125.0f;
    constexpr float FILTERBANK_UPPER_BAND_LIMIT = 7500.0f;
    constexpr int NOISE_REDUCTION_SMOOTHING_BITS = 10;
    constexpr float NOISE_REDUCTION_EVEN_SMOOTHING = 0.025f;
    constexpr float NOISE_REDUCTION_ODD_SMOOTHING = 0.06f;
    constexpr float NOISE_REDUCTION_MIN_SIGNAL_REMAINING = 0.05f;
    constexpr float PCAN_GAIN_CONTROL_STRENGTH = 0.95f;
    constexpr float PCAN_GAIN_CONTROL_OFFSET = 80.0f;
    constexpr int PCAN_GAIN_CONTROL_GAIN_BITS = 21;
    constexpr int LOG_SCALE_SCALE_SHIFT = 6;
    // Scale factor: converts uint16 microfrontend output to float (1/256 * 10)
    constexpr float FLOAT32_SCALE = 0.0390625f;
}

MicroFrontendWrapper::MicroFrontendWrapper(int sampleRate, size_t stepSizeMs)
        : sampleRate_(sampleRate), stepSizeMs_(stepSizeMs) {

    struct FrontendConfig config;
    FrontendFillConfigWithDefaults(&config);

    config.window.size_ms = FEATURE_DURATION_MS;
    config.window.step_size_ms = stepSizeMs_;
    config.filterbank.num_channels = PREPROCESSOR_FEATURE_SIZE;
    config.filterbank.lower_band_limit = FILTERBANK_LOWER_BAND_LIMIT;
    config.filterbank.upper_band_limit = FILTERBANK_UPPER_BAND_LIMIT;
    // Noise reduction + PCAN enabled — matches ESPHome training config.
    config.noise_reduction.smoothing_bits = NOISE_REDUCTION_SMOOTHING_BITS;
    config.noise_reduction.even_smoothing = NOISE_REDUCTION_EVEN_SMOOTHING;
    config.noise_reduction.odd_smoothing = NOISE_REDUCTION_ODD_SMOOTHING;
    config.noise_reduction.min_signal_remaining = NOISE_REDUCTION_MIN_SIGNAL_REMAINING;
    config.pcan_gain_control.enable_pcan = 1;
    config.pcan_gain_control.strength = PCAN_GAIN_CONTROL_STRENGTH;
    config.pcan_gain_control.offset = PCAN_GAIN_CONTROL_OFFSET;
    config.pcan_gain_control.gain_bits = PCAN_GAIN_CONTROL_GAIN_BITS;
    config.log_scale.enable_log = 1;
    config.log_scale.scale_shift = LOG_SCALE_SCALE_SHIFT;

    if (!FrontendPopulateState(&config, &state_, sampleRate_)) {
        LOGE("Failed to initialize MicroFrontend state");
        initialized_ = false;
        return;
    }
    initialized_ = true;
}

MicroFrontendWrapper::~MicroFrontendWrapper() {
    if (initialized_) {
        FrontendFreeStateContents(&state_);
    }
}

std::vector<std::vector<float>> MicroFrontendWrapper::processSamples(
        const int16_t* samples, size_t numSamples) {
    std::vector<std::vector<float>> results;
    if (!initialized_) return results;

    size_t samplesProcessed = 0;
    while (samplesProcessed < numSamples) {
        size_t numSamplesRead = 0;
        struct FrontendOutput output = FrontendProcessSamples(
                &state_,
                samples + samplesProcessed,
                numSamples - samplesProcessed,
                &numSamplesRead);

        if (numSamplesRead == 0) break;
        samplesProcessed += numSamplesRead;

        if (output.values != nullptr && output.size > 0) {
            std::vector<float> frame(PREPROCESSOR_FEATURE_SIZE);
            for (int i = 0; i < PREPROCESSOR_FEATURE_SIZE && i < (int)output.size; i++) {
                frame[i] = static_cast<float>(output.values[i]) * FLOAT32_SCALE;
            }
            results.push_back(std::move(frame));
        }
    }
    return results;
}

void MicroFrontendWrapper::reset() {
    if (initialized_) {
        FrontendReset(&state_);
    }
}
