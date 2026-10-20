// Host simulation of how Android 13 decodes MP3 tags, to try tag-charset rules on a whole
// library without rescanning the unit: ID3.cpp, MP3Extractor's frame map,
// StagefrightMetadataRetriever's detector order and CharacterEncodingDetector, with ICU4J 70.1
// standing in for the unit's ICU4C 70 (one of 3637 files of the 10-17 library came out
// differently). Variant "stock" is libmedia as shipped, "W" adds libzx507tagcharset.so's rule;
// keep W identical to zx507tagcharset.cpp.
//
// Inputs: CharacterEncodingDetectorTables.h from frameworks/av android13-release; a path list
// and a dump of each file as "@@ <size>\n", its first 262144 bytes and its last 128, made on
// the unit with
//   while IFS= read -r f; do s=$(stat -c %s "$f"); echo "@@ $s"; head -c 262144 "$f";
//   tail -c 128 "$f"; done < list
// Output: one JSON line per file with the raw tags and each variant's decoded values.
//
// Usage: java -cp icu4j-70.1.jar:icu4j-charset-70.1.jar tag-charset/TagSim.java \
//            <tables.h> <list> <dump> <out.jsonl>
import com.ibm.icu.charset.CharsetProviderICU;
import com.ibm.icu.text.CharsetDetector;
import com.ibm.icu.text.CharsetMatch;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.*;
import java.nio.file.*;
import java.util.*;

public class TagSim {
    static final int HEAD = 262144;
    static int[][] FREQ = new int[4][];
    static final float[] COV = {0.718950369339973f, 0.704841200026877f, 0.880569589120162f, 0.948157021464184f};
    static final List<String> ORDER = List.of("UTF-8", "UTF-16BE", "UTF-16LE", "UTF-32BE", "UTF-32LE",
            "ISO-8859-1", "windows-1252", "ISO-8859-2", "windows-1250", "ISO-8859-5", "ISO-8859-6",
            "ISO-8859-7", "windows-1253", "ISO-8859-8-I", "ISO-8859-8", "windows-1255", "windows-1251",
            "windows-1256", "KOI8-R", "ISO-8859-9", "windows-1254", "Shift_JIS", "GB18030", "EUC-JP",
            "EUC-KR", "Big5", "ISO-2022-JP", "ISO-2022-KR", "ISO-2022-CN");
    static final CharsetProviderICU PROV = new CharsetProviderICU();
    static final Map<String, Charset> CS = new HashMap<>();

    static Charset cs(String name) {
        return CS.computeIfAbsent(name, n -> {
            try { return PROV.charsetForName(n); } catch (Exception e) { return null; }
        });
    }

    static String decode(Charset c, byte[] b) {
        CharsetDecoder d = c.newDecoder().onMalformedInput(CodingErrorAction.REPLACE)
                .onUnmappableCharacter(CodingErrorAction.REPLACE);
        try { return d.decode(ByteBuffer.wrap(b)).toString(); } catch (CharacterCodingException e) { throw new RuntimeException(e); }
    }

    // ---------- ID3 (port of media/libstagefright/id3/ID3.cpp, the parts MP3Extractor uses)
    static final int V22 = 2, V23 = 3, V24 = 4, V1 = 10, V11 = 11;

    static class Id3 {
        byte[] d; int size; int first; int ver; boolean truncated; int avail = Integer.MAX_VALUE;
        int u(int i) { return d[i] & 0xff; }
    }

    static boolean syncsafe(byte[] b, int o, long[] out) {
        long x = 0;
        for (int i = 0; i < 4; i++) {
            if ((b[o + i] & 0x80) != 0) return false;
            x = (x << 7) | (b[o + i] & 0x7f);
        }
        out[0] = x; return true;
    }

    static long u32(byte[] b, int o) {
        return ((long) (b[o] & 0xff) << 24) | ((b[o + 1] & 0xff) << 16) | ((b[o + 2] & 0xff) << 8) | (b[o + 3] & 0xff);
    }

