package com.sony.songpal.localplayer.mediadb.provider;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Locale;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * W.music's half of tag-charset: the rule of zx507tagcharset.cpp, for the tag parser W.music
 * builds its own library with. tag-charset/WmTagCharsetFix.java adds this class to W.music and
 * calls it from SpMetaParser.setDataSource, extractStringData and release.
 *
 * SpMetaParser's native parser decodes "ISO-8859-1" frames with one charset picked from the UI
 * language (CP1252 for English, UHC for Korean) and hands back strings only. With
 * persist.sys.tagloc=ko this parses the file once more with ISO-8859-1, which gives back the
 * bytes of such frames. Like libmedia, which folds UTF-16 text that fits in Latin-1 to bytes,
 * every tag whose characters all fit in Latin-1 is judged on those bytes: some taggers wrote
 * CP949 into UTF-16 frames byte by byte. The rule then decides as in mediaserver. Where
 * mediaserver leaves the rest to libmedia's detector, with the CP1252 reading, which is
 * mojibake for any CJK text, the first pass runs once more with Hanja allowed in tags that
 * hold at least as much Hangul ("사랑의 시(時)"). Valid UTF-8 is decoded as UTF-8; the rest
 * keeps the UI language's reading unless it came back empty or broken (UHC drops
 * "Beyonc\xe9"), which windows-1252 then replaces. With the CP1252 reading, files without a
 * non-ASCII tag are not parsed again.
 */
final class ZxTagCharset {
    private static final SpMetaParser.MetaType[] TYPES = {
        SpMetaParser.MetaType.TITLE, SpMetaParser.MetaType.ALBUM, SpMetaParser.MetaType.ARTIST,
        SpMetaParser.MetaType.ALBUM_ARTIST, SpMetaParser.MetaType.GENRE,
        SpMetaParser.MetaType.COMPOSER,
    };
    private static final int NOT_UTF8 = 0, UTF8 = 1, UTF8_OR_CP949 = 2, CP949_OR_UTF8 = 3;

    private static final Map<SpMetaParser, Tags> OPEN = Collections.synchronizedMap(new WeakHashMap<>());
    private static Boolean sEnabled;
    private static Method sFormat, sCharset, sCreate, sString, sDispose;
    private static Field sParser, sType;
    private static int sCp1252, sIso;
    private static Charset sCp949, sWestern;

    private static final class Tags {
        final String path;
        String[] fixed, western;

        Tags(String path) {
            this.path = path;
        }
    }

    private ZxTagCharset() {
    }

    static void open(SpMetaParser parser, String path) {
        if (enabled()) OPEN.put(parser, new Tags(path));
    }

    static void close(SpMetaParser parser) {
        OPEN.remove(parser);
    }

    static String fix(SpMetaParser parser, SpMetaParser.MetaType type, String value) {
        int i = 0;
        while (i < TYPES.length && TYPES[i] != type) i++;
        Tags tags = i < TYPES.length ? OPEN.get(parser) : null;
        if (tags == null) return value;
        if (tags.fixed == null) decide(parser, tags);
        if (tags.fixed[i] != null) return tags.fixed[i];
        boolean broken = value == null || value.isEmpty() || value.indexOf('�') >= 0;
        return broken && tags.western[i] != null ? tags.western[i] : value;
    }

    private static synchronized boolean enabled() {
        if (sEnabled == null) {
            boolean on = false;
            try {
                Method get = Class.forName("android.os.SystemProperties").getMethod("get", String.class);
                on = ((String) get.invoke(null, "persist.sys.tagloc")).startsWith("ko");
                sFormat = method("getNativeFormat", String.class);
                sCharset = method("getCharsetDefault", Locale.class);
                sCreate = method("nativeCreate", String.class, int.class, int.class);
                sString = method("nativeExtractStringData", long.class, int.class);
                sDispose = method("nativeDispose", long.class);
                sParser = SpMetaParser.class.getDeclaredField("mNativeParser");
                sParser.setAccessible(true);
                sType = SpMetaParser.MetaType.class.getDeclaredField("mNativeValue");
                sType.setAccessible(true);
                Class<?> values = Class.forName(SpMetaParser.class.getName() + "$NativeValue");
                sCp1252 = constant(values, "CHARSET_CP1252");
                sIso = constant(values, "CHARSET_ISO_8859_1");
                sCp949 = Charset.forName("windows-949-2000");
                sWestern = Charset.forName("windows-1252");
            } catch (ReflectiveOperationException | RuntimeException e) {
                on = false;
            }
            sEnabled = on;
        }
        return sEnabled;
    }

