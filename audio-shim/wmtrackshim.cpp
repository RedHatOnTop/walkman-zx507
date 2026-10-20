// libwmtrackshim.so: the Android 9 android::AudioTrack ABI that Sony's
// libspmedia_walkman.so (W.music) was built against, on top of Android 13's.
//
// Sony allocates 0x3d8 bytes, runs AudioTrack::AudioTrack() in them and then
// takes sp<> references with RefBase at offset 0. Android 13's AudioTrack is
// 0x4f0 bytes and has RefBase as a virtual base, so it cannot live in that
// block. scripts/patch-spmedia.py renames Sony's eight AudioTrack imports to
// android::WmShimTrck (same length) and points its libaudioclient.so
// DT_NEEDED here. Sony's block then holds a Proxy: a real RefBase at offset 0,
// zero at 0xa0 (Sony's inline sharedBuffer() reads mSharedBuffer there), and a
// strong reference to a real Android 13 AudioTrack that every call goes to.
//
// The forwarded set() is the Android 9 overload, which Android 13 still
// exports under the same mangled name.

#include <android/log.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>

#include <new>

#define LOG_TAG "wmtrackshim"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace android {
// Layout and virtual order as in system/core/libutils (checked against the
// GSI's _ZTVN7android7RefBaseE).
class RefBase {
public:
    void incStrong(const void* id) const;
    void decStrong(const void* id) const;

protected:
    RefBase();
    virtual ~RefBase();
    virtual void onFirstRef();
    virtual void onLastStrongRef(const void* id);
    virtual bool onIncStrongAttempted(uint32_t flags, const void* id);
    virtual void onLastWeakRef(const void* id);

private:
    void* const mRefs;
};
} // namespace android

typedef void (*callback_t)(int event, void* user, void* info);

extern "C" {
void at_ctor(void* self) __asm__("_ZN7android10AudioTrackC1Ev");
int32_t at_set(void* self, int32_t streamType, uint32_t sampleRate, uint32_t format,
               uint32_t channelMask, size_t frameCount, int32_t flags, callback_t cbf, void* user,
               int32_t notificationFrames, const void* sharedBuffer, bool threadCanCallJava,
               int32_t sessionId, int32_t transferType, const void* offloadInfo, uint32_t uid,
               int32_t pid, const void* pAttributes, bool doNotReconnect, float maxRequiredSpeed,
               int32_t selectedDeviceId)
        __asm__("_ZN7android10AudioTrack3setE19audio_stream_type_tj14audio_format_tjm20audio_output_"
                "flags_tPFviPvS4_ES4_iRKNS_2spINS_7IMemoryEEEb15audio_session_tNS0_13transfer_"
                "typeEPK20audio_offload_info_tjiPK18audio_attributes_tbfi");
int32_t at_start(void* self) __asm__("_ZN7android10AudioTrack5startEv");
void at_pause(void* self) __asm__("_ZN7android10AudioTrack5pauseEv");
void at_flush(void* self) __asm__("_ZN7android10AudioTrack5flushEv");
ssize_t at_write(void* self, const void* buffer, size_t size, bool blocking)
        __asm__("_ZN7android10AudioTrack5writeEPKvmb");
uint32_t at_latency(void* self) __asm__("_ZN7android10AudioTrack7latencyEv");
int32_t at_getMinFrameCount(size_t* frameCount, int32_t streamType, uint32_t sampleRate)
        __asm__("_ZN7android10AudioTrack16getMinFrameCountEPm19audio_stream_type_tj");
}

namespace {

constexpr size_t kSonyTrackSize = 0x3d8;          // NativeAudioTrackSinkFilter::setup()
constexpr size_t kSonySharedBufferOffset = 0xa0;  // NativeAudioTrackSinkFilter::writeToTrack()
constexpr size_t kTrackSize = 0x4f0;              // what libaudioclient itself allocates
constexpr size_t kSonyOffloadInfoSize = 48;       // audio_offload_info_t version 0.1
constexpr size_t kOffloadInfoSize = 64;           // version 0.2, which Android 13 copies
constexpr uint16_t kOffloadInfoVersion0_2 = 0x0002;

android::RefBase* refBaseOf(void* track) {
    // Itanium ABI: the virtual-base offset sits 0x18 before the address point.
    const char* vptr = *static_cast<char**>(track);
    ptrdiff_t offset = *reinterpret_cast<const ptrdiff_t*>(vptr - 0x18);
    return reinterpret_cast<android::RefBase*>(static_cast<char*>(track) + offset);
}

class Proxy : public android::RefBase {
public:
    Proxy() : track(::operator new(kTrackSize)) {
        at_ctor(track);
        refBaseOf(track)->incStrong(this);
    }
    ~Proxy() override { refBaseOf(track)->decStrong(this); }
    // Sony's block came from operator new(0x3d8); free it unsized.
    static void operator delete(void* p) { ::operator delete(p); }