    static Id3 parseV2(byte[] head, long fileSize) {
        if (head.length < 10) return null;
        if (head[0] != 'I' || head[1] != 'D' || head[2] != '3') return null;
        int maj = head[3] & 0xff, min = head[4] & 0xff, fl = head[5] & 0xff;
        if (maj == 0xff || min == 0xff) return null;
        if (maj == 2) { if ((fl & 0x3f) != 0 || (fl & 0x40) != 0) return null; }
        else if (maj == 3) { if ((fl & 0x1f) != 0) return null; }
        else if (maj == 4) { if ((fl & 0x0f) != 0) return null; }
        else return null;
        long[] s = new long[1];
        if (!syncsafe(head, 6, s)) return null;
        if (s[0] > 3 * 1024 * 1024) return null;
        int size = (int) s[0];
        Id3 t = new Id3();
        t.d = new byte[size];
        int avail = Math.min(size, head.length - 10);
        if (10L + size > fileSize) return null;
        System.arraycopy(head, 10, t.d, 0, avail);
        if (avail < size) { t.truncated = true; t.avail = avail; }
        t.size = size;
        boolean global = (fl & 0x80) != 0;
        if (global && maj != 4) unsync(t);
        t.first = 0;
        if (maj == 3 && (fl & 0x40) != 0) {
            if (t.size < 4) return null;
            long ext = u32(t.d, 0) + 4;
            if (ext > t.size) return null;
            t.first = (int) ext;
            if (ext >= 6) {
                if (ext >= 10) {
                    long pad = u32(t.d, 6);
                    if (pad > t.size - t.first) return null;
                    t.size -= (int) pad;
                }
            }
        } else if (maj == 4 && (fl & 0x40) != 0) {
            if (t.size < 4) return null;
            if (!syncsafe(t.d, 0, s)) return null;
            if (s[0] < 6 || s[0] > t.size) return null;
            t.first = (int) s[0];
        }
        if (maj == 4) {
            byte[] copy = t.d.clone();
            if (!unsync24(t, false, global)) {
                t.d = copy.clone(); t.size = size;
                if (!unsync24(t, true, global)) return null;
            }
        }
        t.ver = maj;
        return t;
    }

    static void unsync(Id3 t) {
        int w = 1;
        for (int r = 1; r < t.size; ++r) {
            if (t.u(r - 1) == 0xff && t.u(r) == 0x00) continue;
            t.d[w++] = t.d[r];
        }
        if (w < t.size) t.size = w;
    }

    static boolean unsync24(Id3 t, boolean itunes, boolean global) {
        int oldSize = t.size;
        int off = t.first;
        long[] s = new long[1];
        while (t.size >= 10 && off <= t.size - 10) {
            if (t.d[off] == 0 && t.d[off + 1] == 0 && t.d[off + 2] == 0 && t.d[off + 3] == 0) break;
            long ds;
            if (itunes) ds = u32(t.d, off + 4);
            else if (!syncsafe(t.d, off + 4, s)) return false; else ds = s[0];
            if (ds > t.size - 10 - off) return false;
            int dataSize = (int) ds;
            int flags = (t.u(off + 8) << 8) | t.u(off + 9);
            int prev = flags;
            if ((flags & 1) != 0) {
                if (t.size < 14 || t.size - 14 < off || dataSize < 4) return false;
                System.arraycopy(t.d, off + 14, t.d, off + 10, t.size - off - 14);
                t.size -= 4; dataSize -= 4; flags &= ~1;
            }
            if ((global || (flags & 2) != 0) && dataSize >= 2) {
                int r = off + 11, w = off + 11;
                for (int i = 0; i + 1 < dataSize; ++i) {
                    if (t.u(r - 1) == 0xff && t.u(r) == 0x00) { ++r; --t.size; --dataSize; }
                    if (i + 1 < dataSize) t.d[w++] = t.d[r++];
                }
                if (r <= oldSize) System.arraycopy(t.d, r, t.d, w, oldSize - r);
            }
            flags &= ~2;
            if (flags != prev || itunes) {
                int x = dataSize;
                for (int i = 0; i < 4; ++i) { t.d[off + 4 + 3 - i] = (byte) (x & 0x7f); x >>= 7; }
                t.d[off + 8] = (byte) (flags >> 8); t.d[off + 9] = (byte) flags;
            }
            off += 10 + dataSize;
        }
        Arrays.fill(t.d, t.size, oldSize, (byte) 0);
        return true;
    }

