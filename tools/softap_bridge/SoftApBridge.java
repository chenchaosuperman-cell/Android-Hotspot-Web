/*
 * SoftApBridge — Android-Hotspot-Web 系统热点配置 Binder Bridge（v3，v1.7.7）
 *
 * 职责（配置/开关/能力分离）：
 *   get-config            读取系统持久 SoftApConfiguration（IWifiManager.getSoftApConfiguration）
 *   set-config            写入系统持久 SoftApConfiguration（IWifiManager.setSoftApConfiguration，
 *                         标准 AOSP 签名为 (SoftApConfiguration, String packageName)；
 *                         运行时枚举方法签名，兼容 (SoftApConfiguration) 等 OEM 变体）
 *   tether-state          读取 Wi-Fi tethering 状态（IConnectivityManager / TetheringManager 体系）
 *   tether-start/stop     走系统 Tethering 体系，分代 Backend：
 *                         Modern = ITetheringConnector（TetheringManager 底层，"tethering" 系统服务）
 *                         Legacy = IConnectivityManager.startTethering/stopTethering
 *   softap-capability     通过 WifiManager.SoftApCallback.onCapabilityChanged(SoftApCapability)
 *                         取得一次真实能力（信道列表/最大客户端），不反射猜 getSoftApCapabilities()
 *   probe                 运行时能力探测（方法签名、Builder 方法、安全/频段常量、Tethering 分代）
 *
 * AOSP 常量（运行时优先反射 Framework 字段，反射不到才用内置值）：
 *   SECURITY_TYPE: OPEN=0 WPA2_PSK=1 WPA3_SAE_TRANSITION=2 WPA3_SAE=3
 *                  WPA3_OWE_TRANSITION=4 WPA3_OWE=5
 *   BAND: 2GHZ=1 5GHZ=2 6GHZ=4 ANY=7（=1|2|4，禁止 0，setBand(0) 会抛 IllegalArgumentException）
 */
