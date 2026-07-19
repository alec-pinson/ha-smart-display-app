// SPDX-License-Identifier: Apache-2.0
#include <jni.h>
#include <android/log.h>
#include "MicroFrontendWrapper.h"

#define LOG_TAG "MicroFrontendJNI"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// Cached JNI references
static jclass g_arrayListClass = nullptr;
static jmethodID g_arrayListInit = nullptr;
static jmethodID g_arrayListAdd = nullptr;

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    jclass local = env->FindClass("java/util/ArrayList");
    if (!local) return JNI_ERR;
    g_arrayListClass = reinterpret_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
    g_arrayListInit = env->GetMethodID(g_arrayListClass, "<init>", "(I)V");
    g_arrayListAdd  = env->GetMethodID(g_arrayListClass, "add", "(Ljava/lang/Object;)Z");
    if (!g_arrayListInit || !g_arrayListAdd) return JNI_ERR;
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNI_OnUnload(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return;
    if (g_arrayListClass) { env->DeleteGlobalRef(g_arrayListClass); g_arrayListClass = nullptr; }
}

// Package: com.alecpinson.ha_smart_display → com_alecpinson_ha_1smart_1display
// Class: MicroFrontend

JNIEXPORT jlong JNICALL
Java_com_alecpinson_ha_1smart_1display_MicroFrontend_nativeCreate(
        JNIEnv* env, jclass, jint sampleRate, jint stepSizeMs) {
    auto* wrapper = new MicroFrontendWrapper(sampleRate, (size_t)stepSizeMs);
    if (!wrapper->isInitialized()) { delete wrapper; return 0; }
    return reinterpret_cast<jlong>(wrapper);
}

JNIEXPORT void JNICALL
Java_com_alecpinson_ha_1smart_1display_MicroFrontend_nativeDestroy(
        JNIEnv* env, jclass, jlong handle) {
    if (handle) delete reinterpret_cast<MicroFrontendWrapper*>(handle);
}

JNIEXPORT jobject JNICALL
Java_com_alecpinson_ha_1smart_1display_MicroFrontend_nativeProcessSamples(
        JNIEnv* env, jclass, jlong handle, jshortArray samplesArray) {
    if (!handle || !g_arrayListClass) return nullptr;
    auto* wrapper = reinterpret_cast<MicroFrontendWrapper*>(handle);

    jsize n = env->GetArrayLength(samplesArray);
    jshort* samples = env->GetShortArrayElements(samplesArray, nullptr);
    if (!samples) return nullptr;

    auto results = wrapper->processSamples(samples, (size_t)n);
    env->ReleaseShortArrayElements(samplesArray, samples, JNI_ABORT);

    jobject list = env->NewObject(g_arrayListClass, g_arrayListInit, (jint)results.size());
    if (!list) return nullptr;

    for (const auto& frame : results) {
        jfloatArray fa = env->NewFloatArray((jsize)frame.size());
        if (!fa) { env->DeleteLocalRef(list); return nullptr; }
        env->SetFloatArrayRegion(fa, 0, (jsize)frame.size(), frame.data());
        env->CallBooleanMethod(list, g_arrayListAdd, fa);
        env->DeleteLocalRef(fa);
        if (env->ExceptionCheck()) { env->DeleteLocalRef(list); return nullptr; }
    }
    return list;
}

JNIEXPORT void JNICALL
Java_com_alecpinson_ha_1smart_1display_MicroFrontend_nativeReset(
        JNIEnv* env, jclass, jlong handle) {
    if (handle) reinterpret_cast<MicroFrontendWrapper*>(handle)->reset();
}

} // extern "C"
