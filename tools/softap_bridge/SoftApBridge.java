/*
 * SoftApBridge — Android-Hotspot-Web 系统热点配置 Binder Bridge（v2，AOSP 签名对齐）
 *
 * 职责（配置与开关分离）：
 *   get-config    读取系统持久 SoftApConfiguration（IWifiManager.getSoftApConfiguration）
 *   set-config    写入系统持久 SoftApConfiguration（IWifiManager.setSoftApConfiguration，
 *                 标准 AOSP 签名为 (SoftApConfiguration, String packageName)；
 *                 运行时枚举方法签名，兼容 (SoftApConfiguration) 等 OEM 变体）
 *   tether-state  读取 Wi-Fi tethering 状态（IConnectivityManager.getTetheredIfaces /
 *                 getTetheringState）——开关本身由 shell 侧走系统 Tethering 路径
 *   probe         运行时能力探测（方法签名、Builder 方法、安全/频段常量），
 *                 shell 侧据此决定 readConfig/writeConfig 与同步级别，不靠文件存在判断
 *
 * 为什么 set 不能只用单参数：
 *   AOSP IWifiManager.aidl：setSoftApConfiguration(SoftApConfiguration config,
 *   String packageName)；低版本/厂商可能存在单参数变体，因此运行时枚举匹配。
 *
 * AOSP 常量（运行时优先反射 Framework 字段，反射不到才用内置值）：
 *   SECURITY_TYPE: OPEN=0 WPA2_PSK=1 WPA3_SAE_TRANSITION=2 WPA3_SAE=3
 *                  WPA3_OWE_TRANSITION=4 WPA3_OWE=5
 *   BAND: 2GHZ=1 5GHZ=2 6GHZ=4 ANY=7（=1|2|4，禁止 0，setBand(0) 会抛 IllegalArgumentException）
 *
 * 运行方式（root，KernelSU/Magisk）：
 *   app_process -Djava.class.path=<模块>/lib/softap_bridge.dex \
 *       /system/bin com.mifi.softap.SoftApBridge get-config
 *   app_process ... com.mifi.softap.SoftApBridge set-config \
 *       <ssid> <open|wpa2|wpa3|wpa3_transition> <pass> \
 *       <2|5|6|any> <channel> <0|1> <maxclients>
 *   app_process ... com.mifi.softap.SoftApBridge tether-state
 *   app_process ... com.mifi.softap.SoftApBridge probe
 *
 * 输出（get-config，字符串字段 base64）：
 *   present=1
 *   ssid_b64=...
 *   security=open|wpa2|wpa3|wpa3_transition|owe_transition|owe
 *   password_b64=...
 *   band=2|5|6|any
 *   channel=N  hidden=0|1  maxclients=N
 *
 * 兼容：API 30+。API<30 输出 present=0 + ERROR_UNSUPPORTED，shell 侧降级。
 */
package com.mifi.softap;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

public class SoftApBridge {