    private static Method method(String name, Class<?>... params) throws NoSuchMethodException {
        Method m = SpMetaParser.class.getDeclaredMethod(name, params);
        m.setAccessible(true);
        return m;
    }

    private static int constant(Class<?> c, String name) throws ReflectiveOperationException {
        Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f.getInt(null);
    }

    private static String[] strings(SpMetaParser parser, long native_) throws ReflectiveOperationException {
        String[] out = new String[TYPES.length];
        for (int i = 0; i < TYPES.length; i++) {
            out[i] = (String) sString.invoke(parser, native_, sType.getInt(TYPES[i]));
        }
        return out;
    }

    private static String[] read(SpMetaParser parser, String path, Object format, int charset)
            throws ReflectiveOperationException {
        long native_ = (Long) sCreate.invoke(parser, path, format, charset);
        if (native_ == 0) return null;
        try {
            return strings(parser, native_);
        } finally {
            sDispose.invoke(parser, native_);
        }
    }

    private static void decide(SpMetaParser parser, Tags tags) {
        String[] fixed = new String[TYPES.length];
        String[] western = new String[TYPES.length];
        tags.fixed = fixed;
        tags.western = western;
        try {
            boolean cp1252 = (Integer) sCharset.invoke(parser, Locale.getDefault()) == sCp1252;
            if (cp1252 && !anyHigh(strings(parser, sParser.getLong(parser)))) return;
            Object format = sFormat.invoke(parser, tags.path);
            String[] latin1 = format == null ? null : read(parser, tags.path, format, sIso);
            if (latin1 == null) return;

            byte[][] raw = new byte[TYPES.length][];
            boolean unicode = false;
            for (int i = 0; i < TYPES.length; i++) {
                String v = latin1[i];
                if (v == null) continue;
                byte[] seen;
                if (isLatin1(v)) {
                    seen = v.getBytes(StandardCharsets.ISO_8859_1);
                    if (anyHigh(v)) raw[i] = seen;
                } else {
                    seen = v.getBytes(StandardCharsets.UTF_8);
                }
                if (utf8Kind(seen) == UTF8) unicode = true;
            }

            int taken = 0;
            for (int pass = 0; pass < 3; pass++) {
                if (pass == 1 && taken == 0) continue;
                if (pass == 2 && !cp1252) break;
                for (int i = 0; i < TYPES.length; i++) {
                    byte[] s = raw[i];
                    if (s == null || fixed[i] != null) continue;
                    int kind = utf8Kind(s), n = cp949Length(s);
                    boolean first = (kind == NOT_UTF8 || kind == CP949_OR_UTF8)
                            && !(unicode && lonePairInText(s, n));
                    boolean ok = pass == 1 ? kind != UTF8 && cp949Shape(s, n, true)
                            : first && cp949Shape(s, n, pass == 2) && (pass == 0 || hangulOverHanja(s, n));
                    if (ok) {
                        fixed[i] = cp949(s, n);
                        if (fixed[i] != null) taken++;
                    }
                }
            }

            for (int i = 0; i < TYPES.length; i++) {
                if (raw[i] == null || fixed[i] != null) continue;
                if (utf8Kind(raw[i]) != NOT_UTF8) {
                    fixed[i] = new String(raw[i], StandardCharsets.UTF_8);
                } else {
                    String w = new String(raw[i], sWestern);
                    if (w.indexOf('�') < 0) western[i] = w;
                }
            }
        } catch (ReflectiveOperationException | RuntimeException e) {
            tags.fixed = new String[TYPES.length];
            tags.western = new String[TYPES.length];
        }
    }