    static Id3 parseV1(byte[] tail) {
        if (tail.length < 128 || tail[0] != 'T' || tail[1] != 'A' || tail[2] != 'G') return null;
        Id3 t = new Id3();
        t.d = tail; t.size = 128; t.first = 3;
        t.ver = tail[125] != 0 ? V1 : V11;
        return t;
    }

    // Returns {frameOffset, frameSize} of the first frame named id, or null. Sets *partial when the
    // walk stopped at a frame extending past the bytes we have (only possible for truncated tags).
    static int[] find(Id3 t, String id, boolean[] partial) {
        int off = t.first;
        for (;;) {
            if (t.truncated && off + 10 > t.avail) { partial[0] = true; return null; }
            if (t.ver == V22) {
                if (off + 6 > t.size) return null;
                if (t.d[off] == 0 && t.d[off + 1] == 0 && t.d[off + 2] == 0) return null;
                int fs = (t.u(off + 3) << 16) | (t.u(off + 4) << 8) | t.u(off + 5);
                if (fs == 0) return null;
                fs += 6;
                if ((long) off + fs > t.size) return null;
                if (t.truncated && (long) off + fs > t.avail) { partial[0] = true; return null; }
                if (new String(t.d, off, 3, StandardCharsets.ISO_8859_1).equals(id)) return new int[]{off, fs};
                off += fs;
            } else if (t.ver == V23 || t.ver == V24) {
                if (off + 10 > t.size) return null;
                if (t.d[off] == 0 && t.d[off + 1] == 0 && t.d[off + 2] == 0 && t.d[off + 3] == 0) return null;
                long base;
                if (t.ver == V24) { long[] s = new long[1]; if (!syncsafe(t.d, off + 4, s)) return null; base = s[0]; }
                else base = u32(t.d, off + 4);
                if (base == 0) return null;
                long fs = 10 + base;
                if (off + fs > t.size) return null;
                if (t.truncated && off + fs > t.avail) { partial[0] = true; return null; }
                int flags = (t.u(off + 8) << 8) | t.u(off + 9);
                if ((t.ver == V24 && (flags & 0x000c) != 0) || (t.ver == V23 && (flags & 0x00c0) != 0)) {
                    off += (int) fs; continue;
                }
                if (new String(t.d, off, 4, StandardCharsets.ISO_8859_1).equals(id)) return new int[]{off, (int) fs};
                off += (int) fs;
            } else {
                if (off >= t.size) return null;
                int fs;
                switch (off) {
                    case 3: case 33: case 63: fs = 30; break;
                    case 93: fs = 4; break;
                    case 97: fs = t.ver == V1 ? 30 : 29; break;
                    default: fs = 1;
                }
                String gid = switch (off) {
                    case 3 -> "TT2"; case 33 -> "TP1"; case 63 -> "TAL"; case 93 -> "TYE";
                    case 97 -> "COM"; case 126 -> "TRK"; case 127 -> "TCO"; default -> "?";
                };
                if (gid.equals(id)) return new int[]{off, fs};
                off += fs;
            }
        }
    }

    static byte[] cstr(byte[] b) {
        for (int i = 0; i < b.length; i++) if (b[i] == 0) return Arrays.copyOf(b, i);
        return b;
    }

    static byte[] utf16ToUtf8(char[] c, int from, int len) {
        return new String(c, from, len).getBytes(StandardCharsets.UTF_8);
    }

