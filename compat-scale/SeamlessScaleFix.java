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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
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
import org.jf.dexlib2.builder.instruction.BuilderInstruction35c;
import org.jf.dexlib2.dexbacked.DexBackedDexFile;
import org.jf.dexlib2.iface.ClassDef;
import org.jf.dexlib2.iface.Method;
import org.jf.dexlib2.iface.instruction.FiveRegisterInstruction;
import org.jf.dexlib2.iface.instruction.OneRegisterInstruction;
import org.jf.dexlib2.iface.instruction.ReferenceInstruction;
import org.jf.dexlib2.iface.reference.MethodReference;
import org.jf.dexlib2.immutable.ImmutableClassDef;
import org.jf.dexlib2.immutable.ImmutableMethod;
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference;
import org.jf.dexlib2.writer.io.FileDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Adds compat-scale/ZxSeamlessScale.java to services.jar and calls
 * ZxSeamlessScale.restore(this, t) in WindowState.finishSeamlessRotation right after
 * SeamlessRotator.finish has reset the window surface's matrix.
 *
 * Built like microg/MicrogSpoofFix.java: the helper is compiled against stubs of the classes it
 * uses (Java 8 bytecode, -source/-target since the JDK has no ct.sym), dexed by D8 without
 * desugaring and merged into the dex that holds WindowState.
 *
 * Usage: java -cp dexlib2-2.5.2.jar:guava-27.1-android.jar:d8.jar SeamlessScaleFix.java
 *            <in services.jar> <ZxSeamlessScale.java> <out.jar>
 * The output is not zipaligned.
 */
public class SeamlessScaleFix {
    static final String WINDOW = "Lcom/android/server/wm/WindowState;";
    static final String HELPER = "Lcom/android/server/wm/ZxSeamlessScale";
    static final String ROTATOR = "Lcom/android/server/wm/SeamlessRotator;";
    static final String TRANSACTION = "Landroid/view/SurfaceControl$Transaction;";
    static final Map<String, String> STUBS = new LinkedHashMap<>();
    static {
        STUBS.put("android/view/SurfaceControl.java", "package android.view;\n"
                + "public final class SurfaceControl {\n"
                + "    public boolean isValid() { return false; }\n"
                + "    public static class Transaction {\n"
                + "        public Transaction setMatrix(SurfaceControl sc, float dsdx, float dtdx,\n"
                + "                float dtdy, float dsdy) { return this; }\n"
                + "    }\n"
                + "}\n");
        STUBS.put("com/android/server/wm/WindowState.java", "package com.android.server.wm;\n"
                + "public class WindowState {\n"
                + "    public float mLastHScale;\n"
                + "    public float mLastVScale;\n"
                + "    public android.view.SurfaceControl getSurfaceControl() { return null; }\n"
                + "}\n");
    }