    private static boolean anyHigh(String v) {
        for (int i = 0; i < v.length(); i++) {
            if (v.charAt(i) >= 0x80) return true;
        }
        return false;
    }

    private static boolean anyHigh(String[] values) {
        for (String v : values) {
            if (v != null && anyHigh(v)) return true;
        }
        return false;
    }

    private static boolean isLatin1(String v) {
        for (int i = 0; i < v.length(); i++) {
            if (v.charAt(i) > 0xff) return false;
        }
        return true;
    }

    private static boolean asciiLetter(int b) {
        return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z');
    }

    private static boolean asciiAlnum(int b) {
        return asciiLetter(b) || (b >= '0' && b <= '9');
    }

    // zx507tagcharset.cpp utf8Kind()
    private static int utf8Kind(byte[] s) {
        int n = s.length, i = 0, prevEnd = -1;
        boolean multi = false, keep = false, letters = true, run = false;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) {
                i++;
                continue;
            }
            int len, min;
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
                return NOT_UTF8;
            }
            if (i + len > n) return NOT_UTF8;
            int cp = c & (0x7f >> len);
            for (int k = 1; k < len; k++) {
                int t = s[i + k] & 0xff;
                if ((t & 0xc0) != 0x80) return NOT_UTF8;
                cp = (cp << 6) | (t & 0x3f);
            }
            if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return NOT_UTF8;
            multi = true;
            if (cp < 0xc0 || cp > 0x24f || cp == 0xd7 || cp == 0xf7) letters = false;
            if (prevEnd == i) run = true;
            prevEnd = i + len;
            if (len > 2 || (i > 0 && asciiLetter(s[i - 1] & 0xff))
                    || (i + len < n && asciiLetter(s[i + len] & 0xff))) {
                keep = true;
            }
            i += len;
        }
        if (!multi) return NOT_UTF8;
        if (keep) return UTF8;
        return letters && run ? CP949_OR_UTF8 : UTF8_OR_CP949;
    }

    // zx507tagcharset.cpp cp949Shape()
    private static boolean cp949Shape(byte[] s, int n, boolean hanja) {
        int i = 0, ks = 0, uhc = 0, sym = 0, hj = 0;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) {
                i++;
                continue;
            }
            if (i + 1 >= n) return false;
            int t = s[i + 1] & 0xff;
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

    // zx507tagcharset.cpp cp949Length()
    private static int cp949Length(byte[] s) {
        int n = s.length, i = 0;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) {
                i++;
                continue;
            }
            if (i + 1 >= n) return n == 30 && c >= 0x81 && c <= 0xfe ? n - 1 : n;
            i += 2;
        }
        return n;
    }

    // zx507tagcharset.cpp lonePairInText()
    private static boolean lonePairInText(byte[] s, int n) {
        int i = 0, pairs = 0;
        boolean text = false;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) {
                i++;
                continue;
            }
            if (++pairs > 1) return false;
            text = (i > 0 && asciiAlnum(s[i - 1] & 0xff)) || (i + 2 < n && asciiAlnum(s[i + 2] & 0xff));
            i += 2;
        }
        return text;
    }

    // At least one KS X 1001 syllable, and no more Hanja than those. A preference, not a proof:
    // GB2312 Chinese spreads over rows B0-F7, so much of it lands in the Hanja rows.
    private static boolean hangulOverHanja(byte[] s, int n) {
        int i = 0, ks = 0, hj = 0;
        while (i + 1 < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) {
                i++;
                continue;
            }
            if (c >= 0xb0 && c <= 0xc8 && (s[i + 1] & 0xff) >= 0xa1) ks++;
            else if (c >= 0xca && c <= 0xfd) hj++;
            i += 2;
        }
        return ks > 0 && ks >= hj;
    }

    // zx507tagcharset.cpp cp949ToUtf8()
    private static String cp949(byte[] s, int n) {
        String v = new String(s, 0, n, sCp949);
        if (v.indexOf('�') >= 0) return null;
        int start = 0, end = v.length();
        while (end > 0 && v.charAt(end - 1) == ' ') end--;
        while (start < end && v.charAt(start) == ' ') start++;
        return v.substring(start, end);
    }
}
