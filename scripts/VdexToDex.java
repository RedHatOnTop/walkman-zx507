import java.io.File;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import org.jf.dexlib2.DexFileFactory;
import org.jf.dexlib2.Opcode;
import org.jf.dexlib2.Opcodes;
import org.jf.dexlib2.dexbacked.CDexBackedDexFile;
import org.jf.dexlib2.dexbacked.DexBackedClassDef;
import org.jf.dexlib2.dexbacked.DexBackedMethod;
import org.jf.dexlib2.dexbacked.DexBackedMethodImplementation;
import org.jf.dexlib2.iface.ClassDef;
import org.jf.dexlib2.iface.instruction.Instruction;
import org.jf.dexlib2.iface.instruction.ReferenceInstruction;
import org.jf.dexlib2.iface.reference.FieldReference;
import org.jf.dexlib2.iface.reference.MethodReference;
import org.jf.dexlib2.writer.io.FileDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Turns the dex section of an Android 9 vdex (vdex 019, dex section 002, CompactDex) back into
 * standard dex files that a newer ART can run.
 *
 * Sony's stripped system apps keep their only copy of the code there. dex2oat quickened it
 * (iget-quick, invoke-virtual-quick, return-void-no-barrier, check-cast elided to nops), which
 * the vdex's quickening info lets us undo exactly, the way Android 9's DexDecompiler does:
 * every quickened instruction and every nop takes the next entry of the method's table.
 *
 * Usage: java -cp dexlib2-2.5.2.jar:guava-27.1-android.jar VdexToDex.java <in.vdex> <out-dir>
 * Writes classes.dex, classes2.dex, ... and fails if any method's table is not used up exactly,
 * or if a restored field access does not match its field's type.
 */
public class VdexToDex {
    static final int NO_INDEX = 0xffff;

    static int u16(byte[] b, int o) {
        return (b[o] & 0xff) | (b[o + 1] & 0xff) << 8;
    }

    static int u32(byte[] b, int o) {
        return u16(b, o) | u16(b, o + 2) << 16;
    }

    static void put16(byte[] b, int o, int v) {
        b[o] = (byte) v;
        b[o + 1] = (byte) (v >> 8);
    }

    static int[] uleb(byte[] b, int o) {
        int v = 0, shift = 0;
        while (true) {
            int x = b[o++] & 0xff;
            v |= (x & 0x7f) << shift;
            if (x < 0x80) return new int[] {v, o};
            shift += 7;
        }
    }

    /** art/libdexfile/dex/compact_offset_table.h, Accessor::GetOffset. */
    static int tableOffset(byte[] v, int tableAt, int index) {
        int minimum = u32(v, tableAt), tableOff = u32(v, tableAt + 4);
        int data = tableAt + 8;
        int block = data + u32(v, data + tableOff + 4 * (index / 16));
        int mask = (v[block] & 0xff) << 8 | (v[block + 1] & 0xff);
        int bit = index % 16;
        if ((mask & 1 << bit) == 0) return 0;
        int count = Integer.bitCount(mask & ((1 << (bit + 1)) - 1));
        int cur = minimum, p = block + 2;
        for (int i = 0; i < count; i++) {
            int[] r = uleb(v, p);
            cur += r[0];
            p = r[1];
        }
        return cur;
    }

    static int unquickenOp(int op) {
        switch (op) {
            case 0xe3: return 0x52; // iget
            case 0xe4: return 0x53; // iget-wide
            case 0xe5: return 0x54; // iget-object
            case 0xe6: return 0x59; // iput
            case 0xe7: return 0x5a; // iput-wide
            case 0xe8: return 0x5b; // iput-object
            case 0xe9: return 0x6e; // invoke-virtual
            case 0xea: return 0x74; // invoke-virtual/range
            case 0xeb: return 0x5c; // iput-boolean
            case 0xec: return 0x5d; // iput-byte
            case 0xed: return 0x5e; // iput-char
            case 0xee: return 0x5f; // iput-short
            case 0xef: return 0x55; // iget-boolean
            case 0xf0: return 0x56; // iget-byte
            case 0xf1: return 0x57; // iget-char
            case 0xf2: return 0x58; // iget-short
            default: return -1;
        }
    }

