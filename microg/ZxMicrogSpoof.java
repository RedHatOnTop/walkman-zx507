package com.android.server.pm;

import android.content.pm.PackageInfo;
import android.content.pm.Signature;
import android.content.pm.SigningDetails;
import android.content.pm.SigningInfo;
import android.os.Bundle;
import android.util.Slog;
import com.android.server.pm.parsing.pkg.AndroidPackage;

/**
 * Signature spoofing for microG, as LineageOS 20 has it (frameworks/base 6d2955f0bd and
 * 53e2f4b85c). microG/MicrogSpoofFix.java adds this class to services.jar and calls apply() as
 * ComputerEngine.generatePackageInfo returns. com.google.android.gms and com.android.vending
 * signed with microG's release key, whose fake-signature meta-data is Google's certificate, are
 * then reported as signed with that certificate; nothing else is. Lineage also requires a
 * debuggable build; this GSI is userdebug, and the key check is what keeps other apps out.
 */
final class ZxMicrogSpoof {
    // O=NOGAPPS Project, C=DE; SHA-256
    // 9bd06727e62796c0130eb6dab39b73157451582cbd138e86c468acc395d14165
    private static final String MICROG =
            "308202ed308201d5a003020102020426ffa009300d06092a864886f70d01010b05003027310b30090603"
            + "5504061302444531183016060355040a130f4e4f47415050532050726f6a656374301e170d3132313030"
            + "363132303533325a170d3337303933303132303533325a3027310b300906035504061302444531183016"
            + "060355040a130f4e4f47415050532050726f6a65637430820122300d06092a864886f70d010101050003"
            + "82010f003082010a02820101009a8d2a5336b0eaaad89ce447828c7753b157459b79e3215dc962ca48f5"
            + "8c2cd7650df67d2dd7bda0880c682791f32b35c504e43e77b43c3e4e541f86e35a8293a54fb46e6b16af"
            + "54d3a4eda458f1a7c8bc1b7479861ca7043337180e40079d9cdccb7e051ada9b6c88c9ec635541e2ebf0"
            + "842521c3024c826f6fd6db6fd117c74e859d5af4db04448965ab5469b71ce719939a06ef30580f50febf"
            + "96c474a7d265bb63f86a822ff7b643de6b76e966a18553c2858416cf3309dd24278374bdd82b4404ef6f"
            + "7f122cec93859351fc6e5ea947e3ceb9d67374fe970e593e5cd05c905e1d24f5a5484f4aadef766e498a"
            + "df64f7cf04bddd602ae8137b6eea40722d0203010001a321301f301d0603551d0e04160414110b7aa9eb"
            + "c840b20399f69a431f4dba6ac42a64300d06092a864886f70d01010b0500038201010007c32ad893349c"
            + "f86952fb5a49cfdc9b13f5e3c800aece77b2e7e0e9c83e34052f140f357ec7e6f4b432dc1ed542218a14"
            + "835acd2df2deea7efd3fd5e8f1c34e1fb39ec6a427c6e6f4178b609b369040ac1f8844b789f3694dc640"
            + "de06e44b247afed11637173f36f5886170fafd74954049858c6096308fc93c1bc4dd5685fa7a1f982a42"
            + "2f2a3b36baa8c9500474cf2af91c39cbec1bc898d10194d368aa5e91f1137ec115087c31962d8f76cd12"
            + "0d28c249cf76f4c70f5baa08c70a7234ce4123be080cee789477401965cfe537b924ef36747e8caca62d"
            + "fefdd1a6288dcb1c4fd2aaa6131a7ad254e9742022cfd597d2ca5c660ce9e41ff537e5a4041e37";
    // CN=Android, O=Google Inc.; SHA-256
    // f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83
    private static final String GOOGLE =
            "308204433082032ba003020102020900c2e08746644a308d300d06092a864886f70d0101040500307431"
            + "0b3009060355040613025553311330110603550408130a43616c69666f726e6961311630140603550407"
            + "130d4d6f756e7461696e205669657731143012060355040a130b476f6f676c6520496e632e3110300e06"
            + "0355040b1307416e64726f69643110300e06035504031307416e64726f6964301e170d30383038323132"
            + "33313333345a170d3336303130373233313333345a3074310b3009060355040613025553311330110603"
            + "550408130a43616c69666f726e6961311630140603550407130d4d6f756e7461696e2056696577311430"
            + "12060355040a130b476f6f676c6520496e632e3110300e060355040b1307416e64726f69643110300e06"
            + "035504031307416e64726f696430820120300d06092a864886f70d01010105000382010d003082010802"
            + "82010100ab562e00d83ba208ae0a966f124e29da11f2ab56d08f58e2cca91303e9b754d372f640a71b1d"
            + "cb130967624e4656a7776a92193db2e5bfb724a91e77188b0e6a47a43b33d9609b77183145ccdf7b2e58"
            + "6674c9e1565b1f4c6a5955bff251a63dabf9c55c27222252e875e4f8154a645f897168c0b1bfc612eabf"
            + "785769bb34aa7984dc7e2ea2764cae8307d8c17154d7ee5f64a51a44a602c249054157dc02cd5f5c0e55"
            + "fbef8519fbe327f0b1511692c5a06f19d18385f5c4dbc2d6b93f68cc2979c70e18ab93866b3bd5db8999"
            + "552a0e3b4c99df58fb918bedc182ba35e003c1b4b10dd244a8ee24fffd333872ab5221985edab0fc0d0b"
            + "145b6aa192858e79020103a381d93081d6301d0603551d0e04160414c77d8cc2211756259a7fd382df6b"
            + "e398e4d786a53081a60603551d2304819e30819b8014c77d8cc2211756259a7fd382df6be398e4d786a5"
            + "a178a4763074310b3009060355040613025553311330110603550408130a43616c69666f726e69613116"
            + "30140603550407130d4d6f756e7461696e205669657731143012060355040a130b476f6f676c6520496e"
            + "632e3110300e060355040b1307416e64726f69643110300e06035504031307416e64726f6964820900c2"
            + "e08746644a308d300c0603551d13040530030101ff300d06092a864886f70d010104050003820101006d"
            + "d252ceef85302c360aaace939bcff2cca904bb5d7a1661f8ae46b2994204d0ff4a68c7ed1a531ec4595a"
            + "623ce60763b167297a7ae35712c407f208f0cb109429124d7b106219c084ca3eb3f9ad5fb871ef92269a"
            + "8be28bf16d44c8d9a08e6cb2f005bb3fe2cb96447e868e731076ad45b33f6009ea19c161e62641aa9927"
            + "1dfd5228c5c587875ddb7f452758d661f6cc0cccb7352e424cc4365c523532f7325137593c4ae341f4db"
            + "41edda0d0b1071a7c440f0fe9ea01cb627ca674369d084bd2fd911ff06cdbf2cfa10dc0f893ae3576291"
            + "9048c7efc64c7144178342f70581c9de573af55b390dd7fdb9418631895d5f759f30112687ff621410c0"
            + "69308a";
    // SigningDetails.SignatureSchemeVersion.SIGNING_BLOCK_V3
    private static final int SIGNING_BLOCK_V3 = 3;

    private ZxMicrogSpoof() {
    }

    static void apply(AndroidPackage p, PackageInfo pi) {
        String name = p.getPackageName();
        if (!"com.google.android.gms".equals(name) && !"com.android.vending".equals(name)) return;
        try {
            Signature[] signatures = p.getSigningDetails().getSignatures();
            Signature[] microg = {new Signature(MICROG)};
            if (signatures == null || !Signature.areExactMatch(signatures, microg)) return;
            Bundle metaData = p.getMetaData();
            String fake = metaData == null ? null : metaData.getString("fake-signature");
            Signature google = new Signature(GOOGLE);
            if (fake == null || !google.equals(new Signature(fake))) return;
            pi.signatures = new Signature[] {google};
            pi.signingInfo = new SigningInfo(new SigningDetails(pi.signatures, SIGNING_BLOCK_V3,
                    SigningDetails.toSigningKeys(pi.signatures), null));
        } catch (Exception e) {
            Slog.e("ZxMicrogSpoof", "no fake signature for " + name, e);
        }
    }
}
