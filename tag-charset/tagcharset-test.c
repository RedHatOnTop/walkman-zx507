// tagcharset-test: run libmedia's CharacterEncodingDetector, as
// StagefrightMetadataRetriever does, over tag sets from a batch file, so the
// result on the unit can be compared with tag-charset/TagSim.java. Run it with
// and without LD_PRELOAD=libzx507tagcharset.so.
//
// Batch file: per tag set a u32 count, then count pairs of NUL-terminated
// name and value. Output: per set "#<index>", then "<name>\t<value hex>".
//
// Usage (unit): tagcharset-test <batch> <out>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// android::CharacterEncodingDetector, from libmedia.so.
void _ZN7android25CharacterEncodingDetectorC1Ev(void* self);
void _ZN7android25CharacterEncodingDetectorD1Ev(void* self);
void _ZN7android25CharacterEncodingDetector6addTagEPKcS2_(void* self, const char* name,
                                                          const char* value);
size_t _ZN7android25CharacterEncodingDetector4sizeEv(void* self);
void _ZN7android25CharacterEncodingDetector16detectAndConvertEv(void* self);
int _ZN7android25CharacterEncodingDetector6getTagEiPPKcS3_(void* self, int index,
                                                           const char** name,
                                                           const char** value);

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <batch> <out>\n", argv[0]);
        return 2;
    }
    FILE* in = fopen(argv[1], "rb");
    FILE* out = fopen(argv[2], "w");
    if (!in || !out) {
        perror("open");
        return 1;
    }
    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    char* data = malloc(size);
    if (!data || fread(data, 1, size, in) != (size_t)size) {
        perror("read");
        return 1;
    }
    long pos = 0;
    for (int set = 0; pos < size; set++) {
        uint32_t count;
        memcpy(&count, data + pos, 4);
        pos += 4;
        // 2 * StringArray + 2 pointers: 40 bytes on arm, 64 on arm64.
        _Alignas(16) unsigned char det[96];
        _ZN7android25CharacterEncodingDetectorC1Ev(det);
        for (uint32_t i = 0; i < count; i++) {
            const char* name = data + pos;
            pos += strlen(name) + 1;
            const char* value = data + pos;
            pos += strlen(value) + 1;
            _ZN7android25CharacterEncodingDetector6addTagEPKcS2_(det, name, value);
        }
        _ZN7android25CharacterEncodingDetector16detectAndConvertEv(det);
        fprintf(out, "#%d\n", set);
        size_t n = _ZN7android25CharacterEncodingDetector4sizeEv(det);
        for (size_t i = 0; i < n; i++) {
            const char* name;
            const char* value;
            _ZN7android25CharacterEncodingDetector6getTagEiPPKcS3_(det, (int)i, &name, &value);
            fprintf(out, "%s\t", name);
            for (const unsigned char* p = (const unsigned char*)value; *p; p++) {
                fprintf(out, "%02x", *p);
            }
            fputc('\n', out);
        }
        _ZN7android25CharacterEncodingDetectorD1Ev(det);
    }
    fclose(out);
    return 0;
}