    /**
     * Unquickens one code item in place. Returns null on success, else why the table did not fit.
     */
    static String unquicken(byte[] buf, int start, int units, byte[] v, int info, Opcodes opcodes,
            int fieldCount, int methodCount, int[] stats) {
        int n = 0, p = info;
        if (info >= 0) {
            int[] r = uleb(v, info);
            n = r[0];
            p = r[1];
        }
        int used = 0, pos = start, end = start + 2 * units;
        while (pos < end) {
            int op = buf[pos] & 0xff;
            int size;
            if (op == 0x00) {
                int ident = u16(buf, pos);
                if (ident == 0x0100) size = u16(buf, pos + 2) * 2 + 4;
                else if (ident == 0x0200) size = u16(buf, pos + 2) * 4 + 2;
                else if (ident == 0x0300)
                    size = (int) (((long) u16(buf, pos + 2) * (u32(buf, pos + 4) & 0xffffffffL) + 1) / 2 + 4);
                else size = 1;
                if (n > 0) {
                    if (used >= n) return "table too short at nop";
                    int ref = u16(v, p + 2 * used++);
                    if (ref != NO_INDEX) {
                        if (used >= n) return "table too short at check-cast";
                        int type = u16(v, p + 2 * used++);
                        buf[pos] = 0x1f;
                        buf[pos + 1] = (byte) ref;
                        put16(buf, pos + 2, type);
                        size = 2;
                        stats[2]++;
                    }
                }
            } else if (op == 0x73) {
                buf[pos] = 0x0e;
                size = 1;
                stats[1]++;
            } else if (unquickenOp(op) >= 0) {
                if (used >= n) return String.format("table too short at op 0x%02x", op);
                int idx = u16(v, p + 2 * used++);
                boolean invoke = op == 0xe9 || op == 0xea;
                if (idx >= (invoke ? methodCount : fieldCount))
                    return String.format("index %d out of range for op 0x%02x", idx, op);
                buf[pos] = (byte) unquickenOp(op);
                put16(buf, pos + 2, idx);
                size = invoke ? 3 : 2;
                stats[0]++;
            } else {
                Opcode o = opcodes.getOpcodeByValue(op);
                if (o == null) return String.format("unknown op 0x%02x", op);
                size = o.format.size / 2;
            }
            pos += 2 * size;
        }
        if (pos != end) return "instructions overrun the code item";
        if (used != n) return "table has " + n + " entries, code used " + used;
        return null;
    }

