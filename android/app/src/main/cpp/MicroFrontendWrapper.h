// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

extern "C" {
#include "tensorflow/lite/experimental/microfrontend/lib/frontend.h"
}

class MicroFrontendWrapper {
public:
    MicroFrontendWrapper(int sampleRate, size_t stepSizeMs);
    ~MicroFrontendWrapper();

    std::vector<std::vector<float>> processSamples(const int16_t* samples, size_t numSamples);
    void reset();
    bool isInitialized() const { return initialized_; }

private:
    int sampleRate_;
    size_t stepSizeMs_;
    struct FrontendState state_;
    bool initialized_ = false;
};
