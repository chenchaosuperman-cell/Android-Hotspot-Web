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
                case "probe":
                    doProbe();
                    break;
                case "get-api":
                    System.out.println("api=" + api);
                    break;
                default:
                    System.err.println("ERROR_USAGE: usage get-config|set-config|tether-state|tether-start|tether-stop|softap-capability|probe|get-api");
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

    /** Modern Backend：ITetheringConnector（Android 12+ 系统 tethering 服务） */
    static int tetherConnectorStart(int type) throws Exception {
        final AtomicReference<Integer> result = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        final android.os.IBinder binder = silentBinder();
        Class<?> cbCls = Class.forName("android.net.IStartTetheringCallback");
        Object cb = Proxy.newProxyInstance(cbCls.getClassLoader(), new Class<?>[]{cbCls},
                new InvocationHandler() {
                    public Object invoke(Object proxy, Method method, Object[] args) {
                        if (method.getName().equals("onTetheringStarted") && args != null && args.length > 0) {
                            result.set(((Number) args[0]).intValue());
                            latch.countDown();
                        }
                        if (method.getName().equals("asBinder")) return binder;
                        return null;
                    }
                });
        Object svc = tetheringConnector();
        // 枚举 startTethering(int, Executor, IStartTetheringCallback) / (int, IStartTetheringCallback, Executor)
        java.util.concurrent.Executor ex = new java.util.concurrent.Executor() {
            public void execute(Runnable r) { r.run(); }
        };
        Method m = null;
        Class<?> exCls = java.util.concurrent.Executor.class;
        for (Method cand : svc.getClass().getMethods()) {
            if (!cand.getName().equals("startTethering")) continue;
            Class<?>[] pts = cand.getParameterTypes();
            if (pts.length >= 3 && pts[0] == int.class
                    && (pts[1] == exCls || pts[2] == exCls)) {
                m = cand;
                break;
            }
        }
        if (m == null) {
            throw new NoSuchMethodException("ITetheringConnector.startTethering");
        }
        Class<?>[] pts = m.getParameterTypes();
        Object[] argv = new Object[pts.length];
        for (int i = 0; i < pts.length; i++) {
            if (pts[i] == int.class) argv[i] = Integer.valueOf(type);
            else if (pts[i] == exCls) argv[i] = ex;
            else argv[i] = cb;
        }
        m.invoke(svc, argv);
        if (!latch.await(2500, TimeUnit.MILLISECONDS)) {
            throw new IllegalStateException("tether start callback timeout");
        }
        return result.get() == null ? -1 : result.get().intValue();
    }

    static int tetherConnectorStop(int type) throws Exception {
        Object svc = tetheringConnector();
        Method m = svc.getClass().getMethod("stopTethering", int.class);
        Object r = m.invoke(svc, Integer.valueOf(type));
        if (r instanceof Integer) {
            return ((Integer) r).intValue();
        }
        return 0;
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

    /* ---------------- softap-capability（SoftApCallback.onCapabilityChanged 实测） ---------------- */

    static void doSoftApCapability() throws Exception {
        StringBuilder sb = new StringBuilder();
        final AtomicReference<Object> capsRef = new AtomicReference<>(null);
        final CountDownLatch latch = new CountDownLatch(1);
        try {
            Class.forName("android.net.wifi.SoftApCapability");
        } catch (ClassNotFoundException e) {
            sb.append("caps=0\n");
            System.out.print(sb);
            return;
        }
        try {
            android.os.Looper.prepareMainLooper();
        } catch (RuntimeException e) {
            // 已 prepare：忽略
        }
        final android.os.IBinder binder = silentBinder();
        Class<?> cbCls = Class.forName("android.net.wifi.IWifiManagerSoftApCallback");
        Object cb = Proxy.newProxyInstance(cbCls.getClassLoader(), new Class<?>[]{cbCls},
                new InvocationHandler() {
                    public Object invoke(Object proxy, Method method, Object[] args) {
                        if (method.getName().equals("onCapabilityChanged") && args != null && args.length > 0 && args[0] != null) {
                            capsRef.set(args[0]);
                            latch.countDown();
                        }
                        if (method.getName().equals("asBinder")) return binder;
                        return null;
                    }
                });
        Object svc = wifiService();
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
            sb.append("caps=0\n");
            System.out.print(sb);
            return;
        }
        Class<?>[] pts = reg.getParameterTypes();
        Object[] argv = new Object[pts.length];
        for (int i = 0; i < pts.length; i++) {
            if (pts[i] == android.os.Looper.class) argv[i] = android.os.Looper.getMainLooper();
            else argv[i] = cb;
        }
        reg.invoke(svc, argv);
        // 驱动 main looper（子线程），最多等 2.5s
        Thread looperThread = new Thread(new Runnable() {
            public void run() {
                android.os.Looper.loop();
            }
        });
        looperThread.setDaemon(true);
        looperThread.start();
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
            Class<?> cbCls = Class.forName("android.net.wifi.IWifiManagerSoftApCallback");
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

        // 系统 Tethering 能力：Modern（ITetheringConnector）优先，Legacy（IConnectivityManager）兜底
        try {
            Object tc = tetheringConnector();
            boolean st = false, sp = false;
            Class<?> exCls = java.util.concurrent.Executor.class;
            for (Method cand : tc.getClass().getMethods()) {
                if (!cand.getName().equals("startTethering")) continue;
                Class<?>[] pts = cand.getParameterTypes();
                if (pts.length >= 3 && pts[0] == int.class && (pts[1] == exCls || pts[2] == exCls)) st = true;
            }
            try {
                tc.getClass().getMethod("stopTethering", int.class);
                sp = true;
            } catch (NoSuchMethodException e) { /* ignore */ }
            sb.append("tether_connector=1\n");
            sb.append("tether_connector_start=").append(st ? 1 : 0).append("\n");
            sb.append("tether_connector_stop=").append(sp ? 1 : 0).append("\n");
        } catch (Throwable t) {
            sb.append("tether_connector=0\n");
            try {
                Object svc = connectivityService();
                try {
                    svc.getClass().getMethod("startTethering", int.class, boolean.class,
                            Class.forName("android.net.IOnStartTetheringCallback"), int.class);
                    sb.append("tether_start_cm=1\n");
                } catch (NoSuchMethodException e) {
                    sb.append("tether_start_cm=0\n");
                }
                try {
                    svc.getClass().getMethod("stopTethering", int.class);
                    sb.append("tether_stop_cm=1\n");
                } catch (NoSuchMethodException e) {
                    sb.append("tether_stop_cm=0\n");
                }
            } catch (Throwable t2) {
                sb.append("tether_start_cm=0\ntether_stop_cm=0\n");
            }
        }

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
