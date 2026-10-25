LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE     := voicefx
LOCAL_SRC_FILES  := voicefx.cpp rubberband-src/single/RubberBandSingle.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/rubberband-src
# v6: NEON + ARM mode + release flags (RubberBand's R3 live shifter is CPU heavy; the old build used plain VFP, no NDEBUG)
LOCAL_ARM_MODE   := arm
LOCAL_ARM_NEON   := true
LOCAL_CPPFLAGS   := -std=c++17 -O3 -DNDEBUG -ffast-math -fno-finite-math-only -fvisibility=hidden -fvisibility-inlines-hidden -fexceptions
LOCAL_LDLIBS     := -llog -ldl
LOCAL_LDFLAGS    := -Wl,--exclude-libs,ALL -Wl,--no-undefined
include $(BUILD_SHARED_LIBRARY)