    static List<ClassDef> helperClasses(Path source, File tmp) throws Exception {
        Path src = tmp.toPath().resolve("src");
        Path cls = tmp.toPath().resolve("cls");
        Path dex = tmp.toPath().resolve("dex");
        List<String> args = new ArrayList<>(List.of("-source", "8", "-target", "8", "-Xlint:-options",
                "-g:none", "-nowarn", "-encoding", "UTF-8", "-d", cls.toString()));
        for (Map.Entry<String, String> e : STUBS.entrySet()) {
            Path p = src.resolve(e.getKey());
            Files.createDirectories(p.getParent());
            Files.writeString(p, e.getValue());
            args.add(p.toString());
        }
        Path helper = src.resolve("com/android/server/wm/ZxSeamlessScale.java");
        Files.createDirectories(helper.getParent());
        Files.copy(source, helper);
        args.add(helper.toString());
        Files.createDirectories(cls);
        Files.createDirectories(dex);
        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        int rc = javac.run(null, null, null, args.toArray(new String[0]));
        if (rc != 0) throw new IllegalStateException("javac: exit " + rc);

        List<Path> classes = new ArrayList<>();
        try (Stream<Path> s = Files.list(cls.resolve("com/android/server/wm"))) {
            s.filter(p -> p.getFileName().toString().startsWith("ZxSeamlessScale")).forEach(classes::add);
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

    // finishSeamlessRotation(t): the one `invoke-virtual {rotator, t, this}, SeamlessRotator.finish`
    // gets `invoke-static {this, t}, ZxSeamlessScale.restore` after it. Both registers must still
    // hold the parameters there.
    static MutableMethodImplementation hook(MutableMethodImplementation code) {
        List<BuilderInstruction> insns = code.getInstructions();
        int self = code.getRegisterCount() - 2, t = code.getRegisterCount() - 1;
        int at = -1;
        for (int i = 0; i < insns.size(); i++) {
            BuilderInstruction in = insns.get(i);
            if (in.getOpcode() == Opcode.INVOKE_VIRTUAL) {
                MethodReference m = (MethodReference) ((ReferenceInstruction) in).getReference();
                if (m.getDefiningClass().equals(ROTATOR) && m.getName().equals("finish")) {
                    FiveRegisterInstruction f = (FiveRegisterInstruction) in;
                    if (at != -1 || f.getRegisterD() != t || f.getRegisterE() != self)
                        throw new IllegalStateException(WINDOW + ".finishSeamlessRotation: unexpected finish call");
                    at = i + 1;
                    continue;
                }
            }
            if (at == -1 && in.getOpcode().setsRegister() && in instanceof OneRegisterInstruction) {
                int a = ((OneRegisterInstruction) in).getRegisterA();
                if (a == self || a == t)
                    throw new IllegalStateException(WINDOW + ".finishSeamlessRotation: v" + a + " written");
            }
        }
        if (at == -1 || at >= insns.size())
            throw new IllegalStateException(WINDOW + ".finishSeamlessRotation: no SeamlessRotator.finish");
        if (!insns.get(at).getLocation().getLabels().isEmpty())
            throw new IllegalStateException(WINDOW + ".finishSeamlessRotation: branch target at " + at);
        if (self > 15 || t > 15)
            throw new IllegalStateException(WINDOW + ".finishSeamlessRotation: registers past v15");
        code.addInstruction(at, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 2, self, t, 0, 0, 0,
                new ImmutableMethodReference(HELPER + ";", "restore", List.of(WINDOW, TRANSACTION), "V")));
        return code;
    }

    static ClassDef patchWindow(ClassDef window) {
        List<Method> methods = new ArrayList<>();
        int patched = 0;
        for (Method m : window.getMethods()) {
            if (m.getName().equals("finishSeamlessRotation") && m.getParameterTypes().size() == 1
                    && m.getParameterTypes().get(0).toString().equals(TRANSACTION)
                    && m.getImplementation() != null) {
                MutableMethodImplementation code = hook(new MutableMethodImplementation(m.getImplementation()));
                m = new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                        m.getReturnType(), m.getAccessFlags(), m.getAnnotations(),
                        m.getHiddenApiRestrictions(), code);
                patched++;
            }
            methods.add(m);
        }
        if (patched != 1) throw new IllegalStateException(WINDOW + ": " + patched + " finishSeamlessRotation");
        return new ImmutableClassDef(window.getType(), window.getAccessFlags(), window.getSuperclass(),
                window.getInterfaces(), window.getSourceFile(), window.getAnnotations(),
                window.getFields(), methods);
    }

    public static void main(String[] args) throws Exception {
        File tmp = Files.createTempDirectory("seamless-scale-fix").toFile();
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
                    if (c.getType().equals(WINDOW)) {
                        target = name;
                        dexFile = d;
                    }
                }
            }
            if (target == null) throw new IllegalStateException(WINDOW + " not in " + args[0]);

            DexPool pool = new DexPool(dexFile.getOpcodes());
            for (ClassDef c : dexFile.getClasses()) {
                pool.internClass(c.getType().equals(WINDOW) ? patchWindow(c) : c);
            }
            for (ClassDef c : added) pool.internClass(c);
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
            System.out.println(args[2] + ": " + WINDOW + ".finishSeamlessRotation calls " + HELPER
                    + ";.restore (" + target + ", " + in.getEntry(target).getSize() + " -> " + dex.length
                    + " bytes)");
        } finally {
            try (Stream<Path> s = Files.walk(tmp.toPath())) {
                s.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }
}
