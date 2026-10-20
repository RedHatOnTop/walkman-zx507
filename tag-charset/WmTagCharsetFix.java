import com.android.tools.r8.CompilationMode;
import com.android.tools.r8.D8;
import com.android.tools.r8.D8Command;
import com.android.tools.r8.OutputMode;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.List;
import java.util.stream.Stream;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import javax.tools.JavaCompiler;
import javax.tools.ToolProvider;
import org.jf.dexlib2.DexFileFactory;
import org.jf.dexlib2.Opcode;
import org.jf.dexlib2.Opcodes;
import org.jf.dexlib2.builder.BuilderInstruction;
import org.jf.dexlib2.builder.MutableMethodImplementation;
import org.jf.dexlib2.builder.instruction.BuilderInstruction11x;
import org.jf.dexlib2.builder.instruction.BuilderInstruction35c;
import org.jf.dexlib2.builder.instruction.BuilderInstruction3rc;
import org.jf.dexlib2.dexbacked.DexBackedDexFile;
import org.jf.dexlib2.iface.ClassDef;
import org.jf.dexlib2.iface.Method;
import org.jf.dexlib2.iface.MethodImplementation;
import org.jf.dexlib2.iface.instruction.OneRegisterInstruction;
import org.jf.dexlib2.iface.instruction.ReferenceInstruction;
import org.jf.dexlib2.iface.reference.MethodReference;
import org.jf.dexlib2.immutable.ImmutableClassDef;
import org.jf.dexlib2.immutable.ImmutableMethod;
import org.jf.dexlib2.immutable.ImmutableMethodImplementation;
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference;
import org.jf.dexlib2.writer.io.FileDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Adds tag-charset/ZxTagCharset.java to W.music (HighResMediaPlayerApp) and calls it from
 * SpMetaParser, the tag parser W.music builds its library with: open() as setDataSource returns,
 * fix() on every string extractStringData returns, close() as release starts.
 *
 * The helper is compiled against a stub of SpMetaParser and dexed by D8 without desugaring
 * (minSdk 33), then merged into the dex that holds SpMetaParser. It is Java 8 bytecode: no
 * nestmates and no invokedynamic string concatenation, neither of which API 33 has. The JDK has
 * no ct.sym, so this is -source/-target and not --release.
 *
 * Usage: java -cp dexlib2-2.5.2.jar:guava-27.1-android.jar:d8.jar WmTagCharsetFix.java
 *            <in.apk> <ZxTagCharset.java> <out.apk>
 * The output is unsigned.
 */
public class WmTagCharsetFix {
    static final String PKG = "com/sony/songpal/localplayer/mediadb/provider/";
    static final String PARSER = "L" + PKG + "SpMetaParser;";
    static final String TYPE = "L" + PKG + "SpMetaParser$MetaType;";
    static final String HELPER = "L" + PKG + "ZxTagCharset";
    static final String STRING = "Ljava/lang/String;";
    static final String STUB = "package com.sony.songpal.localplayer.mediadb.provider;\n"
            + "public class SpMetaParser {\n"
            + "    public enum MetaType { TITLE, ALBUM, ARTIST, ALBUM_ARTIST, GENRE, COMPOSER }\n"
            + "}\n";

    static MethodReference helper(String name, String ret, String... params) {
        return new ImmutableMethodReference(HELPER + ";", name, List.of(params), ret);
    }

    static List<ClassDef> helperClasses(Path source, File tmp) throws Exception {
        Path src = tmp.toPath().resolve("src/" + PKG);
        Path cls = tmp.toPath().resolve("cls");
        Path dex = tmp.toPath().resolve("dex");
        Files.createDirectories(src);
        Files.createDirectories(cls);
        Files.createDirectories(dex);
        Files.writeString(src.resolve("SpMetaParser.java"), STUB);
        Files.copy(source, src.resolve("ZxTagCharset.java"));
        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        int rc = javac.run(null, null, null, "-source", "8", "-target", "8", "-Xlint:-options",
                "-g:none", "-nowarn", "-encoding", "UTF-8", "-d", cls.toString(),
                src.resolve("SpMetaParser.java").toString(), src.resolve("ZxTagCharset.java").toString());
        if (rc != 0) throw new IllegalStateException("javac: exit " + rc);

        List<Path> classes = new ArrayList<>();
        try (Stream<Path> s = Files.list(cls.resolve(PKG))) {
            s.filter(p -> p.getFileName().toString().startsWith("ZxTagCharset")).forEach(classes::add);
        }
        D8.run(D8Command.builder()
                .addProgramFiles(classes)
                .setMinApiLevel(33)
                .setDisableDesugaring(true)
                .setMode(CompilationMode.RELEASE)
                .setOutput(dex, OutputMode.DexIndexed)
                .build());
        List<ClassDef> out = new ArrayList<>();
        for (ClassDef c : DexFileFactory.loadDexFile(dex.resolve("classes.dex").toFile(), Opcodes.forApi(33))
                .getClasses()) {
            if (!c.getType().startsWith(HELPER)) throw new IllegalStateException("D8 emitted " + c.getType());
            out.add(c);
        }
        if (out.isEmpty()) throw new IllegalStateException("D8 emitted no " + HELPER);
        return out;
    }

