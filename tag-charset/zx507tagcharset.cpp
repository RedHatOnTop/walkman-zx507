// libzx507tagcharset.so: read legacy Korean tags as CP949 in mediaserver.
//
// ID3v1 and "ISO-8859-1" ID3v2 frames carry no real encoding; Korean taggers
// wrote CP949 into them. libmedia's CharacterEncodingDetector joins all such
// tags of a file, asks ICU, and decodes every one with the winner; for short
// Korean titles ICU's pick is windows-1252, GB18030 or ISO-8859-2 about one
// time in thirty (devlog 2026-10-17), and a file mixing UTF-8 and CP949 tags
// loses both. Android's only hint is persist.sys.locale "th" for Thai.
//
// First in mediaserver's DT_NEEDED (scripts/tag-charset-gsi.sh), this defines
// CharacterEncodingDetector::detectAndConvert() ahead of libmedia. When
// persist.sys.tagloc starts with "ko", it converts the tags whose bytes have
// the shape of Korean CP949 itself, takes them out, runs libmedia's detector
// on the rest and adds them back. Pass 1 takes tags that hold Hangul and KS X
// 1001 symbols only and are not plausible UTF-8 (GB2312 Chinese often lands
// entirely in the Hangul rows, so this is a preference for Korean, not a
// proof), except a single pair inside ASCII text when another tag of the file
// is Unicode. Once a tag of the file has passed, pass 2 also takes the file's
// other CP949-shaped tags, Hanja included, unless they are clearly UTF-8.
//
// tag-charset/TagSim.java carries the same rule for the host simulation;
// keep the two identical.

#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

#define LOG_TAG "zx507tagcharset"
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" {
typedef struct UConverter UConverter;
typedef int UErrorCode;
UConverter* ucnv_open_android(const char* name, UErrorCode* err);
void ucnv_close_android(UConverter* cnv);
void ucnv_convertEx_android(UConverter* targetCnv, UConverter* sourceCnv, char** target,
                            const char* targetLimit, const char** source, const char* sourceLimit,
                            char16_t* pivotStart, char16_t** pivotSource, char16_t** pivotTarget,
                            const char16_t* pivotLimit, int8_t reset, int8_t flush,
                            UErrorCode* err);
}

namespace android {
// Layout as in frameworks/av/media/libmedia/include/media/StringArray.h and
// CharacterEncodingDetector.h (Android 13).
class StringArray {
public:
    virtual ~StringArray();
    bool push_back(const char* str);
    void erase(int idx);
    int size() const { return mCurrent; }
    const char* getEntry(int idx) const {
        return (unsigned(idx) >= unsigned(mCurrent)) ? nullptr : mArray[idx];
    }

    int mMax;
    int mCurrent;
    char** mArray;
};

class CharacterEncodingDetector {
public:
    __attribute__((visibility("default"))) void detectAndConvert();

    StringArray mNames;
    StringArray mValues;
    UConverter* mUtf8Conv;
    const char* mLocaleEnc;
};
}  // namespace android

namespace {

using Detect = void (*)(android::CharacterEncodingDetector*);
Detect gLibmedia;
pthread_once_t gOnce = PTHREAD_ONCE_INIT;

void resolve() {
    void* h = dlopen("libmedia.so", RTLD_NOW | RTLD_NOLOAD);
    if (h) {
        gLibmedia = reinterpret_cast<Detect>(
                dlsym(h, "_ZN7android25CharacterEncodingDetector16detectAndConvertEv"));
    }
    if (!gLibmedia) ALOGE("libmedia's detectAndConvert not found: %s", dlerror());
}

// The tags libmedia decodes together.
const char* const kCombined[] = {"artist", "albumartist", "composer", "genre", "album", "title"};

const char* combinedName(const char* name) {
    for (const char* n : kCombined) {
        if (!strcmp(n, name)) return n;
    }
    return nullptr;
}

bool printableAscii(const uint8_t* s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s[i] & 0x80 || s[i] < 0x20 || s[i] == 0x7f) return false;
    }
    return true;
}