    static byte[] getstring(Id3 t, int[] f) {
        int off = f[0], fs = f[1];
        if (t.ver == V1 || t.ver == V11) {
            if (off == 126 || off == 127) return Integer.toString(t.u(off)).getBytes();
            return cstr(Arrays.copyOfRange(t.d, off, off + fs));
        }
        int hl = t.ver == V22 ? 6 : 10;
        int data = off + hl;
        if (fs < hl + 1) return new byte[0];
        int n = fs - hl - 1;
        if (n <= 0) return new byte[0];
        int enc = t.u(data);
        if (enc == 0 || enc == 3) return cstr(Arrays.copyOfRange(t.d, data + 1, data + 1 + n));
        int len = n / 2;
        char[] c = new char[len];
        for (int i = 0; i < len; i++) {
            int lo = t.u(data + 1 + 2 * i), hi = t.u(data + 2 + 2 * i);
            c[i] = enc == 2 ? (char) ((lo << 8) | hi) : (char) ((hi << 8) | lo);
        }
        if (enc == 2) return cstr(utf16ToUtf8(c, 0, len));
        if (len == 0) return new byte[0];
        int from = 0;
        if (c[0] == 0xfffe) {
            if (len <= 1) return new byte[0];
            for (int i = 0; i < len; i++) c[i] = (char) Character.reverseBytes(c[i]);
            from = 1;
        } else if (c[0] == 0xfeff) {
            if (len <= 1) return new byte[0];
            from = 1;
        }
        boolean eight = true;
        for (int i = from; i < len; i++) if (c[i] > 0xff) { eight = false; break; }
        if (eight) {
            byte[] b = new byte[len - from];
            for (int i = from; i < len; i++) b[i - from] = (byte) c[i];
            return cstr(b);
        }
        // String8(char16_t*) stops at an embedded U+0000 the same way once read back as a C string.
        int end = from;
        while (end < len && c[end] != 0) end++;
        return utf16ToUtf8(c, from, end - from);
    }

    // MP3Extractor::getMetaData kMap, then StagefrightMetadataRetriever's detector order.
    static final String[][] MP3MAP = {
            {"album", "TALB", "TAL"}, {"artist", "TPE1", "TP1"}, {"albumartist", "TPE2", "TP2"},
            {"composer", "TCOM", "TCM"}, {"genre", "TCON", "TCO"}, {"title", "TIT2", "TT2"},
            {"year", "TYE", "TYER"}, {"tracknumber", "TRK", "TRCK"}, {"discnumber", "TPA", "TPOS"},
            {"compilation", "TCP", "TCMP"}};
    static final List<String> DETECTOR_ORDER = List.of("tracknumber", "discnumber", "album", "artist",
            "albumartist", "composer", "genre", "title", "year", "writer", "compilation");

    // ---------- CharacterEncodingDetector (port of media/libmedia/CharacterEncodingDetector.cpp)
    static boolean printable(byte[] v) {
        for (byte b : v) { int x = b & 0xff; if ((x & 0x80) != 0 || x < 0x20 || x == 0x7f) return false; }
        return true;
    }

    static final Set<String> COMBINED = Set.of("artist", "albumartist", "composer", "genre", "album", "title");

    static class Match { String name; int conf; int newconf = Integer.MIN_VALUE; int freq = -1, total = -1, demerit; }
    static class Pref { List<Match> ms = new ArrayList<>(); int best = -1; boolean good; int highest; boolean early; }

    static List<Match> detectAll(byte[] buf) {
        CharsetDetector det = new CharsetDetector();
        det.setText(buf);
        CharsetMatch[] r = det.detectAll();
        List<Match> ms = new ArrayList<>();
        if (r == null) return ms;
        for (CharsetMatch m : r) { Match x = new Match(); x.name = m.getName(); x.conf = m.getConfidence(); ms.add(x); }
        // ICU4C sorts stably by descending confidence in recognizer order; ICU4J reverses ties.
        ms.sort((a, b) -> a.conf != b.conf ? b.conf - a.conf : rank(a.name) - rank(b.name));
        return ms;
    }

    static int rank(String n) { int i = ORDER.indexOf(n); return i < 0 ? 99 : i; }

    static boolean isFrequent(int[] v, int c) {
        int start = 0, end = 511, mid = (start + end) / 2;
        while (start <= end) {
            if (c == v[mid]) return true;
            else if (c > v[mid]) start = mid + 1; else end = mid - 1;
            mid = (start + end) / 2;
        }
        return false;
    }

