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
 * Adds microg/ZxMicrogSpoof.java to services.jar and calls ZxMicrogSpoof.apply(p, packageInfo)
 * where ComputerEngine.generatePackageInfo returns the PackageInfo of an installed package, the
 * place LineageOS 20 spoofs microG's signature.
 *
 * The helper is compiled against stubs of the framework classes it uses and dexed by D8 without
 * desugaring (minSdk 33, Java 8 bytecode: no nestmates or invokedynamic string concatenation;
 * the JDK has no ct.sym, so -source/-target and not --release), then merged into the dex that
 * holds ComputerEngine.
 *
 * Usage: java -cp dexlib2-2.5.2.jar:guava-27.1-android.jar:d8.jar MicrogSpoofFix.java
 *            <in services.jar> <ZxMicrogSpoof.java> <out.jar>
 * The output is not zipaligned.
 */
public class MicrogSpoofFix {
    static final String ENGINE = "Lcom/android/server/pm/ComputerEngine;";
    static final String HELPER = "Lcom/android/server/pm/ZxMicrogSpoof";
    static final String PKG = "Lcom/android/server/pm/parsing/pkg/AndroidPackage;";
    static final String INFO = "Landroid/content/pm/PackageInfo;";
    static final Map<String, String> STUBS = new LinkedHashMap<>();
    static {
        STUBS.put("android/content/pm/Signature.java", "package android.content.pm;\n"
                + "public class Signature {\n"
                + "    public Signature(String text) {}\n"
                + "    public static boolean areExactMatch(Signature[] a, Signature[] b) { return false; }\n"
                + "}\n");
        STUBS.put("android/content/pm/SigningDetails.java", "package android.content.pm;\n"
                + "public final class SigningDetails {\n"
                + "    public SigningDetails(Signature[] signatures, int scheme,\n"
                + "            android.util.ArraySet<java.security.PublicKey> keys, Signature[] past) {}\n"
                + "    public Signature[] getSignatures() { return null; }\n"
                + "    public static android.util.ArraySet<java.security.PublicKey> toSigningKeys(\n"
                + "            Signature[] signatures) throws java.security.cert.CertificateException {\n"
                + "        return null;\n"
                + "    }\n"
                + "}\n");
        STUBS.put("android/content/pm/SigningInfo.java", "package android.content.pm;\n"
                + "public final class SigningInfo { public SigningInfo(SigningDetails details) {} }\n");
        STUBS.put("android/content/pm/PackageInfo.java", "package android.content.pm;\n"
                + "public class PackageInfo { public Signature[] signatures; public SigningInfo signingInfo; }\n");
        STUBS.put("android/util/ArraySet.java", "package android.util;\n"
                + "public final class ArraySet<E> {}\n");
        STUBS.put("android/util/Slog.java", "package android.util;\n"
                + "public final class Slog { public static int e(String t, String m, Throwable e) { return 0; } }\n");
        STUBS.put("android/os/Bundle.java", "package android.os;\n"
                + "public final class Bundle { public String getString(String key) { return null; } }\n");
        STUBS.put("com/android/server/pm/parsing/pkg/AndroidPackage.java",
                "package com.android.server.pm.parsing.pkg;\n"
                + "public interface AndroidPackage {\n"
                + "    String getPackageName();\n"
                + "    android.content.pm.SigningDetails getSigningDetails();\n"
                + "    android.os.Bundle getMetaData();\n"
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
        Path helper = src.resolve("com/android/server/pm/ZxMicrogSpoof.java");
        Files.createDirectories(helper.getParent());
        Files.copy(source, helper);
        args.add(helper.toString());
        Files.createDirectories(cls);
        Files.createDirectories(dex);
        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        int rc = javac.run(null, null, null, args.toArray(new String[0]));
        if (rc != 0) throw new IllegalStateException("javac: exit " + rc);

        List<Path> classes = new ArrayList<>();
        try (Stream<Path> s = Files.list(cls.resolve("com/android/server/pm"))) {
            s.filter(p -> p.getFileName().toString().startsWith("ZxMicrogSpoof")).forEach(classes::add);
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

    // generatePackageInfo: the one `return-object` that follows
    //   invoke-virtual {this, p}, resolveExternalPackageName(AndroidPackage)
    //   move-result-object; iput-object ApplicationInfo.packageName; iput-object PackageInfo.packageName
    // gets `invoke-static {p, packageInfo}, ZxMicrogSpoof.apply` in front of it.
    static MutableMethodImplementation hook(MutableMethodImplementation code) {
        List<BuilderInstruction> insns = code.getInstructions();
        List<int[]> found = new ArrayList<>();
        for (int i = 0; i + 4 < insns.size(); i++) {
            BuilderInstruction in = insns.get(i);
            if (in.getOpcode() != Opcode.INVOKE_VIRTUAL) continue;
            MethodReference m = (MethodReference) ((ReferenceInstruction) in).getReference();
            if (!m.getName().equals("resolveExternalPackageName")) continue;
            if (insns.get(i + 1).getOpcode() != Opcode.MOVE_RESULT_OBJECT
                    || insns.get(i + 2).getOpcode() != Opcode.IPUT_OBJECT
                    || insns.get(i + 3).getOpcode() != Opcode.IPUT_OBJECT
                    || insns.get(i + 4).getOpcode() != Opcode.RETURN_OBJECT) {
                continue;
            }
            int p = ((FiveRegisterInstruction) in).getRegisterD();
            int info = ((OneRegisterInstruction) insns.get(i + 4)).getRegisterA();
            found.add(new int[] {i + 4, p, info});
        }
        if (found.size() != 1)
            throw new IllegalStateException(ENGINE + ".generatePackageInfo: " + found.size() + " sites");
        int at = found.get(0)[0], p = found.get(0)[1], info = found.get(0)[2];
        if (!insns.get(at).getLocation().getLabels().isEmpty())
            throw new IllegalStateException(ENGINE + ".generatePackageInfo: branch target at " + at);
        if (p > 15 || info > 15)
            throw new IllegalStateException(ENGINE + ".generatePackageInfo: registers past v15");
        code.addInstruction(at, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 2, p, info, 0, 0, 0,
                new ImmutableMethodReference(HELPER + ";", "apply", List.of(PKG, INFO), "V")));
        return code;
    }

    static ClassDef patchEngine(ClassDef engine) {
        List<Method> methods = new ArrayList<>();
        int patched = 0;
        for (Method m : engine.getMethods()) {
            if (m.getName().equals("generatePackageInfo") && m.getReturnType().equals(INFO)
                    && m.getImplementation() != null) {
                MutableMethodImplementation code = hook(new MutableMethodImplementation(m.getImplementation()));
                m = new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                        m.getReturnType(), m.getAccessFlags(), m.getAnnotations(),
                        m.getHiddenApiRestrictions(), code);
                patched++;
            }
            methods.add(m);
        }
        if (patched != 1) throw new IllegalStateException(ENGINE + ": " + patched + " generatePackageInfo");
        return new ImmutableClassDef(engine.getType(), engine.getAccessFlags(), engine.getSuperclass(),
                engine.getInterfaces(), engine.getSourceFile(), engine.getAnnotations(),
                engine.getFields(), methods);
    }

    public static void main(String[] args) throws Exception {
        File tmp = Files.createTempDirectory("microg-spoof-fix").toFile();
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
                    if (c.getType().equals(ENGINE)) {
                        target = name;
                        dexFile = d;
                    }
                }
            }
            if (target == null) throw new IllegalStateException(ENGINE + " not in " + args[0]);

            DexPool pool = new DexPool(dexFile.getOpcodes());
            for (ClassDef c : dexFile.getClasses()) {
                pool.internClass(c.getType().equals(ENGINE) ? patchEngine(c) : c);
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
            System.out.println(args[2] + ": " + ENGINE + ".generatePackageInfo calls " + HELPER + ";.apply ("
                    + target + ", " + in.getEntry(target).getSize() + " -> " + dex.length + " bytes)");
        } finally {
            try (Stream<Path> s = Files.walk(tmp.toPath())) {
                s.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }
}