package com.mifi.softap;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public class SoftApBridge {

    // AOSP 内置默认值（反射 Framework 字段优先，见 readIntConstants）
    static final int SEC_OPEN = 0;
    static final int SEC_WPA2 = 1;
    static final int SEC_WPA3_TRANSITION = 2;
    static final int SEC_WPA3 = 3;
    static final int SEC_OWE_TRANSITION = 4;
    static final int SEC_OWE = 5;

    static final int BAND_2GHZ = 1;
    static final int BAND_5GHZ = 2;
    static final int BAND_6GHZ = 4;
    static final int BAND_ANY = 7; // 1|2|4；禁止 0

    public static void main(String[] args) {
        try {
            int api = android.os.Build.VERSION.SDK_INT;
            if (api < 30) {
                System.out.println("present=0");
                System.err.println("ERROR_UNSUPPORTED: SoftApConfiguration requires API 30+, current=" + api);
                System.exit(3);
            }
            String cmd = args.length > 0 ? args[0] : "get-config";
            switch (cmd) {
                case "get-config":
                    doGet();
                    break;
                case "set-config":
                    if (args.length < 8) {
                        System.err.println("ERROR_USAGE: set-config needs 8 args");
                        System.exit(2);
                    }
                    doSet(args);
                    break;
                case "tether-state":
                    doTetherState();
                    break;
                case "tether-start":
                    doTetherStart(parseInt(args.length > 1 ? args[1] : "0", 0));
                    break;
                case "tether-stop":
                    doTetherStop(parseInt(args.length > 1 ? args[1] : "0", 0));
                    break;
                case "softap-capability":
                    doSoftApCapability();
                    break;
                case "softap-state":
                    doSoftApState();
                    break;
                case "probe":
                    doProbe();
                    break;
                case "get-api":
                    System.out.println("api=" + api);
                    break;
                default:
                    System.err.println("ERROR_USAGE: usage get-config|set-config|tether-state|tether-start|tether-stop|softap-capability|softap-state|probe|get-api");
                    System.exit(2);
            }
        } catch (Throwable t) {
            System.err.println("ERROR: " + t);
            System.exit(1);
        }
    }

    /* ---------------- Binder 入口 ---------------- */

    static Object binderService(String name, String stubClsName) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Method get = sm.getMethod("getService", String.class);
        android.os.IBinder b = (android.os.IBinder) get.invoke(null, name);
        if (b == null) {
            throw new IllegalStateException(name + " service unavailable");
        }
        Class<?> stub = Class.forName(stubClsName);
        Method asIface = stub.getMethod("asInterface", android.os.IBinder.class);
        return asIface.invoke(null, b);
    }

    static Object wifiService() throws Exception {
        return binderService("wifi", "android.net.wifi.IWifiManager$Stub");
    }

    static Object connectivityService() throws Exception {
        return binderService("connectivity", "android.net.IConnectivityManager$Stub");
    }

    static Object tetheringConnector() throws Exception {
        return binderService("tethering", "android.net.ITetheringConnector$Stub");
    }

    /* ---------------- get-config ---------------- */

    static Object getConfig() throws Exception {
        Object svc = wifiService();
        Method m = svc.getClass().getMethod("getSoftApConfiguration");
        return m.invoke(svc);
    }

    static void doGet() throws Exception {
        Object cfg = getConfig();
        if (cfg == null) {
            System.out.println("present=0");
            return;
        }
        Class<?> c = cfg.getClass();
        String ssid = (String) c.getMethod("getSsid").invoke(cfg);
        Object pass = c.getMethod("getPassphrase").invoke(cfg);
        int sec = (Integer) c.getMethod("getSecurityType").invoke(cfg);
        int band = 0, channel = 0, max = 0;
        try { band = (Integer) c.getMethod("getBand").invoke(cfg); } catch (NoSuchMethodException e) {}
        try { channel = (Integer) c.getMethod("getChannel").invoke(cfg); } catch (NoSuchMethodException e) {}
        try { max = (Integer) c.getMethod("getMaxNumberOfClients").invoke(cfg); } catch (NoSuchMethodException e) {}
        boolean hidden = (Boolean) c.getMethod("isHiddenSsid").invoke(cfg);

        StringBuilder sb = new StringBuilder();
        sb.append("present=1\n");
        sb.append("ssid_b64=").append(b64(ssid == null ? "" : ssid)).append("\n");
        sb.append("security=").append(secName(sec)).append("\n");
        sb.append("password_b64=").append(b64(pass == null ? "" : (String) pass)).append("\n");
        sb.append("band=").append(bandName(band)).append("\n");
        sb.append("channel=").append(channel).append("\n");
        sb.append("hidden=").append(hidden ? 1 : 0).append("\n");
        sb.append("maxclients=").append(max < 0 ? 0 : max).append("\n");
        System.out.print(sb);
    }

    /* ---------------- set-config ---------------- */

    /** 调用目标：set ssid sec pass band channel hidden maxclients */
    static void doSet(String[] args) throws Exception {
        String ssid = args[1];
        String security = args[2];
        String password = args[3];
        String band = args[4];
        int channel = parseInt(args[5], 0);
        boolean hidden = args[6].equals("1");
        int max = parseInt(args[7], 0);

        int sec = secFromName(security);
        int b = bandFromName(band);

        Class<?> cfgCls = Class.forName("android.net.wifi.SoftApConfiguration");
        Class<?> bCls = Class.forName("android.net.wifi.SoftApConfiguration$Builder");

        // 复制当前配置（保留 OEM 特有字段），无则新建
        Object cur = getConfig();
        Object builder;
        if (cur != null) {
            builder = bCls.getConstructor(cfgCls).newInstance(cur);
        } else {
            builder = bCls.newInstance();
        }

        // setSsid(String)
        bCls.getMethod("setSsid", String.class).invoke(builder, ssid);

        // 密码 + 加密方式：标准 AOSP 为 setPassphrase(String,int)
        // OPEN 必须显式 setPassphrase(null, OPEN)：Builder 从旧配置复制后，
        // "不设置密码"会保留旧 security/passphrase（WPA2→Open 会失败）
        if (sec == SEC_OPEN) {
            try {
                bCls.getMethod("setPassphrase", String.class, int.class).invoke(builder, (String) null, Integer.valueOf(SEC_OPEN));
            } catch (NoSuchMethodException e) {
                try {
                    bCls.getMethod("setSecurityType", int.class).invoke(builder, Integer.valueOf(SEC_OPEN));
                } catch (NoSuchMethodException e2) {
                    throw new IllegalStateException("cannot set OPEN security on this Builder");
                }
            }
        } else {
            try {
                bCls.getMethod("setPassphrase", String.class, int.class).invoke(builder, password, sec);
            } catch (NoSuchMethodException e) {
                bCls.getMethod("setPassphrase", String.class).invoke(builder, password);
                try {
                    bCls.getMethod("setSecurityType", int.class).invoke(builder, sec);
                } catch (NoSuchMethodException e2) {
                    throw new IllegalStateException("no setPassphrase(String,int) nor setSecurityType(int) on Builder");
                }
            }
        }

        // 频段 / 信道：标准 AOSP 为 setChannel(int,int)，单独 setBand(int)
        if (channel > 0) {
            try {
                bCls.getMethod("setChannel", int.class, int.class).invoke(builder, channel, b);
            } catch (NoSuchMethodException e) {
                try {
                    bCls.getMethod("setChannel", int.class).invoke(builder, channel);
                } catch (NoSuchMethodException e2) {
                    throw new IllegalStateException("no setChannel(int,int) nor setChannel(int) on Builder");
                }
            }
        } else {
            try {
                bCls.getMethod("setBand", int.class).invoke(builder, b);
            } catch (NoSuchMethodException e) {
                // 个别 ROM 无 setBand：跳过（保留系统默认频段）
            }
        }

        try { bCls.getMethod("setHiddenSsid", boolean.class).invoke(builder, hidden); } catch (NoSuchMethodException e) {}
        // max>=0 都调用：0 表示恢复系统默认/不限（Builder 从旧配置复制后必须显式设置）
        try {
            bCls.getMethod("setMaxNumberOfClients", int.class).invoke(builder, Integer.valueOf(max));
        } catch (NoSuchMethodException e) {
            // 无此方法：不设置
        } catch (InvocationTargetException e) {
            // 个别 ROM 拒绝 0：忽略，保留原值
        }
        // v1.9.0：禁用系统 SoftAP idle 自动关闭。
        // HyperOS framework 默认 600000ms（10 分钟）无客户端活动即 DISABLED 热点，
        // keepalive 虽能自动恢复，但客户端每 10 分钟断网一次，体验不可接受。
        // AOSP 语义：0 应表示禁用，但 MIUI/HyperOS 拒绝 0（IllegalArgumentException:
        // "Invalid timeout value: 0"），改用 7 天（604800000ms）等效禁用（模块自身
        // 仍有 30 分钟无客户端自动关闭策略，热点不会永远挂着）。
        try {
            bCls.getMethod("setShutdownTimeoutMillis", long.class).invoke(builder, Long.valueOf(604800000L));
        } catch (NoSuchMethodException e) {
            System.err.println("NOTE: setShutdownTimeoutMillis(long) unavailable; system idle shutdown remains");
        } catch (InvocationTargetException e) {
            System.err.println("NOTE: setShutdownTimeoutMillis rejected by this ROM: " + e.getCause());
        }
        Object cfg = bCls.getMethod("build").invoke(builder);

        Object svc = wifiService();
        // 标准 AOSP：setSoftApConfiguration(SoftApConfiguration, String packageName)
        Method m = null;
        try {
            m = svc.getClass().getMethod("setSoftApConfiguration", cfgCls, String.class);
        } catch (NoSuchMethodException e) {
            try {
                m = svc.getClass().getMethod("setSoftApConfiguration", cfgCls);
            } catch (NoSuchMethodException e2) {
                // 枚举所有同名方法兜底（OEM 变体签名）
                for (Method cand : svc.getClass().getMethods()) {
                    if (cand.getName().equals("setSoftApConfiguration")
                            && cand.getParameterTypes().length >= 1
                            && cand.getParameterTypes()[0].isAssignableFrom(cfgCls)) {
                        m = cand;
                        break;
                    }
                }
                if (m == null) {
                    throw new IllegalStateException("no setSoftApConfiguration method on IWifiManager");
                }
            }
        }
        Object result;
        if (m.getParameterTypes().length == 2) {
            result = m.invoke(svc, cfg, "com.android.shell");
        } else {
            result = m.invoke(svc, cfg);
        }
        Boolean ok = (Boolean) result;
        if (!Boolean.TRUE.equals(ok)) {
            System.err.println("ERROR: setSoftApConfiguration returned false");
            System.exit(1);
        }
        System.out.println("ok=1");
    }

    /* ---------------- tether-start / tether-stop（系统 Tethering 体系，分代 Backend） ---------------- */

    /** 通用静默回调 Binder：onTransact 直接 writeNoException 并返回 true */
    static android.os.IBinder silentBinder() {
        return new android.os.Binder() {
            @Override
            protected boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) {
                if (reply != null) reply.writeNoException();
                return true;
            }
        };
    }

    /** v1.7.9 Modern Backend：ITetheringConnector 严格按 AIDL 签名（Android 12+）。
     *  startTethering(TetheringRequestParcel, String callerPkg, String attributionTag, IIntResultListener)
     *  stopTethering(int type, String callerPkg, String attributionTag, IIntResultListener)
     *  回调使用继承 IIntResultListener.Stub 的真实 Binder（跨进程可收到 onResult）。 */
    static class IntResultCb extends android.net.IIntResultListener.Stub {
        final AtomicReference<Integer> result;
        final CountDownLatch latch;
        IntResultCb(AtomicReference<Integer> r, CountDownLatch l) { result = r; latch = l; }
        public void onResult(int res) throws android.os.RemoteException {
            result.set(Integer.valueOf(res));
            latch.countDown();
        }
    }

    // v1.7.9：反射构造 TetheringRequestParcel。字段名随 ROM/版本演变，实测双名兼容：
    //   新（Android 16 / HyperOS）：tetheringType / requestType / exemptFromEntitlementCheck
    //   旧（Android 12-15）：type / shouldShowProvisioningUi / isExemptFromEntitlementCheck
    // 旧实现只认 type/isExemptFromEntitlementCheck，在本 ROM 上全部 set 失败（字段不存在），
    // 请求类型默认 0 且未豁免 entitlement → Tethering 拒绝（result=18），模块 fallback 到
    // cmd wifi start-softap：SoftAP 起来但系统 Tethering（DHCP/NAT）不建立，设备无网。
    static void _setIntField(Object o, String[] names, int v) throws Exception {
        for (String n : names) {
            try {
                java.lang.reflect.Field fd = o.getClass().getDeclaredField(n);
                fd.setAccessible(true);
                Class<?> ft = fd.getType();
                if (ft == int.class) { fd.setInt(o, v); return; }
                if (ft == long.class) { fd.setLong(o, v); return; }
                return;
            } catch (NoSuchFieldException e) { /* 试下一个候选名 */ }
        }
    }
    static void _setBoolField(Object o, String[] names, boolean v) throws Exception {
        for (String n : names) {
            try {
                java.lang.reflect.Field fd = o.getClass().getDeclaredField(n);
                fd.setAccessible(true);
                if (fd.getType() == boolean.class) { fd.setBoolean(o, v); return; }
                return;
            } catch (NoSuchFieldException e) { /* 试下一个候选名 */ }
        }
    }
    static void _setStringField(Object o, String[] names, String v) throws Exception {
        for (String n : names) {
            try {
                java.lang.reflect.Field fd = o.getClass().getDeclaredField(n);
                fd.setAccessible(true);
                if (fd.getType() == String.class) { fd.set(o, v); return; }
                return;
            } catch (NoSuchFieldException e) { /* 试下一个候选名 */ }
        }
    }
    static Object buildTetheringRequest(int type) throws Exception {
        Class<?> reqCls = Class.forName("android.net.TetheringRequestParcel");
        Object req = reqCls.getConstructor().newInstance();
        _setIntField(req, new String[]{"tetheringType", "type"}, type);
        _setBoolField(req, new String[]{"showProvisioningUi", "shouldShowProvisioningUi"}, false);
        // v1.7.9：不再设 exemptFromEntitlementCheck（=false，与系统 Settings 一致）。
        // 实测该 ROM 上设 true 会跳过 entitlement/provisioning 流程，导致 Tethering
        // 状态机不完整（wlan2 serving state 停在 INVALID、IpServer 不启动、DHCP 不建立）。
        // uid=1000 + callerPkg=com.android.settings 可正常通过 entitlement（不豁免）。
        // uid 字段（新 ROM 存在时设为 system uid=1000，模拟系统路径）。
        // 实测 uid=0（root）时 Tethering 状态机报 Invalid serving state、IpServer 不启动、
        // DHCP 不建立（连接的设备拿不到地址）；uid=1000 与系统 Settings 一致可正常流转。
        _setIntField(req, new String[]{"uid"}, 1000);
        // These values were observed only on Xiaomi 14 (houji). Passing wlan2 to
        // another phone whose AP is wlan1 can prevent its SoftAP from starting.
        // Leave OEM extensions unset elsewhere so Tethering selects the interface
        // and local address itself. Preserve the verified Xiaomi 14 path.
        if ("xiaomi".equalsIgnoreCase(android.os.Build.MANUFACTURER)
                && "houji".equalsIgnoreCase(android.os.Build.DEVICE)) {
            _setStringField(req, new String[]{"interfaceName"}, "wlan2");
            _setStringField(req, new String[]{"localIPv4Address"}, "172.18.100.120/24");
        }
        return req;
    }

    static int tetherConnectorStart(int type) throws Exception {
        final AtomicReference<Integer> result = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        IntResultCb cb = new IntResultCb(result, latch);
        Object svc = tetheringConnector();
        // AIDL: startTethering(TetheringRequestParcel, String, String, IIntResultListener)
        Method m = null;
        for (Method cand : svc.getClass().getMethods()) {
            if (!cand.getName().equals("startTethering")) continue;
            Class<?>[] pts = cand.getParameterTypes();
            if (pts.length >= 4 && pts[0].getName().equals("android.net.TetheringRequestParcel")) {
                m = cand;
                break;
            }
        }
        if (m == null) {
            throw new NoSuchMethodException("ITetheringConnector.startTethering(TetheringRequestParcel,...)");
        }
        Class<?>[] pts = m.getParameterTypes();
        Object req = buildTetheringRequest(type);
        // 模仿系统设置：callerPkg=com.android.settings，attributionTag 空
        String callerPkg = "com.android.settings";
        String attributionTag = "";
        Object[] argv = new Object[pts.length];
        for (int i = 0; i < pts.length; i++) {
            if (pts[i].getName().equals("android.net.TetheringRequestParcel")) argv[i] = req;
            else if (pts[i] == String.class) argv[i] = (i == 1) ? callerPkg : attributionTag;
            else if (pts[i].isAssignableFrom(android.net.IIntResultListener.class)) argv[i] = cb;
            else argv[i] = null;
        }
        Object r = m.invoke(svc, argv);
        int rc = (r instanceof Integer) ? ((Integer) r).intValue() : 0;
        if (rc != 0) {
            return rc;
        }
        if (!latch.await(2500, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("tether start result timeout");
        }
        return result.get() == null ? -1 : result.get().intValue();
    }

    static int tetherConnectorStop(int type) throws Exception {
        final AtomicReference<Integer> result = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        IntResultCb cb = new IntResultCb(result, latch);
        Object svc = tetheringConnector();
        Method m = null;
        for (Method cand : svc.getClass().getMethods()) {
            if (!cand.getName().equals("stopTethering")) continue;
            Class<?>[] pts = cand.getParameterTypes();
            if (pts.length >= 1 && pts[0] == int.class) {
                m = cand;
                break;
            }
        }
        if (m == null) {
            throw new NoSuchMethodException("ITetheringConnector.stopTethering");
        }
        Class<?>[] pts = m.getParameterTypes();
        Object[] argv = new Object[pts.length];
        for (int i = 0; i < pts.length; i++) {
            if (pts[i] == int.class) argv[i] = Integer.valueOf(type);
            else if (pts[i] == String.class) argv[i] = (i == 1) ? "com.android.settings" : "";
            else if (pts[i].isAssignableFrom(android.net.IIntResultListener.class)) argv[i] = cb;
            else argv[i] = null;
        }
        Object r = m.invoke(svc, argv);
        int rc = (r instanceof Integer) ? ((Integer) r).intValue() : 0;
        if (rc != 0) return rc;
        if (!latch.await(2500, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("tether stop result timeout");
        }
        return result.get() == null ? 0 : result.get().intValue();
    }

    static void doTetherStart(int type) throws Exception {
        // Modern：ITetheringConnector
        try {
            int rc = tetherConnectorStart(type);
            if (rc == 0) {
                System.out.println("backend=modern\nok=1");
                return;
            }
            System.out.println("backend=modern\nresult=" + rc);
            System.exit(1);
        } catch (Throwable modernErr) {
            // Legacy：IConnectivityManager.startTethering
            try {
                Object svc = connectivityService();
                Method m = svc.getClass().getMethod("startTethering",
                        int.class, boolean.class, Class.forName("android.net.IOnStartTetheringCallback"), int.class);
                Object cb = Proxy.newProxyInstance(
                        Class.forName("android.net.IOnStartTetheringCallback").getClassLoader(),
                        new Class<?>[]{Class.forName("android.net.IOnStartTetheringCallback")},
                        new InvocationHandler() {
                            public Object invoke(Object proxy, Method method, Object[] args) {
                                if (method.getName().equals("asBinder")) return silentBinder();
                                return null;
                            }
                        });
                m.invoke(svc, Integer.valueOf(type), Boolean.FALSE, cb, Integer.valueOf(android.os.Process.myUid()));
                System.out.println("backend=legacy\nok=1");
            } catch (NoSuchMethodException e) {
                System.err.println("ERROR_NOSUCHMETHOD: no tether start backend (modern=" + modernErr + ")");
                System.exit(1);
            } catch (InvocationTargetException e) {
                System.err.println("ERROR_TETHERING: " + e.getCause());
                System.exit(1);
            }
        }
    }

    static void doTetherStop(int type) throws Exception {
        // Modern：ITetheringConnector
        try {
            int rc = tetherConnectorStop(type);
            System.out.println("backend=modern\nok=1");
            return;
        } catch (Throwable modernErr) {
            // Legacy：IConnectivityManager.stopTethering
            try {
                Object svc = connectivityService();
                Method m = svc.getClass().getMethod("stopTethering", int.class);
                m.invoke(svc, Integer.valueOf(type));
                System.out.println("backend=legacy\nok=1");
            } catch (NoSuchMethodException e) {
                System.err.println("ERROR_NOSUCHMETHOD: no tether stop backend (modern=" + modernErr + ")");
                System.exit(1);
            } catch (InvocationTargetException e) {
                System.err.println("ERROR_TETHERING: " + e.getCause());
                System.exit(1);
            }
        }
    }

    /* ---------------- tether-state（开关状态，供 shell 侧确认系统 Tethering 真实状态） ---------------- */

    static void doTetherState() throws Exception {
        StringBuilder sb = new StringBuilder();
        boolean got = false;
        // 现代 Android Tethering 已迁移，IConnectivityManager 部分方法可能不存在
        try {
            Object svc = connectivityService();
            Method gti = svc.getClass().getMethod("getTetheredIfaces");
            String[] ifaces = (String[]) gti.invoke(svc);
            sb.append("tethered=").append(ifaces == null ? 0 : ifaces.length).append("\n");
            if (ifaces != null && ifaces.length > 0) {
                sb.append("ifaces=").append(String.join(",", ifaces)).append("\n");
            }
            got = true;
        } catch (NoSuchMethodException e) {
            sb.append("tethered=-1\n");
        }
        try {
            Object svc = connectivityService();
            Method gts = svc.getClass().getMethod("getTetheringState", int.class);
            int st = (Integer) gts.invoke(svc, 0); // TETHERING_WIFI=0
            sb.append("tether_state=").append(st).append("\n");
            got = true;
        } catch (NoSuchMethodException e) {
            sb.append("tether_state=-1\n");
        }
        if (!got) {
            sb.append("tether_state=-1\n");
        }
        System.out.print(sb);
    }

    /* ---------------- SoftAP 回调（继承 ISoftApCallback.Stub，跨进程回调由 framework 父类 onTransact 分发） ---------------- */
    // v1.7.9：不再使用 Proxy+silentBinder（跨进程收不到回调），改为继承真实 AIDL Stub。
    // 编译期 stub.jar 提供同名 ISoftApCallback$Stub 占位；运行时 app_process 的 boot classpath
    // 优先加载 framework 真实 Stub（parent-first），其 onTransact 正确反序列化 system_server 的回调。
    static class SoftApCb extends android.net.wifi.ISoftApCallback.Stub {
        final AtomicReference<Object> stateRef;
        final AtomicReference<Object> capsRef;
        final CountDownLatch latch;
        SoftApCb(AtomicReference<Object> s, AtomicReference<Object> c, CountDownLatch l) {
            stateRef = s; capsRef = c; latch = l;
        }
        public void onStateChanged(int state, int failureReason) throws android.os.RemoteException {
            stateRef.set(Integer.valueOf(state));
            latch.countDown();
        }
        public void onCapabilityChanged(android.net.wifi.SoftApCapability capability) throws android.os.RemoteException {
            capsRef.set(capability);
            latch.countDown();
        }
        public void onConnectedClientsChanged(java.util.List<?> clients) throws android.os.RemoteException {
            // 不关心
        }
        public void onInfoChanged(android.net.wifi.SoftApInfo info) throws android.os.RemoteException {
            // 不关心
        }
        public void onConnectedClientsChangedForApUid(int apUid, java.util.List<?> clients) throws android.os.RemoteException {
            // 不关心
        }
        public void onClientNumChanged(int num) throws android.os.RemoteException {
            // 不关心
        }
    }

    // 通过 IWifiManager 反射注册 ISoftApCallback；返回已注册的 SoftApCb。
    static SoftApCb registerSoftApCallback(AtomicReference<Object> stateRef,
                                           AtomicReference<Object> capsRef,
                                           CountDownLatch latch) throws Exception {
        SoftApCb cb = new SoftApCb(stateRef, capsRef, latch);
        Object svc = wifiService();
        Class<?> cbCls = Class.forName("android.net.wifi.ISoftApCallback");
        Method reg = null;
        for (Method cand : svc.getClass().getMethods()) {
            if (cand.getName().equals("registerSoftApCallback")
                    && cand.getParameterTypes().length >= 1
                    && cand.getParameterTypes()[0].isAssignableFrom(cbCls)) {
                reg = cand;
                break;
            }
        }
        if (reg == null) {
            throw new NoSuchMethodException("IWifiManager.registerSoftApCallback");
        }
        Class<?>[] pts = reg.getParameterTypes();
        Object[] argv = new Object[pts.length];
        for (int i = 0; i < pts.length; i++) {
            if (pts[i] == android.os.Looper.class) argv[i] = null;
            else argv[i] = cb;
        }
        reg.invoke(svc, argv);
        return cb;
    }

    /* ---------------- softap-capability（ISoftApCallback.onCapabilityChanged 实测） ---------------- */
    static void doSoftApCapability() throws Exception {
        StringBuilder sb = new StringBuilder();
        try {
            Class.forName("android.net.wifi.SoftApCapability");
        } catch (ClassNotFoundException e) {
            sb.append("caps=0\n");
            System.out.print(sb);
            return;
        }
        final AtomicReference<Object> capsRef = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        try {
            registerSoftApCallback(new AtomicReference<>(null), capsRef, latch);
        } catch (Throwable t) {
            sb.append("caps=0\n");
            System.out.print(sb);
            return;
        }
        try {
            latch.await(2500, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            // 忽略
        }
        Object caps = capsRef.get();
        if (caps == null) {
            sb.append("caps=0\n");
            System.out.print(sb);
            return;
        }
        sb.append("caps=1\n");
        int[] bands = new int[]{1, 2, 4};
        String[] keys = new String[]{"channels2g", "channels5g", "channels6g"};
        for (int i = 0; i < bands.length; i++) {
            StringBuilder line = new StringBuilder(keys[i] + "=");
            try {
                Method cml = caps.getClass().getMethod("getSupportedChannelList", int.class);
                Object list = cml.invoke(caps, Integer.valueOf(bands[i]));
                if (list instanceof int[]) {
                    int[] arr = (int[]) list;
                    if (arr.length == 0) line.append("empty");
                    else for (int j = 0; j < arr.length; j++) { if (j > 0) line.append(","); line.append(arr[j]); }
                } else if (list instanceof java.util.List) {
                    java.util.List<?> l = (java.util.List<?>) list;
                    if (l == null || l.isEmpty()) line.append("empty");
                    else for (int j = 0; j < l.size(); j++) { if (j > 0) line.append(","); line.append(l.get(j)); }
                } else {
                    line.append("empty");
                }
            } catch (Throwable t) {
                line.append("empty");
            }
            sb.append(line).append("\n");
        }
        // 最大客户端（硬件能力）
        try {
            Method mm = caps.getClass().getMethod("getMaxSupportedClients");
            Object mc = mm.invoke(caps);
            sb.append("max_clients=").append(mc == null ? 0 : mc).append("\n");
        } catch (Throwable t) {
            try {
                Method mm = caps.getClass().getMethod("getMaximumSupportedClientNumber");
                Object mc = mm.invoke(caps);
                sb.append("max_clients=").append(mc == null ? 0 : mc).append("\n");
            } catch (Throwable t2) {
                sb.append("max_clients=0\n");
            }
        }
        System.out.print(sb);
    }

    /* ---------------- softap-state（ISoftApCallback.onStateChanged 实测） ---------------- */
    // 输出 SoftAP Framework 真实状态数值（10=DISABLING 11=DISABLED 12=ENABLING 13=ENABLED 14=FAILED）。
    // "failure reason: 0" 表示无失败原因，只按最终 state 判定；无法取得回调则输出 -1。
    static void doSoftApState() throws Exception {
        final AtomicReference<Object> stateRef = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        try {
            registerSoftApCallback(stateRef, new AtomicReference<>(null), latch);
        } catch (Throwable t) {
            System.out.print("softap_state=-1\n");
            return;
        }
        try {
            latch.await(2500, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            // 忽略
        }
        Object st = stateRef.get();
        System.out.print("softap_state=" + (st == null ? -1 : st) + "\n");
    }

    /* ---------------- probe（真实能力探测，shell 侧决定 read/write 与同步级别） ---------------- */

    static void doProbe() throws Exception {
        StringBuilder sb = new StringBuilder();
        sb.append("api=").append(android.os.Build.VERSION.SDK_INT).append("\n");

        // Wi-Fi 服务与读取能力
        boolean wifiOk = false;
        try {
            Object svc = wifiService();
            wifiOk = true;
            try {
                svc.getClass().getMethod("getSoftApConfiguration");
                Object cfg = svc.getClass().getMethod("getSoftApConfiguration").invoke(svc);
                sb.append("get_config=1\n");
                sb.append("get_config_has_data=").append(cfg != null ? 1 : 0).append("\n");
            } catch (NoSuchMethodException e) {
                sb.append("get_config=0\n");
            }
        } catch (Throwable t) {
            sb.append("wifi_service=0\n");
            sb.append("wifi_error=").append(t.getClass().getSimpleName()).append("\n");
        }
        if (wifiOk) sb.append("wifi_service=1\n");

        // setSoftApConfiguration 签名（标准 2 参 / 单参 / 其他）
        try {
            Object svc = wifiService();
            boolean two = false, one = false, other = false;
            for (Method cand : svc.getClass().getMethods()) {
                if (!cand.getName().equals("setSoftApConfiguration")) continue;
                Class<?>[] pts = cand.getParameterTypes();
                if (pts.length == 2 && pts[0].getName().equals("android.net.wifi.SoftApConfiguration")) two = true;
                else if (pts.length == 1 && pts[0].getName().equals("android.net.wifi.SoftApConfiguration")) one = true;
                else other = true;
            }
            sb.append("set_config_2arg=").append(two ? 1 : 0).append("\n");
            sb.append("set_config_1arg=").append(one ? 1 : 0).append("\n");
            sb.append("set_config_other=").append(other ? 1 : 0).append("\n");
        } catch (Throwable t) {
            sb.append("set_config_2arg=0\nset_config_1arg=0\nset_config_other=0\n");
        }

        // Builder 方法探测
        try {
            Class<?> bCls = Class.forName("android.net.wifi.SoftApConfiguration$Builder");
            has(bCls, "setSsid", sb, "builder_setSsid", String.class);
            has(bCls, "setPassphrase", sb, "builder_setPassphrase_int", String.class, int.class);
            has(bCls, "setPassphrase", sb, "builder_setPassphrase_str", String.class);
            has(bCls, "setSecurityType", sb, "builder_setSecurityType", int.class);
            has(bCls, "setBand", sb, "builder_setBand", int.class);
            has(bCls, "setChannel", sb, "builder_setChannel_intint", int.class, int.class);
            has(bCls, "setChannel", sb, "builder_setChannel_int", int.class);
            has(bCls, "setHiddenSsid", sb, "builder_setHiddenSsid", boolean.class);
            has(bCls, "setMaxNumberOfClients", sb, "builder_setMaxNumberOfClients", int.class);
        } catch (ClassNotFoundException e) {
            sb.append("builder_class=0\n");
        }

        // 安全/频段常量（运行时反射 Framework 字段，替代硬编码）
        readIntConstants("android.net.wifi.SoftApConfiguration", sb,
                "sec_open", "SECURITY_TYPE_OPEN",
                "sec_wpa2", "SECURITY_TYPE_WPA2_PSK",
                "sec_wpa3_transition", "SECURITY_TYPE_WPA3_SAE_TRANSITION",
                "sec_wpa3", "SECURITY_TYPE_WPA3_SAE",
                "sec_owe_transition", "SECURITY_TYPE_WPA3_OWE_TRANSITION",
                "sec_owe", "SECURITY_TYPE_WPA3_OWE");
        readIntConstants("android.net.wifi.SoftApConfiguration", sb,
                "band_2g", "BAND_2GHZ",
                "band_5g", "BAND_5GHZ",
                "band_6g", "BAND_6GHZ",
                "band_any", "BAND_ANY");

        // SoftApCapability 类存在 + SoftApCallback 注册路径（软AP能力走 callback，不猜 getSoftApCapabilities）
        try {
            Class.forName("android.net.wifi.SoftApCapability");
            sb.append("softap_capability=1\n");
        } catch (ClassNotFoundException e) {
            sb.append("softap_capability=0\n");
        }
        try {
            Object svc = wifiService();
            boolean cbReg = false;
            Class<?> cbCls = Class.forName("android.net.wifi.ISoftApCallback");
            for (Method cand : svc.getClass().getMethods()) {
                if (cand.getName().equals("registerSoftApCallback")
                        && cand.getParameterTypes().length >= 1
                        && cand.getParameterTypes()[0].isAssignableFrom(cbCls)) {
                    cbReg = true;
                    break;
                }
            }
            sb.append("softap_callback=").append(cbReg ? 1 : 0).append("\n");
        } catch (Throwable t) {
            sb.append("softap_callback=0\n");
        }

        // 密码是否可读回（部分 ROM 读回为空；决定保存后是否校验密码）
        try {
            Object cfg = getConfig();
            if (cfg != null) {
                Object pass = cfg.getClass().getMethod("getPassphrase").invoke(cfg);
                sb.append("password_readable=").append(pass != null ? 1 : 0).append("\n");
            } else {
                sb.append("password_readable=0\n");
            }
        } catch (Throwable t) {
            sb.append("password_readable=0\n");
        }

        // 系统 Tethering 能力：Modern（ITetheringConnector，AIDL TetheringRequestParcel 签名）+ Legacy（IConnectivityManager）独立探测
        boolean connOk = false, connStart = false, connStop = false;
        try {
            Object tc = tetheringConnector();
            connOk = true;
            for (Method cand : tc.getClass().getMethods()) {
                if (!cand.getName().equals("startTethering")) continue;
                Class<?>[] pts = cand.getParameterTypes();
                if (pts.length >= 4 && pts[0].getName().equals("android.net.TetheringRequestParcel")) connStart = true;
            }
            for (Method cand : tc.getClass().getMethods()) {
                if (!cand.getName().equals("stopTethering")) continue;
                Class<?>[] pts = cand.getParameterTypes();
                if (pts.length >= 1 && pts[0] == int.class) connStop = true;
            }
        } catch (Throwable t) {
            connOk = false;
        }
        boolean cmStart = false, cmStop = false;
        try {
            Object svc = connectivityService();
            try {
                svc.getClass().getMethod("startTethering", int.class, boolean.class,
                        Class.forName("android.net.IOnStartTetheringCallback"), int.class);
                cmStart = true;
            } catch (NoSuchMethodException e) { /* legacy 不存在 */ }
            try {
                svc.getClass().getMethod("stopTethering", int.class);
                cmStop = true;
            } catch (NoSuchMethodException e) { /* legacy 不存在 */ }
        } catch (Throwable t2) {
            /* connectivity service 不可用 */
        }
        sb.append("tether_connector=").append(connOk ? 1 : 0).append("\n");
        sb.append("tether_connector_start=").append(connStart ? 1 : 0).append("\n");
        sb.append("tether_connector_stop=").append(connStop ? 1 : 0).append("\n");
        sb.append("tether_start_cm=").append(cmStart ? 1 : 0).append("\n");
        sb.append("tether_stop_cm=").append(cmStop ? 1 : 0).append("\n");

        System.out.print(sb);
    }

    static void has(Class<?> c, String name, StringBuilder sb, String key, Class<?>... params) throws Exception {
        try {
            c.getMethod(name, params);
            sb.append(key).append("=1\n");
        } catch (NoSuchMethodException e) {
            sb.append(key).append("=0\n");
        }
    }

    static void readIntConstants(String clsName, StringBuilder sb, String... kv) throws Exception {
        Class<?> c;
        try {
            c = Class.forName(clsName);
        } catch (ClassNotFoundException e) {
            for (int i = 0; i < kv.length; i += 2) sb.append(kv[i]).append("=-1\n");
            return;
        }
        for (int i = 0; i < kv.length; i += 2) {
            String key = kv[i], fname = kv[i + 1];
            try {
                Field f = c.getField(fname);
                sb.append(key).append("=").append(f.getInt(null)).append("\n");
            } catch (Throwable t) {
                sb.append(key).append("=-1\n");
            }
        }
    }

    /* ---------------- 常量/名称映射 ---------------- */

    static int secFromName(String security) {
        if (security.equals("open")) return SEC_OPEN;
        if (security.equals("wpa3")) return SEC_WPA3;
        if (security.equals("wpa3_transition")) return SEC_WPA3_TRANSITION;
        if (security.equals("owe_transition")) return SEC_OWE_TRANSITION;
        if (security.equals("owe")) return SEC_OWE;
        return SEC_WPA2;
    }

    static String secName(int sec) {
        switch (sec) {
            case SEC_OPEN: return "open";
            case SEC_WPA3: return "wpa3";
            case SEC_WPA3_TRANSITION: return "wpa3_transition";
            case SEC_OWE_TRANSITION: return "owe_transition";
            case SEC_OWE: return "owe";
            default: return "wpa2";
        }
    }

    static int bandFromName(String band) {
        if (band.equals("2")) return BAND_2GHZ;
        if (band.equals("5")) return BAND_5GHZ;
        if (band.equals("6")) return BAND_6GHZ;
        return BAND_ANY;
    }

    static String bandName(int band) {
        switch (band) {
            case BAND_2GHZ: return "2";
            case BAND_5GHZ: return "5";
            case BAND_6GHZ: return "6";
            default: return "any";
        }
    }

    static int parseInt(String s, int dflt) {
        try {
            return Integer.parseInt(s.trim());
        } catch (Exception e) {
            return dflt;
        }
    }

    static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }
}