bool asciiLetter(uint8_t b) { return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z'); }

bool asciiAlnum(uint8_t b) { return asciiLetter(b) || (b >= '0' && b <= '9'); }

enum Utf8 { kNotUtf8, kUtf8, kUtf8OrCp949, kCp949OrUtf8 };

// Korean CP949 is often valid two-byte UTF-8: 청혼 C3BB C8A5 reads "ûȥ", 틴탑
// "ƾž"; but so is a FLAC album "÷ (Deluxe)", C3B7 being 첨. kUtf8 for UTF-8
// with a sequence of three or more bytes, or a two-byte one next to an ASCII
// letter ("Beyoncé"); kCp949OrUtf8 when it reads as Latin letters only, two
// or more of them in a row and none next to ASCII; kUtf8OrCp949 otherwise.
Utf8 utf8Kind(const uint8_t* s, size_t n) {
    bool multi = false, keep = false, letters = true, run = false;
    size_t prevEnd = SIZE_MAX;
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        size_t len;
        uint32_t min;
        if (c >= 0xc2 && c <= 0xdf) {
            len = 2;
            min = 0x80;
        } else if (c >= 0xe0 && c <= 0xef) {
            len = 3;
            min = 0x800;
        } else if (c >= 0xf0 && c <= 0xf4) {
            len = 4;
            min = 0x10000;
        } else {
            return kNotUtf8;
        }
        if (i + len > n) return kNotUtf8;
        uint32_t cp = c & (0x7f >> len);
        for (size_t k = 1; k < len; k++) {
            if ((s[i + k] & 0xc0) != 0x80) return kNotUtf8;
            cp = (cp << 6) | (s[i + k] & 0x3f);
        }
        if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return kNotUtf8;
        multi = true;
        if (cp < 0xc0 || cp > 0x24f || cp == 0xd7 || cp == 0xf7) letters = false;
        if (prevEnd == i) run = true;
        prevEnd = i + len;
        if (len > 2 || (i > 0 && asciiLetter(s[i - 1])) || (i + len < n && asciiLetter(s[i + len]))) {
            keep = true;
        }
        i += len;
    }
    if (!multi) return kNotUtf8;
    if (keep) return kUtf8;
    return letters && run ? kCp949OrUtf8 : kUtf8OrCp949;
}

// KS X 1001 Hangul (rows B0-C8) and symbols (rows A1-AC), with hanja also
// Hanja (rows CA-FD), plus UHC extension Hangul whose trail byte is not
// ASCII ("Ál" in Latin-1 is a UHC pair with an ASCII trail). Without hanja,
// extension syllables may not outnumber KS X 1001 ones: Shift_JIS kana fall
// in the extension rows.
bool cp949Shape(const uint8_t* s, size_t n, bool hanja) {
    int ks = 0, uhc = 0, sym = 0, hj = 0;
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        if (i + 1 >= n) return false;
        uint8_t t = s[i + 1];
        if (c >= 0xa1 && c <= 0xfe && t >= 0xa1 && t <= 0xfe) {
            if (c >= 0xb0 && c <= 0xc8) {
                ks++;
            } else if (c <= 0xac) {
                sym++;
            } else if (hanja && c >= 0xca && c <= 0xfd) {
                hj++;
            } else {
                return false;
            }
        } else if (c >= 0x81 && c <= 0xc5 && t >= 0x81 && t <= 0xfe) {
            uhc++;
        } else {
            return false;
        }
        i += 2;
    }
    return ks + uhc + sym + hj > 0 && (hanja || uhc <= ks);
}

// ID3v1 fields hold 30 bytes, and taggers cut CP949 text there mid-character:
// a 30-byte value whose last byte is a lone lead byte is judged and converted
// without it.
size_t cp949Length(const uint8_t* s, size_t n) {
    size_t i = 0;
    while (i < n) {
        if (s[i] < 0x80) {
            i++;
            continue;
        }
        if (i + 1 >= n) return n == 30 && s[i] >= 0x81 && s[i] <= 0xfe ? n - 1 : n;
        i += 2;
    }
    return n;
}

