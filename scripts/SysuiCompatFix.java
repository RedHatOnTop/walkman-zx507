import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;
import org.jf.dexlib2.AccessFlags;
import org.jf.dexlib2.DexFileFactory;
import org.jf.dexlib2.Opcode;
import org.jf.dexlib2.Opcodes;
import org.jf.dexlib2.builder.BuilderInstruction;
import org.jf.dexlib2.builder.Label;
import org.jf.dexlib2.builder.MutableMethodImplementation;
import org.jf.dexlib2.builder.instruction.BuilderInstruction10x;
import org.jf.dexlib2.builder.instruction.BuilderInstruction11n;
import org.jf.dexlib2.builder.instruction.BuilderInstruction11x;
import org.jf.dexlib2.builder.instruction.BuilderInstruction21c;
import org.jf.dexlib2.builder.instruction.BuilderInstruction21t;
import org.jf.dexlib2.builder.instruction.BuilderInstruction22c;
import org.jf.dexlib2.builder.instruction.BuilderInstruction22t;
import org.jf.dexlib2.builder.instruction.BuilderInstruction35c;
import org.jf.dexlib2.builder.instruction.BuilderInstruction3rc;
import org.jf.dexlib2.dexbacked.DexBackedDexFile;
import org.jf.dexlib2.iface.ClassDef;
import org.jf.dexlib2.iface.Method;
import org.jf.dexlib2.iface.MethodImplementation;
import org.jf.dexlib2.iface.reference.FieldReference;
import org.jf.dexlib2.iface.reference.MethodReference;
import org.jf.dexlib2.immutable.ImmutableClassDef;
import org.jf.dexlib2.immutable.ImmutableField;
import org.jf.dexlib2.immutable.ImmutableMethod;
import org.jf.dexlib2.immutable.ImmutableMethodImplementation;
import org.jf.dexlib2.immutable.ImmutableMethodParameter;
import org.jf.dexlib2.immutable.reference.ImmutableFieldReference;
import org.jf.dexlib2.immutable.reference.ImmutableMethodReference;
import org.jf.dexlib2.immutable.reference.ImmutableStringReference;
import org.jf.dexlib2.immutable.reference.ImmutableTypeReference;
import org.jf.dexlib2.writer.io.FileDataStore;
import org.jf.dexlib2.writer.pool.DexPool;

/**
 * Lets SystemUI run downscaled (am compat enable DOWNSCALED + DOWNSCALE_75) without some of its
 * views drawing at 0.75 of their size: adds com.android.systemui.CompatConfigFix and registers
 * it first thing in SystemUIApplication.onCreate.
 *
 * Android 13's ViewRootImpl.performConfigurationChange applies the app's CompatibilityInfo to the
 * global configuration a window reports (densityDpi 360 -> 270) and hands it to ActivityThread's
 * config callback, which passes it to ResourcesManager.applyConfigurationToResources; every
 * ResourcesImpl then applies the CompatibilityInfo once more (270 -> 202). Which views get the
 * doubly scaled resources depends on the order window and process configuration changes arrive
 * in. CompatConfigFix runs after ActivityThread's callback and before the views hear of the
 * change, and applies the configuration again with the scaling undone. The scaled configuration
 * still goes to SystemUI's own configuration listeners, as before: they lay out against it
 * (given the unscaled one, the QS footer moved down under the navigation bar).
 *
 * Usage: java -cp dexlib2-2.5.2.jar:guava-27.1-android.jar SysuiCompatFix.java <in.apk> <out.apk>
 * The output is unsigned.
 */
public class SysuiCompatFix {
    static final String DEX = "classes.dex";
    static final String DEX2 = "classes2.dex";
    static final String APP = "Lcom/android/systemui/SystemUIApplication;";
    static final String FIX = "Lcom/android/systemui/CompatConfigFix;";
    static final String CALLBACK = "Landroid/view/ViewRootImpl$ConfigChangedCallback;";
    static final String RES = "Landroid/content/res/Resources;";
    static final String CONFIG = "Landroid/content/res/Configuration;";
    static final String COMPAT = "Landroid/content/res/CompatibilityInfo;";
    static final String METRICS = "Landroid/util/DisplayMetrics;";
    static final String WINCONFIG = "Landroid/app/WindowConfiguration;";
    static final String CONTEXT = "Landroid/content/Context;";
    static final String RESMGR = "Landroid/app/ResourcesManager;";