    // As scripts/SysuiCompatFix.java: one debug_info item per method from dexlib2 would grow the
    // dex for pc-based line numbers ART prints anyway.
    static ClassDef strip(ClassDef c) {
        List<Method> methods = new ArrayList<>();
        for (Method m : c.getMethods()) {
            MethodImplementation code = m.getImplementation();
            if (code != null) {
                code = new ImmutableMethodImplementation(code.getRegisterCount(),
                        code.getInstructions(), code.getTryBlocks(), null);
            }
            methods.add(new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                    m.getReturnType(), m.getAccessFlags(), m.getAnnotations(),
                    m.getHiddenApiRestrictions(), code));
        }
        return new ImmutableClassDef(c.getType(), c.getAccessFlags(), c.getSuperclass(),
                c.getInterfaces(), c.getSourceFile(), c.getAnnotations(), c.getFields(), methods);
    }

    static int only(List<Integer> found, String what) {
        if (found.size() != 1) throw new IllegalStateException(PARSER + "." + what + ": " + found.size());
        return found.get(0);
    }

    static void unlabelled(MutableMethodImplementation code, int index, String what) {
        if (!code.getInstructions().get(index).getLocation().getLabels().isEmpty())
            throw new IllegalStateException(PARSER + "." + what + ": branch target at " + index);
    }

    // setDataSource(String): before its one return-void, reached once mNativeParser is set.
    static MutableMethodImplementation open(MutableMethodImplementation code) {
        List<Integer> found = new ArrayList<>();
        List<BuilderInstruction> insns = code.getInstructions();
        for (int i = 0; i < insns.size(); i++) {
            if (insns.get(i).getOpcode() == Opcode.RETURN_VOID) found.add(i);
        }
        int at = only(found, "setDataSource return-void");
        unlabelled(code, at, "setDataSource");
        code.addInstruction(at, new BuilderInstruction3rc(Opcode.INVOKE_STATIC_RANGE,
                code.getRegisterCount() - 2, 2, helper("open", "V", PARSER, STRING)));
        return code;
    }

    // extractStringData(MetaType): the string nativeExtractStringData returns goes through fix().
    static MutableMethodImplementation fix(MutableMethodImplementation code) {
        List<Integer> found = new ArrayList<>();
        List<BuilderInstruction> insns = code.getInstructions();
        for (int i = 0; i + 1 < insns.size(); i++) {
            BuilderInstruction in = insns.get(i);
            if (in.getOpcode() == Opcode.INVOKE_DIRECT
                    && ((MethodReference) ((ReferenceInstruction) in).getReference()).getName()
                            .equals("nativeExtractStringData")
                    && insns.get(i + 1).getOpcode() == Opcode.MOVE_RESULT_OBJECT) {
                found.add(i + 1);
            }
        }
        int at = only(found, "extractStringData nativeExtractStringData");
        int value = ((OneRegisterInstruction) insns.get(at)).getRegisterA();
        int self = code.getRegisterCount() - 2;
        if (self + 1 > 15 || value > 15)
            throw new IllegalStateException(PARSER + ".extractStringData: registers past v15");
        code.addInstruction(at + 1, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 3, self, self + 1,
                value, 0, 0, helper("fix", STRING, PARSER, TYPE, STRING)));
        code.addInstruction(at + 2, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, value));
        return code;
    }

    // release(): first thing, whether or not a native parser is open.
    static MutableMethodImplementation close(MutableMethodImplementation code) {
        unlabelled(code, 0, "release");
        code.addInstruction(0, new BuilderInstruction3rc(Opcode.INVOKE_STATIC_RANGE,
                code.getRegisterCount() - 1, 1, helper("close", "V", PARSER)));
        return code;
    }

    static ClassDef patchParser(ClassDef parser) {
        List<Method> methods = new ArrayList<>();
        int patched = 0;
        for (Method m : parser.getMethods()) {
            String sig = m.getName() + m.getParameterTypes() + m.getReturnType();
            MutableMethodImplementation code = m.getImplementation() == null ? null
                    : new MutableMethodImplementation(m.getImplementation());
            if (sig.equals("setDataSource[" + STRING + "]V")) code = open(code);
            else if (sig.equals("extractStringData[" + TYPE + "]" + STRING)) code = fix(code);
            else if (sig.equals("release[]V")) code = close(code);
            else code = null;
            if (code != null) {
                m = new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                        m.getReturnType(), m.getAccessFlags(), m.getAnnotations(),
                        m.getHiddenApiRestrictions(), code);
                patched++;
            }
            methods.add(m);
        }
        if (patched != 3) throw new IllegalStateException(PARSER + ": " + patched + " of 3 methods");
        return new ImmutableClassDef(parser.getType(), parser.getAccessFlags(), parser.getSuperclass(),
                parser.getInterfaces(), parser.getSourceFile(), parser.getAnnotations(),
                parser.getFields(), methods);
    }

    public static void main(String[] args) throws Exception {
        File tmp = Files.createTempDirectory("wm-tag-charset-fix").toFile();
        try (ZipFile in = new ZipFile(args[0])) {
            List<ClassDef> added = helperClasses(Path.of(args[1]), tmp);
            String target = null;
            DexBackedDexFile dexFile = null;
            for (Enumeration<? extends ZipEntry> e = in.entries(); e.hasMoreElements(); ) {
                String name = e.nextElement().getName();
                if (!name.matches("classes[0-9]*\\.dex")) continue;
                File f = new File(tmp, name);
                Files.write(f.toPath(), in.getInputStream(in.getEntry(name)).readAllBytes());
                DexBackedDexFile d = DexFileFactory.loadDexFile(f, Opcodes.forApi(33));
                for (ClassDef c : d.getClasses()) {
                    if (c.getType().startsWith(HELPER + ";") || c.getType().startsWith(HELPER + "$"))
                        throw new IllegalStateException(c.getType() + " already in " + name);
                    if (c.getType().equals(PARSER)) {
                        target = name;
                        dexFile = d;
                    }
                }
            }
            if (target == null) throw new IllegalStateException(PARSER + " not in " + args[0]);

            DexPool pool = new DexPool(dexFile.getOpcodes());
            for (ClassDef c : dexFile.getClasses()) {
                pool.internClass(c.getType().equals(PARSER) ? patchParser(strip(c)) : strip(c));
            }
            for (ClassDef c : added) pool.internClass(strip(c));
            if (pool.hasOverflowed()) throw new IllegalStateException(target + ": over 65536 ids");
            File out = new File(tmp, target + ".out");
            pool.writeTo(new FileDataStore(out));
            byte[] dex = Files.readAllBytes(out.toPath());

            try (ZipOutputStream zout = new ZipOutputStream(new FileOutputStream(args[2]))) {
                for (Enumeration<? extends ZipEntry> e = in.entries(); e.hasMoreElements(); ) {
                    ZipEntry ie = e.nextElement();
                    byte[] data = ie.getName().equals(target) ? dex : in.getInputStream(ie).readAllBytes();
                    ZipEntry oe = new ZipEntry(ie.getName());
                    oe.setTime(ie.getTime());
                    oe.setMethod(ie.getMethod());
                    if (ie.getMethod() == ZipEntry.STORED) {
                        CRC32 crc = new CRC32();
                        crc.update(data);
                        oe.setSize(data.length);
                        oe.setCompressedSize(data.length);
                        oe.setCrc(crc.getValue());
                    }
                    zout.putNextEntry(oe);
                    zout.write(data);
                    zout.closeEntry();
                }
            }
            System.out.println(args[2] + ": " + PARSER + " calls " + HELPER + "; (" + target + ")");
        } finally {
            try (Stream<Path> s = Files.walk(tmp.toPath())) {
                s.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }
}
