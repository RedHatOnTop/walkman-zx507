"""Draws the ZX507 image's default wallpaper: a 1-bit (DSD-style) stream in champagne gold.

A second-order sigma-delta modulator turns two slow sine cycles into pulses, one hairline per
pulse, so the line density follows the signal; a seeded loudness envelope sets each line's
height, which gives the band a track-waveform outline. 1440x1280 like the stock wallpaper, so
the launcher's two pages each show one half. Everything is drawn here, nothing comes from
Sony's firmware.

Usage: python3 wallpaper/onebit.py <out.png>
"""

import sys

import numpy as np
from PIL import Image, ImageFilter

W, H = 1440, 1280
SS = 2
GOLD = np.array([0xC0, 0xA5, 0x65], float) / 255  # W.music's accent, the theme's Monet seed
HI = np.array([0xF2, 0xE4, 0xBE], float) / 255


def sdm2(x):
    i1 = i2 = 0.0
    y = 0.0
    out = np.empty_like(x)
    for n, v in enumerate(x):
        i1 += v - y
        i2 += i1 - y
        y = 1.0 if i2 >= 0 else -1.0
        out[n] = y
    return out


def envelope(t):
    rng = np.random.default_rng(507)
    e = np.zeros_like(t)
    for f in (1.3, 2.9, 6.1, 11.7, 23.0):
        e += rng.uniform(0.5, 1.0) / f ** 0.7 * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    e = (e - e.min()) / (e.max() - e.min())
    return 0.18 + 0.82 * e ** 1.3


def render(path, yc=690, band=340, pitch=3, cycles=2.0, gain=1.15):
    w, h = W * SS, H * SS
    slots = W // pitch
    t = np.arange(slots) / slots
    sig = 0.82 * np.sin(2 * np.pi * cycles * t + 0.6) + 0.12 * np.sin(2 * np.pi * 3 * cycles * t + 1.1)
    pulses = sdm2(sig) > 0

    env = envelope(t)
    img = np.zeros((h, w, 3))
    ys = np.arange(h) / SS
    core = np.exp(-((ys - yc) / 6) ** 2)
    sheen = 0.6 + 0.4 * np.cos(np.pi * (t - 0.3)) ** 2

    for k in np.nonzero(pulses)[0]:
        x0 = k * pitch * SS
        d = np.abs(ys - yc) / (band / 2 * env[k])
        a = np.clip(1 - d, 0, 1) ** 0.8 * sheen[k] * gain
        col = a[:, None] * GOLD + (core * sheen[k])[:, None] * (HI - GOLD) * 0.8
        img[:, x0:x0 + SS] = np.maximum(img[:, x0:x0 + SS], col[:, None, :])

    out = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    out = out.resize((W, H), Image.LANCZOS)
    glow = out.filter(ImageFilter.GaussianBlur(28))
    out = Image.fromarray(np.clip(np.asarray(out, float) + 0.45 * np.asarray(glow, float), 0, 255).astype(np.uint8))
    out.save(path, optimize=True)


if __name__ == "__main__":
    render(sys.argv[1])