    static MethodReference method(String cls, String name, String ret, String... params) {
        return new ImmutableMethodReference(cls, name, List.of(params), ret);
    }

    static FieldReference field(String cls, String name, String type) {
        return new ImmutableFieldReference(cls, name, type);
    }

    static ImmutableMethod method(String name, int flags, String ret, List<String> params,
            MutableMethodImplementation code) {
        List<ImmutableMethodParameter> p = new ArrayList<>();
        for (String t : params) p.add(new ImmutableMethodParameter(t, null, null));
        return new ImmutableMethod(FIX, name, p, ret, flags, null, null, code);
    }

    static MutableMethodImplementation code(int registers, BuilderInstruction... insns) {
        MutableMethodImplementation m = new MutableMethodImplementation(registers);
        for (BuilderInstruction i : insns) m.addInstruction(i);
        return m;
    }

    static ClassDef fixClass() {
        FieldReference res = field(FIX, "res", RES);

        // <init>(Resources): v0 = this, v1 = res
        MutableMethodImplementation init = code(2,
                new BuilderInstruction35c(Opcode.INVOKE_DIRECT, 1, 0, 0, 0, 0, 0,
                        method("Ljava/lang/Object;", "<init>", "V")),
                new BuilderInstruction22c(Opcode.IPUT_OBJECT, 1, 0, res),
                new BuilderInstruction10x(Opcode.RETURN_VOID));

        // install(Context): v3 = context. Puts the callback first in ViewRootImpl.sConfigCallbacks,
        // which runs last; if the list cannot be reached, SystemUI runs without it.
        MutableMethodImplementation install = code(4,
                new BuilderInstruction21c(Opcode.NEW_INSTANCE, 0, new ImmutableTypeReference(FIX)),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 3, 0, 0, 0, 0,
                        method(CONTEXT, "getResources", RES)),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1),
                new BuilderInstruction35c(Opcode.INVOKE_DIRECT, 2, 0, 1, 0, 0, 0,
                        method(FIX, "<init>", "V", RES)),
                new BuilderInstruction21c(Opcode.CONST_CLASS, 1,
                        new ImmutableTypeReference("Landroid/view/ViewRootImpl;")),
                new BuilderInstruction21c(Opcode.CONST_STRING, 2,
                        new ImmutableStringReference("sConfigCallbacks")),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 1, 2, 0, 0, 0,
                        method("Ljava/lang/Class;", "getDeclaredField", "Ljava/lang/reflect/Field;",
                                "Ljava/lang/String;")),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1),
                new BuilderInstruction11n(Opcode.CONST_4, 2, 1),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 1, 2, 0, 0, 0,
                        method("Ljava/lang/reflect/Field;", "setAccessible", "V", "Z")),
                new BuilderInstruction11n(Opcode.CONST_4, 2, 0),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 1, 2, 0, 0, 0,
                        method("Ljava/lang/reflect/Field;", "get", "Ljava/lang/Object;",
                                "Ljava/lang/Object;")),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1),
                new BuilderInstruction21c(Opcode.CHECK_CAST, 1,
                        new ImmutableTypeReference("Ljava/util/ArrayList;")),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 3, 1, 2, 0, 0, 0,
                        method("Ljava/util/ArrayList;", "add", "V", "I", "Ljava/lang/Object;")),
                new BuilderInstruction10x(Opcode.RETURN_VOID),
                new BuilderInstruction11x(Opcode.MOVE_EXCEPTION, 0),
                new BuilderInstruction10x(Opcode.RETURN_VOID));
        install.addCatch(install.newLabelForIndex(4), install.newLabelForIndex(15),
                install.newLabelForIndex(16));

        // onConfigurationChanged(Configuration): v4 = this, v5 = config. Runs after
        // ActivityThread's callback; if that left the process configuration at the scaled
        // density, applies a copy of config with the scaling undone. Its seq is 0, since the
        // configuration it replaces has config's. The nops become branches to the return-void.
        MutableMethodImplementation changed = code(6,
                new BuilderInstruction22c(Opcode.IGET_OBJECT, 0, 4, res),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0,
                        method(RES, "getCompatibilityInfo", COMPAT)),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 1, 0, 0, 0, 0,
                        method(COMPAT, "isScalingRequired", "Z")),
                new BuilderInstruction11x(Opcode.MOVE_RESULT, 2),
                new BuilderInstruction10x(Opcode.NOP),
                new BuilderInstruction21c(Opcode.NEW_INSTANCE, 2, new ImmutableTypeReference(CONFIG)),
                new BuilderInstruction35c(Opcode.INVOKE_DIRECT, 2, 2, 5, 0, 0, 0,
                        method(CONFIG, "<init>", "V", CONFIG)),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0,
                        method(RES, "getDisplayMetrics", METRICS)),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0),
                new BuilderInstruction22c(Opcode.IGET, 0, 0,
                        field(METRICS, "noncompatDensityDpi", "I")),
                new BuilderInstruction22c(Opcode.IPUT, 0, 2, field(CONFIG, "densityDpi", "I")),
                new BuilderInstruction22c(Opcode.IGET_OBJECT, 0, 2,
                        field(CONFIG, "windowConfiguration", WINCONFIG)),
                new BuilderInstruction22c(Opcode.IGET, 1, 1, field(COMPAT, "applicationScale", "F")),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 0, 1, 0, 0, 0,
                        method(WINCONFIG, "scale", "V", "F")),
                new BuilderInstruction35c(Opcode.INVOKE_STATIC, 0, 0, 0, 0, 0, 0,
                        method(RESMGR, "getInstance", RESMGR)),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0,
                        method(RESMGR, "getConfiguration", CONFIG)),
                new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1),
                new BuilderInstruction22c(Opcode.IGET, 1, 1, field(CONFIG, "densityDpi", "I")),
                new BuilderInstruction22c(Opcode.IGET, 3, 2, field(CONFIG, "densityDpi", "I")),
                new BuilderInstruction10x(Opcode.NOP),
                new BuilderInstruction11n(Opcode.CONST_4, 1, 0),
                new BuilderInstruction22c(Opcode.IPUT, 1, 2, field(CONFIG, "seq", "I")),
                new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 3, 0, 2, 1, 0, 0,
                        method(RESMGR, "applyConfigurationToResources", "Z", CONFIG, COMPAT)),
                new BuilderInstruction10x(Opcode.RETURN_VOID));
        Label done = changed.newLabelForIndex(changed.getInstructions().size() - 1);
        changed.replaceInstruction(5, new BuilderInstruction21t(Opcode.IF_EQZ, 2, done));
        changed.replaceInstruction(21, new BuilderInstruction22t(Opcode.IF_EQ, 1, 3, done));

        return new ImmutableClassDef(FIX, AccessFlags.PUBLIC.getValue() | AccessFlags.FINAL.getValue(),
                "Ljava/lang/Object;", List.of(CALLBACK), null, null,
                List.of(new ImmutableField(FIX, "res", RES,
                        AccessFlags.PRIVATE.getValue() | AccessFlags.FINAL.getValue(), null, null, null)),
                List.of(
                        method("<init>", AccessFlags.PUBLIC.getValue() | AccessFlags.CONSTRUCTOR.getValue(),
                                "V", List.of(RES), init),
                        method("install", AccessFlags.PUBLIC.getValue() | AccessFlags.STATIC.getValue(),
                                "V", List.of(CONTEXT), install),
                        method("onConfigurationChanged", AccessFlags.PUBLIC.getValue(), "V",
                                List.of(CONFIG), changed)));
    }

    // R8 gave the methods a few shared, pc-based debug_info items (1373 for 41627 methods in
    // classes.dex); dexlib2 writes one copy per method, ten times the size of the code. Their
    // line numbers are dex pcs, which ART prints for methods without debug info anyway.
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

    static ClassDef patchApp(ClassDef app) {
        List<Method> methods = new ArrayList<>();
        int patched = 0;
        for (Method m : app.getMethods()) {
            if (m.getName().equals("onCreate") && m.getParameterTypes().isEmpty()
                    && m.getReturnType().equals("V")) {
                MutableMethodImplementation code = new MutableMethodImplementation(m.getImplementation());
                int self = code.getRegisterCount() - 1;
                code.addInstruction(0, new BuilderInstruction3rc(Opcode.INVOKE_STATIC_RANGE, self, 1,
                        method(FIX, "install", "V", CONTEXT)));
                m = new ImmutableMethod(m.getDefiningClass(), m.getName(), m.getParameters(),
                        m.getReturnType(), m.getAccessFlags(), m.getAnnotations(),
                        m.getHiddenApiRestrictions(), code);
                patched++;
            }
            methods.add(m);
        }
        if (patched != 1) throw new IllegalStateException(APP + ": " + patched + " onCreate()V");
        return new ImmutableClassDef(app.getType(), app.getAccessFlags(), app.getSuperclass(),
                app.getInterfaces(), app.getSourceFile(), app.getAnnotations(), app.getFields(), methods);
    }

    static DexBackedDexFile load(ZipFile apk, String name, File tmp) throws Exception {
        File f = new File(tmp, name);
        Files.write(f.toPath(), apk.getInputStream(apk.getEntry(name)).readAllBytes());
        return DexFileFactory.loadDexFile(f, Opcodes.forApi(33));
    }

    static byte[] write(DexPool pool, File tmp, String name) throws Exception {
        File f = new File(tmp, name + ".out");
        pool.writeTo(new FileDataStore(f));
        return Files.readAllBytes(f.toPath());
    }

    public static void main(String[] args) throws Exception {
        File tmp = Files.createTempDirectory("sysui-compat-fix").toFile();
        try (ZipFile in = new ZipFile(args[0])) {
            // classes.dex has 65535 method ids, so SystemUIApplication moves to classes2.dex,
            // where install() and the new class fit.
            DexBackedDexFile primary = load(in, DEX, tmp);
            DexBackedDexFile secondary = load(in, DEX2, tmp);
            DexPool pool = new DexPool(primary.getOpcodes());
            DexPool pool2 = new DexPool(secondary.getOpcodes());
            ClassDef app = null;
            for (ClassDef c : primary.getClasses()) {
                if (c.getType().equals(APP)) app = strip(c);
                else pool.internClass(strip(c));
            }
            if (app == null) throw new IllegalStateException(APP + " not in " + DEX);
            for (ClassDef c : secondary.getClasses()) {
                if (c.getType().equals(FIX) || c.getType().equals(APP))
                    throw new IllegalStateException(c.getType() + " already in " + DEX2);
                pool2.internClass(strip(c));
            }
            pool2.internClass(patchApp(app));
            pool2.internClass(fixClass());
            byte[] dex = write(pool, tmp, DEX);
            byte[] dex2 = write(pool2, tmp, DEX2);

            try (ZipOutputStream zout = new ZipOutputStream(new FileOutputStream(args[1]))) {
                for (Enumeration<? extends ZipEntry> e = in.entries(); e.hasMoreElements(); ) {
                    ZipEntry ie = e.nextElement();
                    byte[] data = ie.getName().equals(DEX) ? dex
                            : ie.getName().equals(DEX2) ? dex2
                            : in.getInputStream(ie).readAllBytes();
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
        } finally {
            for (File f : tmp.listFiles()) f.delete();
            tmp.delete();
        }
        System.out.println(args[1] + ": " + FIX + " registered in " + APP + ".onCreate");
    }
}