    static Pref getPreferred(byte[] input, List<Match> ms) {
        Pref p = new Pref();
        p.ms = ms;
        if (ms.isEmpty()) { p.early = true; return p; }
        if (ms.size() == 1) {
            p.best = 0; p.good = ms.get(0).conf > 15; p.highest = 0; // highestmatch untouched
            p.early = true;
            return p;
        }
        int done = 0;
        for (int i = 0; i < ms.size(); i++) {
            Match m = ms.get(i);
            int[] freq = null; float cov = 0;
            switch (m.name) {
                case "GB18030": freq = FREQ[0]; cov = COV[0]; break;
                case "Big5": freq = FREQ[1]; cov = COV[1]; break;
                case "EUC-KR": freq = FREQ[3]; cov = COV[3]; break;
                case "EUC-JP": case "Shift_JIS": freq = FREQ[2]; cov = COV[2]; break;
            }
            int confidence = m.conf, demerit = 0;
            Charset c = cs(m.name);
            int fc = 0, tc = 0;
            if (c == null) { confidence = 0; demerit += 1000; System.err.println("no converter " + m.name); }
            else {
                String s = decode(c, input);
                for (int k = 0; k < s.length(); ) {
                    int ch = s.codePointAt(k); k += Character.charCount(ch);
                    if (ch < 0x20 || (ch >= 0x7f && ch <= 0x9f)) demerit += 100;
                    else if (ch == 0xa0 || (ch >= 0xa2 && ch <= 0xbe) || ch == 0xd7 || ch == 0xf7
                            || (ch >= 0x2000 && ch <= 0x209f)) demerit += 10;
                    else if (ch >= 0xe000 && ch <= 0xf8ff) demerit += 30;
                    else if (ch >= 0x2190 && ch <= 0x2bff) demerit += 10;
                    else if (ch == 0xfffd) demerit += 50;
                    else if (ch >= 0xfff0 && ch <= 0xfffc) demerit += 50;
                    else if (freq != null) { tc++; if (isFrequent(freq, ch)) fc++; }
                }
            }
            if (freq != null && tc != 0) {
                int my = (int) (10 + ((float) ((100 * fc) / tc)) / cov);
                if (my > 100) my = 100;
                if (my < 0) my = 0;
                confidence = my;
                m.freq = fc; m.total = tc;
            }
            m.demerit = demerit;
            m.newconf = confidence - demerit;
            done = i + 1;
            if (i == 0 && m.newconf == 100) break;
        }
        int highest = ms.get(0).newconf, hi = 0, runnerup = -10000, ri = -10000;
        for (int i = 1; i < done; i++) {
            int nc = ms.get(i).newconf;
            if (nc > highest) { runnerup = highest; ri = hi; highest = nc; hi = i; }
            else if (nc > runnerup) { runnerup = nc; ri = i; }
        }
        if (ri < 0) { if (highest > 15) p.good = true; }
        else { if (runnerup < 0) runnerup = 0; if (highest - runnerup > 15) p.good = true; }
        p.highest = highest; p.best = hi;
        return p;
    }

    interface Gate { String pick(String localeEnc, Pref p, boolean good, int highest, String bestName); }

    static class Result {
        Map<String, String> out = new LinkedHashMap<>();
        List<Pref> passes = new ArrayList<>();
        String combinedenc; byte[] buf;
    }

    static byte[] cat(byte[] a, byte[] b) {
        byte[] r = Arrays.copyOf(a, a.length + b.length);
        System.arraycopy(b, 0, r, a.length, b.length);
        return r;
    }

    static byte[] strlcat(byte[] buf, byte[] v) {
        byte[] r = cat(buf, v);
        return r.length > 1023 ? Arrays.copyOf(r, 1023) : r;
    }

