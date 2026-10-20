// dsf-tone: write a stereo DSF test file holding a sine tone, for checking
// the DSD path without copyrighted DSD material.
//
// Second-order sigma-delta modulator, 1 bit LSB first, 4096-byte blocks per
// channel (DSF spec 1.01). amp is relative to full modulation; the SACD 0 dB
// reference is 0.5.
//
// Build (host): cc -O2 -o dsf-tone scripts/dsf-tone.c -lm
// Usage: dsf-tone <64|128|256> <seconds> <hz> <amp> <out.dsf>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK 4096

static void put32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put64(FILE* f, uint64_t v) { fwrite(&v, 8, 1, f); }

int main(int argc, char** argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: %s <64|128|256> <seconds> <hz> <amp> <out.dsf>\n", argv[0]);
        return 2;
    }
    uint32_t rate = 44100u * (uint32_t)atoi(argv[1]);
    double seconds = atof(argv[2]), hz = atof(argv[3]), amp = atof(argv[4]);
    uint64_t samples = (uint64_t)(seconds * rate);
    uint64_t blocks = (samples + BLOCK * 8 - 1) / (BLOCK * 8);
    uint64_t data = blocks * BLOCK * 2;

    FILE* f = fopen(argv[5], "wb");
    if (!f) {
        perror(argv[5]);
        return 1;
    }
    fwrite("DSD ", 4, 1, f);
    put64(f, 28);
    put64(f, 28 + 52 + 12 + data);
    put64(f, 0);
    fwrite("fmt ", 4, 1, f);
    put64(f, 52);
    put32(f, 1);      // format version
    put32(f, 0);      // DSD raw
    put32(f, 2);      // channel type: stereo
    put32(f, 2);      // channels
    put32(f, rate);
    put32(f, 1);      // bits per sample, LSB first
    put64(f, samples);
    put32(f, BLOCK);
    put32(f, 0);
    fwrite("data", 4, 1, f);
    put64(f, 12 + data);

    uint8_t* buf = malloc(BLOCK * 2);
    double i1[2] = {0}, i2[2] = {0}, y[2] = {0};
    uint64_t n = 0;
    for (uint64_t b = 0; b < blocks; b++) {
        memset(buf, 0, BLOCK * 2);
        for (int byte = 0; byte < BLOCK; byte++) {
            for (int bit = 0; bit < 8; bit++, n++) {
                double x = n < samples ? amp * sin(2 * M_PI * hz * n / rate) : 0;
                for (int ch = 0; ch < 2; ch++) {
                    i1[ch] += x - y[ch];
                    i2[ch] += i1[ch] - y[ch];
                    y[ch] = i2[ch] >= 0 ? 1 : -1;
                    if (y[ch] > 0) buf[ch * BLOCK + byte] |= 1u << bit;
                }
            }
        }
        fwrite(buf, BLOCK * 2, 1, f);
    }
    free(buf);
    return fclose(f) ? 1 : 0;
}