    void* const track;
};

static_assert(sizeof(Proxy) <= kSonySharedBufferOffset, "Proxy overlaps Sony's mSharedBuffer read");

void* trackOf(void* self) {
    return static_cast<Proxy*>(self)->track;
}

} // namespace

extern "C" {

void shim_ctor(void* self) __asm__("_ZN7android10WmShimTrckC1Ev");
void shim_ctor(void* self) {
    memset(self, 0, kSonyTrackSize);
    new (self) Proxy();
}

int32_t shim_set(void* self, int32_t streamType, uint32_t sampleRate, uint32_t format,
                 uint32_t channelMask, size_t frameCount, int32_t flags, callback_t cbf, void* user,
                 int32_t notificationFrames, const void* sharedBuffer, bool threadCanCallJava,
                 int32_t sessionId, int32_t transferType, const void* offloadInfo, uint32_t uid,
                 int32_t pid, const void* pAttributes, bool doNotReconnect, float maxRequiredSpeed,
                 int32_t selectedDeviceId)
        __asm__("_ZN7android10WmShimTrck3setE19audio_stream_type_tj14audio_format_tjm20audio_output_"
                "flags_tPFviPvS4_ES4_iRKNS_2spINS_7IMemoryEEEb15audio_session_tNS0_13transfer_"
                "typeEPK20audio_offload_info_tjiPK18audio_attributes_tbfi");
int32_t shim_set(void* self, int32_t streamType, uint32_t sampleRate, uint32_t format,
                 uint32_t channelMask, size_t frameCount, int32_t flags, callback_t cbf, void* user,
                 int32_t notificationFrames, const void* sharedBuffer, bool threadCanCallJava,
                 int32_t sessionId, int32_t transferType, const void* offloadInfo, uint32_t uid,
                 int32_t pid, const void* pAttributes, bool doNotReconnect, float maxRequiredSpeed,
                 int32_t selectedDeviceId) {
    // Sony's DSD request carries a version 0.1 offload info. Android 13 then
    // leaves AudioOffloadInfo.encapsulationMode at its AIDL default INVALID,
    // which AudioFlinger's aidl2legacy conversion rejects with BAD_VALUE, so
    // hand it a 0.2 struct with encapsulation NONE (0) instead.
    alignas(8) unsigned char info[kOffloadInfoSize];
    if (offloadInfo != nullptr) {
        memset(info, 0, sizeof(info));
        memcpy(info, offloadInfo, kSonyOffloadInfoSize);
        const uint16_t header[2] = {kOffloadInfoVersion0_2, kOffloadInfoSize};
        memcpy(info, header, sizeof(header));
        offloadInfo = info;
    }
    int32_t status = at_set(trackOf(self), streamType, sampleRate, format, channelMask, frameCount,
                            flags, cbf, user, notificationFrames, sharedBuffer, threadCanCallJava,
                            sessionId, transferType, offloadInfo, uid, pid, pAttributes,
                            doNotReconnect, maxRequiredSpeed, selectedDeviceId);
    ALOGI("set rate=%u format=%#x mask=%#x frames=%zu flags=%#x transfer=%d offload=%d -> %d",
          sampleRate, format, channelMask, frameCount, flags, transferType, offloadInfo != nullptr,
          status);
    return status;
}

int32_t shim_start(void* self) __asm__("_ZN7android10WmShimTrck5startEv");
int32_t shim_start(void* self) {
    return at_start(trackOf(self));
}

void shim_pause(void* self) __asm__("_ZN7android10WmShimTrck5pauseEv");
void shim_pause(void* self) {
    at_pause(trackOf(self));
}

void shim_flush(void* self) __asm__("_ZN7android10WmShimTrck5flushEv");
void shim_flush(void* self) {
    at_flush(trackOf(self));
}

ssize_t shim_write(void* self, const void* buffer, size_t size, bool blocking)
        __asm__("_ZN7android10WmShimTrck5writeEPKvmb");
ssize_t shim_write(void* self, const void* buffer, size_t size, bool blocking) {
    return at_write(trackOf(self), buffer, size, blocking);
}

uint32_t shim_latency(void* self) __asm__("_ZN7android10WmShimTrck7latencyEv");
uint32_t shim_latency(void* self) {
    return at_latency(trackOf(self));
}

int32_t shim_getMinFrameCount(size_t* frameCount, int32_t streamType, uint32_t sampleRate)
        __asm__("_ZN7android10WmShimTrck16getMinFrameCountEPm19audio_stream_type_tj");
int32_t shim_getMinFrameCount(size_t* frameCount, int32_t streamType, uint32_t sampleRate) {
    return at_getMinFrameCount(frameCount, streamType, sampleRate);
}

} // extern "C"