    static Result detect(LinkedHashMap<String, byte[]> tags, String localeEnc, Gate gate) {
        Result res = new Result();
        byte[] buf = new byte[0];
        boolean allprintable = true;
        for (var e : tags.entrySet()) {
            if (!printable(e.getValue()) && COMBINED.contains(e.getKey())) {
                buf = strlcat(buf, e.getValue()); buf = strlcat(buf, new byte[]{' '}); allprintable = false;
            }
        }
        String combinedenc = "UTF-8";
        boolean good = true; int highest = 0;
        if (!allprintable) {
            Pref p = getPreferred(buf, detectAll(buf));
            res.passes.add(p);
            good = p.good; if (!p.early) highest = p.highest;
            Match best = p.best >= 0 ? p.ms.get(p.best) : null;
            if (!good && (highest < 15 || buf.length < 20)) {
                boolean added = false;
                for (var e : tags.entrySet()) {
                    String n = e.getKey();
                    if (printable(e.getValue()) && (n.equals("artist") || n.equals("album") || n.equals("title"))) {
                        buf = strlcat(buf, e.getValue()); buf = strlcat(buf, new byte[]{' '}); added = true;
                    }
                }
                if (added) {
                    p = getPreferred(buf, detectAll(buf));
                    res.passes.add(p);
                    good = p.good; if (!p.early) highest = p.highest;
                    best = p.best >= 0 ? p.ms.get(p.best) : null;
                    if (!good && highest <= 15) best = null;
                }
            }
            combinedenc = gate.pick(localeEnc, p, good, highest, best == null ? null : best.name);
        }
        res.combinedenc = combinedenc; res.buf = buf;
        for (var e : tags.entrySet()) {
            String name = e.getKey(); byte[] s = e.getValue();
            String enc;
            if (!allprintable && COMBINED.contains(name)) {
                if (!good && highest < 0) {
                    Pref ps = getPreferred(s, detectAll(s));
                    int hs = ps.early ? 0 : ps.highest;
                    if ((ps.good || hs > highest) && ps.best >= 0) enc = ps.ms.get(ps.best).name;
                    else enc = combinedenc;
                } else enc = combinedenc;
            } else {
                if (printable(s)) enc = "UTF-8";
                else {
                    List<Match> m = detectAll(s);
                    if (m.isEmpty()) { res.out.put(name, "???"); continue; }
                    enc = m.get(0).name;
                }
            }
            String v;
            if (!enc.equals("UTF-8")) {
                Charset c = cs(enc);
                if (c == null) c = cs("ISO-8859-1");
                v = decode(c, s);
                int end = v.length();
                while (end > 1 && v.charAt(end - 1) == ' ') end--;
                v = v.substring(0, end);
                int st = 0; while (st < v.length() && v.charAt(st) == ' ') st++;
                v = v.substring(st);
            } else v = new String(s, StandardCharsets.UTF_8);
            res.out.put(name, v);
        }
        res.out.values().removeIf(String::isEmpty);
        return res;
    }

    static final Map<String, Gate> GATES = new LinkedHashMap<>();
    static {
        GATES.put("stock", (loc, p, good, hi, best) ->
                loc != null && !good && hi < 50 ? loc : best != null ? best : "ISO-8859-1");
        GATES.put("W", null);
    }