    // AOSP 内置默认值（反射 Framework 字段优先，见 readSecurityConstants/readBandConstants）
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
                case "probe":
                    doProbe();
                    break;
                case "get-api":
                    System.out.println("api=" + api);
                    break;
                default:
                    System.err.println("ERROR_USAGE: usage get-config|set-config|tether-state|tether-start|tether-stop|probe|get-api");
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
                // OEM 变体：无 (String,int) 时只设安全类型（无密码方法则无法清除密码，报错让上层降级）
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
        } catch (java.lang.reflect.InvocationTargetException e) {
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

    /* ---------------- tether-start / tether-stop（走系统 Tethering 体系，不依赖 cmd connectivity 子命令） ---------------- */

    /** IConnectivityManager.startTethering(type, showProvisioningUi, IOnStartTetheringCallback, uid)
     *  callback 用 Proxy 实现接口 + asBinder 返回自定义 Binder（服务端跨进程回调时 transact 即可，无需实现 AIDL stub） */
    static Object tetherCallbackBinder() {
        return new android.os.Binder() {
            @Override
            protected boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) {
                // onTetheringStarted / onTetheringFailed：静默接受
                if (reply != null) reply.writeNoException();
                return true;
            }
        };
    }

    static Object tetherCallbackProxy() throws Exception {
        Class<?> cbCls = Class.forName("android.net.IOnStartTetheringCallback");
        final android.os.IBinder binder = (android.os.IBinder) tetherCallbackBinder();
        java.lang.reflect.InvocationHandler h = new java.lang.reflect.InvocationHandler() {
            public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args) {
                if (method.getName().equals("asBinder")) return binder;
                return null;
            }
        };
        return java.lang.reflect.Proxy.newProxyInstance(cbCls.getClassLoader(), new Class<?>[]{cbCls}, h);
    }

    static void doTetherStart(int type) throws Exception {
        try {
            Object svc = connectivityService();
            Method m = svc.getClass().getMethod("startTethering",
                    int.class, boolean.class, Class.forName("android.net.IOnStartTetheringCallback"), int.class);
            m.invoke(svc, Integer.valueOf(type), Boolean.FALSE, tetherCallbackProxy(), Integer.valueOf(android.os.Process.myUid()));
            System.out.println("ok=1");
        } catch (NoSuchMethodException e) {
            System.err.println("ERROR_NOSUCHMETHOD: IConnectivityManager.startTethering unavailable");
            System.exit(1);
        } catch (java.lang.reflect.InvocationTargetException e) {
            System.err.println("ERROR_TETHERING: " + e.getCause());
            System.exit(1);
        }
    }

    static void doTetherStop(int type) throws Exception {
        try {
            Object svc = connectivityService();
            Method m = svc.getClass().getMethod("stopTethering", int.class);
            m.invoke(svc, Integer.valueOf(type));
            System.out.println("ok=1");
        } catch (NoSuchMethodException e) {
            System.err.println("ERROR_NOSUCHMETHOD: IConnectivityManager.stopTethering unavailable");
            System.exit(1);
        } catch (java.lang.reflect.InvocationTargetException e) {
            System.err.println("ERROR_TETHERING: " + e.getCause());
            System.exit(1);
        }
    }

    /* ---------------- tether-state（开关状态，供 shell 侧确认系统 Tethering 真实状态） ---------------- */

    static void doTetherState() throws Exception {
        Object svc = connectivityService();
        StringBuilder sb = new StringBuilder();
        try {
            Method gti = svc.getClass().getMethod("getTetheredIfaces");
            String[] ifaces = (String[]) gti.invoke(svc);
            sb.append("tethered=").append(ifaces == null ? 0 : ifaces.length).append("\n");
            if (ifaces != null && ifaces.length > 0) {
                sb.append("ifaces=").append(String.join(",", ifaces)).append("\n");
            }
        } catch (NoSuchMethodException e) {
            sb.append("tethered=-1\n");
        }
        try {
            Method gts = svc.getClass().getMethod("getTetheringState", int.class);
            int st = (Integer) gts.invoke(svc, 0); // TETHERING_WIFI=0
            sb.append("tether_state=").append(st).append("\n");
        } catch (NoSuchMethodException e) {
            sb.append("tether_state=-1\n");
        }
        System.out.print(sb);
    }

    /* ---------------- probe（真实能力探测，shell 侧决定 read/write 与同步级别） ---------------- */

    static void doProbe() throws Exception {
        StringBuilder sb = new StringBuilder();
        sb.append("api=").append(android.os.Build.VERSION.SDK_INT).append("\n");

        // Wi-Fi 服务与读取能力
        boolean wifiOk = false;
        boolean getOk = false;
        try {
            Object svc = wifiService();
            wifiOk = true;
            try {
                svc.getClass().getMethod("getSoftApConfiguration");
                Object cfg = svc.getClass().getMethod("getSoftApConfiguration").invoke(svc);
                getOk = true;
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

        // SoftApCapability（API 30+，信道/最大客户端硬件能力）
        try {
            Class.forName("android.net.wifi.SoftApCapability");
            sb.append("softap_capability=1\n");
        } catch (ClassNotFoundException e) {
            sb.append("softap_capability=0\n");
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

        // 系统 Tethering 能力：IConnectivityManager.startTethering/stopTethering（API 26+，无需 cmd connectivity 子命令）
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
        } catch (Throwable t) {
            sb.append("tether_start_cm=0\ntether_stop_cm=0\n");
        }

        // 设备支持信道列表（SoftApCapabilities.getSupportedChannelList(band)，API 30+；获取不到则 Web 只显示"自动"）
        try {
            Object svc = wifiService();
            Object caps = svc.getClass().getMethod("getSoftApCapabilities").invoke(svc);
            if (caps != null) {
                Method cml = caps.getClass().getMethod("getSupportedChannelList", int.class);
                int[] bands = new int[]{1, 2, 4};
                String[] keys = new String[]{"channels2g", "channels5g", "channels6g"};
                for (int i = 0; i < bands.length; i++) {
                    Object list = cml.invoke(caps, Integer.valueOf(bands[i]));
                    StringBuilder line = new StringBuilder(keys[i] + "=");
                    if (list instanceof java.util.List) {
                        java.util.List<?> l = (java.util.List<?>) list;
                        if (l == null || l.isEmpty()) {
                            line.append("empty");
                        } else {
                            for (int j = 0; j < l.size(); j++) {
                                if (j > 0) line.append(",");
                                line.append(l.get(j));
                            }
                        }
                    } else {
                        line.append("empty");
                    }
                    sb.append(line).append("\n");
                }
            } else {
                sb.append("channels2g=empty\nchannels5g=empty\nchannels6g=empty\n");
            }
        } catch (NoSuchMethodException e) {
            sb.append("channels2g=empty\nchannels5g=empty\nchannels6g=empty\n");
        } catch (Throwable t) {
            sb.append("channels2g=empty\nchannels5g=empty\nchannels6g=empty\n");
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