    public static void main(String[] args) throws Exception {
        byte[] v = Files.readAllBytes(Paths.get(args[0]));
        File out = new File(args[1]);
        if (!new String(v, 0, 12, "ISO-8859-1").equals("vdex019\0" + "002\0"))
            throw new IllegalArgumentException("not a vdex 019 with a dex section");
        int nDex = u32(v, 12), depsSize = u32(v, 16);
        int o = 20 + 4 * nDex;
        int dexSize = u32(v, o), sharedSize = u32(v, o + 4), quickSize = u32(v, o + 8);
        int sharedEnd = o + 12 + dexSize + sharedSize;
        int quick = sharedEnd + depsSize;
        if (quick + quickSize != v.length) throw new IllegalArgumentException("unexpected vdex layout");
        Opcodes opcodes = Opcodes.forApi(28);
        Method startM = CDexBackedMethodImplementationAccess.find("getInstructionsStartOffset");
        Method sizeM = CDexBackedMethodImplementationAccess.find("getInstructionsSize");

        int p = o + 12;
        for (int i = 0; i < nDex; i++) {
            int qoff = u32(v, p), dexAt = p + 4;
            int fileSize = u32(v, dexAt + 0x20);
            byte[] buf = Arrays.copyOfRange(v, dexAt, sharedEnd);
            CDexBackedDexFile dex = new CDexBackedDexFile(opcodes, buf);
            int fieldCount = u32(buf, 0x50), methodCount = u32(buf, 0x58);
            String err = null;
            int[] stats = new int[3];
            int methods = 0, used = 0;
            for (int delta : new int[] {-1, 0}) {
                used = delta;
                byte[] work = buf.clone();
                Set<Integer> seen = new HashSet<>();
                stats = new int[3];
                methods = 0;
                err = null;
                for (DexBackedClassDef c : dex.getClasses()) {
                    for (DexBackedMethod m : c.getMethods()) {
                        DexBackedMethodImplementation impl = m.getImplementation();
                        if (impl == null) continue;
                        int start = dex.getBaseDataOffset() + (int) startM.invoke(impl);
                        if (!seen.add(start)) continue;
                        int units = (int) sizeM.invoke(impl);
                        int off = quickSize == 0 ? 0 : tableOffset(v, quick + qoff, m.getMethodIndex());
                        int info = off == 0 ? -1 : quick + off + delta;
                        String e = unquicken(work, start, units, v, info, opcodes, fieldCount, methodCount, stats);
                        if (e != null) {
                            err = m + ": " + e;
                            break;
                        }
                        methods++;
                    }
                    if (err != null) break;
                }
                if (err == null) {
                    System.arraycopy(work, 0, buf, 0, buf.length);
                    break;
                }
            }
            if (err != null) throw new IllegalStateException("dex " + i + ": " + err);
            DexPool pool = new DexPool(opcodes);
            int classes = 0;
            for (DexBackedClassDef c : dex.getClasses()) {
                pool.internClass(c);
                classes++;
            }
            File f = new File(out, i == 0 ? "classes.dex" : "classes" + (i + 1) + ".dex");
            pool.writeTo(new FileDataStore(f));
            int typeErrors = checkTypes(DexFileFactory.loadDexFile(f, opcodes));
            System.out.printf("%s: %d classes, %d code items, %d field/invoke + %d return-void + %d check-cast restored (table delta %d), %d type mismatches%n",
                    f.getName(), classes, methods, stats[0], stats[1], stats[2], used, typeErrors);
            if (typeErrors > 0) throw new IllegalStateException(f + ": restored field accesses do not match field types");
            p = (dexAt + fileSize + 3) & ~3;
        }
    }

    /** Each iget/iput variant names the field type it moves; a wrong restored index rarely agrees. */
    static int checkTypes(org.jf.dexlib2.iface.DexFile dex) {
        int bad = 0;
        for (ClassDef c : dex.getClasses()) {
            for (org.jf.dexlib2.iface.Method m : c.getMethods()) {
                if (m.getImplementation() == null) continue;
                for (Instruction ins : m.getImplementation().getInstructions()) {
                    String name = ins.getOpcode().name;
                    if (!name.startsWith("iget") && !name.startsWith("iput")) continue;
                    String t = ((FieldReference) ((ReferenceInstruction) ins).getReference()).getType();
                    String want = name.endsWith("-wide") ? "JD" : name.endsWith("-object") ? "L[" : name.endsWith("-boolean") ? "Z"
                            : name.endsWith("-byte") ? "B" : name.endsWith("-char") ? "C" : name.endsWith("-short") ? "S" : "IF";
                    if (want.indexOf(t.charAt(0)) < 0) {
                        if (bad++ < 5) System.err.println("  " + m + ": " + name + " on " + t);
                    }
                }
            }
        }
        return bad;
    }

    static class CDexBackedMethodImplementationAccess {
        static Method find(String name) throws Exception {
            Method m = org.jf.dexlib2.dexbacked.CDexBackedMethodImplementation.class.getDeclaredMethod(name);
            m.setAccessible(true);
            return m;
        }
    }
}