    // ---------- libzx507tagcharset.so's rule
    static boolean isLetter(int b) { return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z'); }
    static boolean isAlnum(int b) { return isLetter(b) || (b >= '0' && b <= '9'); }

    // 0: not UTF-8 (or ASCII only), 1: UTF-8 that must stay UTF-8, 2: other valid UTF-8,
    // 3: valid UTF-8 that reads as Latin letters only, two or more in a row, none next to ASCII
    static int utf8Kind(byte[] s) {
        int n = s.length, i = 0, prevEnd = -1; boolean multi = false, keep = false, letters = true, run = false;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) { i++; continue; }
            int len; int min;
            if (c >= 0xc2 && c <= 0xdf) { len = 2; min = 0x80; }
            else if (c >= 0xe0 && c <= 0xef) { len = 3; min = 0x800; }
            else if (c >= 0xf0 && c <= 0xf4) { len = 4; min = 0x10000; }
            else return 0;
            if (i + len > n) return 0;
            int cp = c & (0x7f >> len);
            for (int k = 1; k < len; k++) {
                int t = s[i + k] & 0xff;
                if ((t & 0xc0) != 0x80) return 0;
                cp = (cp << 6) | (t & 0x3f);
            }
            if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return 0;
            multi = true;
            if (cp < 0xc0 || cp > 0x24f || cp == 0xd7 || cp == 0xf7) letters = false;
            if (prevEnd == i) run = true;
            prevEnd = i + len;
            if (len > 2) keep = true;
            if ((i > 0 && isLetter(s[i - 1] & 0xff)) || (i + len < n && isLetter(s[i + len] & 0xff))) keep = true;
            i += len;
        }
        if (!multi) return 0;
        if (keep) return 1;
        return letters && run ? 3 : 2;
    }

    // Byte structure of CP949 text: KS X 1001 Hangul (rows B0-C8), symbols (rows A1-AC) and,
    // with hanja set, Hanja (rows CA-FD); plus UHC extension Hangul whose trail byte is not
    // ASCII. Without hanja the text must be Hangul or symbols only, and extension syllables
    // may not outnumber KS X 1001 ones (Shift_JIS kana fall there).
    static boolean cp949Korean(byte[] s, int n, boolean hanja) {
        int i = 0, ks = 0, uhc = 0, sym = 0, hj = 0;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) { i++; continue; }
            if (i + 1 >= n) return false;
            int t = s[i + 1] & 0xff;
            if (c >= 0xa1 && c <= 0xfe && t >= 0xa1 && t <= 0xfe) {
                if (c >= 0xb0 && c <= 0xc8) ks++;
                else if (c <= 0xac) sym++;
                else if (hanja && c >= 0xca && c <= 0xfd) hj++;
                else return false;
            } else if (c >= 0x81 && c <= 0xc5 && t >= 0x81 && t <= 0xfe) {
                uhc++;
            } else return false;
            i += 2;
        }
        return ks + uhc + sym + hj > 0 && (hanja || uhc <= ks);
    }

    // ID3v1 fields hold 30 bytes, and taggers cut CP949 text there mid-character: a 30-byte
    // value whose last byte is a lone lead byte is judged and converted without it.
    static int cp949Length(byte[] s) {
        int n = s.length, i = 0;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) { i++; continue; }
            if (i + 1 >= n) return n == 30 && c >= 0x81 && c <= 0xfe ? n - 1 : n;
            i += 2;
        }
        return n;
    }

    // One two-byte pair next to an ASCII letter or digit. In a file whose other tags are
    // Unicode, that is Latin-1 symbols more often than a syllable: "1¹¹=1" is B9 B9, 뭐.
    static boolean lonePairInText(byte[] s, int n) {
        int i = 0, pairs = 0; boolean text = false;
        while (i < n) {
            int c = s[i] & 0xff;
            if (c < 0x80) { i++; continue; }
            if (++pairs > 1) return false;
            text = (i > 0 && isAlnum(s[i - 1] & 0xff)) || (i + 2 < n && isAlnum(s[i + 2] & 0xff));
            i += 2;
        }
        return text;
    }

    static String cp949(byte[] s) {
        String v = decode(cs("windows-949-2000"), s);
        if (v.indexOf('�') >= 0) return null;
        int end = v.length();
        while (end > 1 && v.charAt(end - 1) == ' ') end--;
        v = v.substring(0, end);
        int st = 0; while (st < v.length() && v.charAt(st) == ' ') st++;
        return v.substring(st);
    }

    // Pass 1 takes fields of kind 0 or 3 that read as Korean on their own, except a lone pair in
    // ASCII text when another field is kind 1; once one has, pass 2 also takes the file's other
    // CP949-shaped fields, Hanja and kind 2 included.
    static Result wrapper(LinkedHashMap<String, byte[]> tags) {
        Map<String, String> mine = new LinkedHashMap<>();
        boolean unicode = false;
        for (var e : tags.entrySet()) {
            if (COMBINED.contains(e.getKey()) && utf8Kind(e.getValue()) == 1) unicode = true;
        }
        for (int pass = 0; pass < 2; pass++) {
            if (pass == 1 && mine.isEmpty()) break;
            for (var e : tags.entrySet()) {
                byte[] s = e.getValue();
                if (mine.containsKey(e.getKey()) || !COMBINED.contains(e.getKey()) || printable(s)) continue;
                int kind = utf8Kind(s), n = cp949Length(s);
                boolean ok = pass == 0 ? (kind == 0 || kind == 3) && !(unicode && lonePairInText(s, n)) : kind != 1;
                if (!ok || !cp949Korean(s, n, pass == 1)) continue;
                String v = cp949(Arrays.copyOf(s, n));
                if (v != null) mine.put(e.getKey(), v);
            }
        }
        LinkedHashMap<String, byte[]> rest = new LinkedHashMap<>();
        for (var e : tags.entrySet()) if (!mine.containsKey(e.getKey())) rest.put(e.getKey(), e.getValue());
        Result r = detect(rest, null, GATES.get("stock"));
        for (var e : mine.entrySet()) if (!e.getValue().isEmpty()) r.out.put(e.getKey(), e.getValue());
        r.combinedenc = (mine.isEmpty() ? "" : "W+") + r.combinedenc;
        return r;
    }

    static String hex(byte[] b) { StringBuilder s = new StringBuilder(); for (byte x : b) s.append(String.format("%02x", x)); return s.toString(); }
    static String js(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        return b.append('"').toString();
    }

    public static void main(String[] a) throws Exception {
        String tables = Files.readString(Path.of(a[0]));
        int k = 0; List<Integer> cur = new ArrayList<>();
        for (String line : tables.split("\n")) {
            String l = line.trim();
            if (l.startsWith("0x") && l.contains(",")) cur.add(Integer.parseInt(l.substring(2, l.indexOf(',')), 16));
            if (l.contains("_coverage=")) { FREQ[k++] = cur.stream().mapToInt(Integer::intValue).toArray(); cur = new ArrayList<>(); }
        }
        // order in the header: zhCN, zhTW, ja, ko -> FREQ indexes 0,1,2,3
        for (int[] f : FREQ) if (f.length != 512) throw new IllegalStateException("table " + f.length);
        List<String> paths = Files.readAllLines(Path.of(a[1]), StandardCharsets.UTF_8);
        DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(a[2]), 1 << 20));
        PrintStream out = new PrintStream(new FileOutputStream(a[3]), false, StandardCharsets.UTF_8);
        int trunc = 0;
        for (String path : paths) {
            StringBuilder hdr = new StringBuilder();
            for (int c; (c = in.read()) != '\n'; ) hdr.append((char) c);
            if (!hdr.toString().startsWith("@@ ")) throw new IllegalStateException("bad frame " + hdr);
            long size = Long.parseLong(hdr.substring(3).trim());
            byte[] head = new byte[(int) Math.min(size, HEAD)]; in.readFully(head);
            byte[] tail = new byte[(int) Math.min(size, 128)]; in.readFully(tail);
            Id3 t = parseV2(head, size);
            if (t == null) t = parseV1(tail);
            LinkedHashMap<String, byte[]> raw = new LinkedHashMap<>();
            boolean[] partial = {false};
            if (t != null) {
                Map<String, byte[]> got = new HashMap<>();
                for (String[] m : MP3MAP) {
                    int[] f = find(t, m[1], partial);
                    if (f == null) f = find(t, m[2], partial);
                    if (f == null) continue;
                    got.put(m[0], getstring(t, f));
                }
                for (String n : DETECTOR_ORDER) if (got.containsKey(n)) raw.put(n, got.get(n));
            }
            if (partial[0]) trunc++;
            StringBuilder j = new StringBuilder("{\"path\":").append(js(path));
            j.append(",\"ver\":").append(t == null ? 0 : t.ver).append(",\"partial\":").append(partial[0]);
            j.append(",\"raw\":{");
            boolean first = true;
            for (var e : raw.entrySet()) { if (!first) j.append(','); first = false; j.append(js(e.getKey())).append(':').append(js(hex(e.getValue()))); }
            j.append("}");
            for (var g : GATES.entrySet()) {
                Result r = g.getKey().equals("W") ? wrapper(raw) : detect(raw, null, g.getValue());
                j.append(",").append(js(g.getKey())).append(":{\"enc\":").append(js(r.combinedenc)).append(",\"out\":{");
                first = true;
                for (var e : r.out.entrySet()) { if (!first) j.append(','); first = false; j.append(js(e.getKey())).append(':').append(js(e.getValue())); }
                j.append("},\"passes\":[");
                for (int i = 0; i < r.passes.size(); i++) {
                    Pref p = r.passes.get(i);
                    if (i > 0) j.append(',');
                    j.append("{\"good\":").append(p.good).append(",\"highest\":").append(p.highest).append(",\"best\":").append(p.best).append(",\"ms\":[");
                    for (int q = 0; q < p.ms.size(); q++) {
                        Match m = p.ms.get(q);
                        if (q > 0) j.append(',');
                        j.append("[").append(js(m.name)).append(',').append(m.conf).append(',')
                                .append(m.newconf == Integer.MIN_VALUE ? "null" : Integer.toString(m.newconf)).append(',')
                                .append(m.freq).append(',').append(m.total).append(',').append(m.demerit).append("]");
                    }
                    j.append("]}");
                }
                j.append("]}");
                if (!g.getKey().equals("stock")) continue;
                j.append(",\"buf\":").append(js(hex(r.buf)));
            }
            out.println(j.append("}"));
        }
        out.close();
        System.err.println("files " + paths.size() + " partial " + trunc);
    }
}