// One two-byte pair next to an ASCII letter or digit. In a file whose other
// tags are Unicode, that is Latin-1 symbols more often than a syllable:
// "1¹¹=1" is B9 B9, 뭐.
bool lonePairInText(const uint8_t* s, size_t n) {
    int pairs = 0;
    bool text = false;
    size_t i = 0;
    while (i < n) {
        if (s[i] < 0x80) {
            i++;
            continue;
        }
        if (++pairs > 1) return false;
        text = (i > 0 && asciiAlnum(s[i - 1])) || (i + 2 < n && asciiAlnum(s[i + 2]));
        i += 2;
    }
    return text;
}

// The first len bytes of s from CP949 to UTF-8, with libmedia's trimming of
// converted tags; null if the text holds a cell CP949 leaves unassigned.
char* cp949ToUtf8(const char* s, size_t len) {
    UErrorCode err = 0;
    UConverter* src = ucnv_open_android("windows-949-2000", &err);
    UConverter* dst = ucnv_open_android("UTF-8", &err);
    char* out = nullptr;
    if (err <= 0) {
        size_t cap = len * 3 + 1;
        out = static_cast<char*>(malloc(cap));
        char* target = out;
        const char* source = s;
        if (out) {
            ucnv_convertEx_android(dst, src, &target, out + cap, &source, s + len, nullptr,
                                   nullptr, nullptr, nullptr, 1, 1, &err);
        }
        if (out && err <= 0) {
            *target = 0;
            if (strstr(out, "\xef\xbf\xbd")) {
                free(out);
                out = nullptr;
            } else {
                while (--target > out && *target == ' ') *target = 0;
                char* start = out;
                while (*start == ' ') start++;
                memmove(out, start, strlen(start) + 1);
            }
        } else {
            free(out);
            out = nullptr;
        }
    }
    ucnv_close_android(src);
    ucnv_close_android(dst);
    return out;
}

bool enabled() {
    char v[PROP_VALUE_MAX];
    return __system_property_get("persist.sys.tagloc", v) >= 2 && v[0] == 'k' && v[1] == 'o';
}

}  // namespace

void android::CharacterEncodingDetector::detectAndConvert() {
    pthread_once(&gOnce, resolve);
    if (!gLibmedia) return;
    if (!mUtf8Conv || !enabled()) {
        gLibmedia(this);
        return;
    }

    struct Taken {
        const char* name;
        char* value;
    } taken[sizeof(kCombined) / sizeof(kCombined[0])];
    size_t count = 0;
    bool unicode = false;
    for (int i = 0; i < mNames.size(); i++) {
        const char* value = mValues.getEntry(i);
        if (combinedName(mNames.getEntry(i)) &&
            utf8Kind(reinterpret_cast<const uint8_t*>(value), strlen(value)) == kUtf8) {
            unicode = true;
        }
    }
    for (int pass = 0; pass < 2 && (pass == 0 || count); pass++) {
        for (int i = 0; i < mNames.size();) {
            const char* name = combinedName(mNames.getEntry(i));
            const char* value = mValues.getEntry(i);
            const uint8_t* v = reinterpret_cast<const uint8_t*>(value);
            size_t len = strlen(value);
            size_t n = cp949Length(v, len);
            char* utf8 = nullptr;
            Utf8 kind = utf8Kind(v, len);
            if (name && count < sizeof(taken) / sizeof(taken[0]) && !printableAscii(v, len) &&
                (pass == 0 ? (kind == kNotUtf8 || kind == kCp949OrUtf8) &&
                                     !(unicode && lonePairInText(v, n))
                           : kind != kUtf8) &&
                cp949Shape(v, n, pass == 1)) {
                utf8 = cp949ToUtf8(value, n);
            }
            if (!utf8) {
                i++;
                continue;
            }
            taken[count++] = {name, utf8};
            mNames.erase(i);
            mValues.erase(i);
        }
    }

    gLibmedia(this);

    for (size_t k = 0; k < count; k++) {
        if (*taken[k].value) {
            mNames.push_back(taken[k].name);
            mValues.push_back(taken[k].value);
        }
        free(taken[k].value);
    }
}
