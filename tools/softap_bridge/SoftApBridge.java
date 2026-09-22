/*
 * SoftApBridge — Android-Hotspot-Web 系统热点配置 Binder Bridge
 *
 * 用途：以 root 身份调用 Android Wi-Fi Framework 的真实持久化接口：
 *   IWifiManager.getSoftApConfiguration() / setSoftApConfiguration()
 *   （后者内部进入 WifiApConfigStore.setApConfiguration() 完成系统持久化）。
 *
 * 为什么需要它：
 *   cmd wifi start-softap <参数> 只是构造一个临时 SoftApConfiguration 调
 *   startTetheredHotspot(config) 启动热点，并不会写入系统持久配置
 *   （Android 设置页看到的配置不会因此改变、重启后丢失）。
 *   真正的"修改系统热点设置并永久保存"只能走 WifiManager.setSoftApConfiguration()。
 *
 * 运行方式（root，KernelSU/Magisk 环境）：
 *   app_process -Djava.class.path=<模块>/lib/softap_bridge.dex \
 *       /system/bin com.mifi.softap.SoftApBridge get
 *   app_process ... com.mifi.softap.SoftApBridge set <ssid> <sec> <pass> <band> <channel> <hidden> <maxclients>
 *
 * 输出（get，字符串字段 base64 防特殊字符）：
 *   present=1
 *   ssid_b64=...
 *   security=wpa2|wpa3|wpa3_transition|open
 *   password_b64=...
 *   band=2|5|6|any
 *   channel=N
 *   hidden=0|1
 *   maxclients=N
 *
 * 兼容：API 30+（SoftApConfiguration）。API<30 输出 present=0 与 ERROR_UNSUPPORTED，
 *   shell 侧据此降级（读走 XML fallback、写拒绝并提示 Level B/C）。
 *
 * 实现说明：SDK android.jar 中 SoftApConfiguration 的 Builder、band/channel/maxclients
 *   相关成员为 @hide，编译期不可见，因此全部通过运行时反射调用；常量值来自 AOSP 源码
 *   （SECURITY_TYPE: open=0 wpa2=1 wpa3=2 wpa3_transition=4；BAND: any=0 2g=1 5g=2 6g=4）。
 */
package com.mifi.softap;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

public class SoftApBridge {

    static final int SEC_OPEN = 0;
    static final int SEC_WPA2 = 1;
    static final int SEC_WPA3 = 2;
    static final int SEC_WPA3_TRANSITION = 4;

    static final int BAND_ANY = 0;
    static final int BAND_2GHZ = 1;
    static final int BAND_5GHZ = 2;
    static final int BAND_6GHZ = 4;

    public static void main(String[] args) {
        try {
            int api = android.os.Build.VERSION.SDK_INT;
            if (api < 30) {
                System.out.println("present=0");
                System.err.println("ERROR_UNSUPPORTED: SoftApConfiguration requires API 30+, current=" + api);
                System.exit(3);
            }
            String cmd = args.length > 0 ? args[0] : "get";
            if (cmd.equals("get")) {
                doGet();
            } else if (cmd.equals("set")) {
                if (args.length < 8) {
                    System.err.println("ERROR_USAGE: set needs 8 args");
                    System.exit(2);
                }
                doSet(args);
            } else if (cmd.equals("get-api")) {
                System.out.println("api=" + api);
            } else {
                System.err.println("ERROR_USAGE: usage get|set|get-api");
                System.exit(2);
            }
        } catch (Throwable t) {
            System.err.println("ERROR: " + t);
            System.exit(1);
        }
    }

    /** 通过 Binder 拿到 IWifiManager（@hide，反射调用）。 */
    static Object wifiService() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Method get = sm.getMethod("getService", String.class);
        android.os.IBinder b = (android.os.IBinder) get.invoke(null, "wifi");
        if (b == null) {
            throw new IllegalStateException("wifi service unavailable");
        }
        Class<?> stub = Class.forName("android.net.wifi.IWifiManager$Stub");
        Method asIface = stub.getMethod("asInterface", android.os.IBinder.class);
        return asIface.invoke(null, b);
    }

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
        int band = 0;
        int channel = 0;
        int max = 0;
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

    /** set ssid security password band channel hidden maxclients */
    static void doSet(String[] args) throws Exception {
        String ssid = args[1];
        String security = args[2];
        String password = args[3];
        String band = args[4];
        int channel = parseInt(args[5], 0);
        boolean hidden = args[6].equals("1");
        int max = parseInt(args[7], 0);

        int sec;
        if (security.equals("open")) sec = SEC_OPEN;
        else if (security.equals("wpa3")) sec = SEC_WPA3;
        else if (security.equals("wpa3_transition")) sec = SEC_WPA3_TRANSITION;
        else sec = SEC_WPA2;

        int b;
        if (band.equals("2")) b = BAND_2GHZ;
        else if (band.equals("5")) b = BAND_5GHZ;
        else if (band.equals("6")) b = BAND_6GHZ;
        else b = BAND_ANY;

        Class<?> cfgCls = Class.forName("android.net.wifi.SoftApConfiguration");
        Class<?> bCls = Class.forName("android.net.wifi.SoftApConfiguration$Builder");
        Object cur = getConfig();
        Object builder;
        if (cur != null) {
            builder = bCls.getConstructor(cfgCls).newInstance(cur);
        } else {
            builder = bCls.newInstance();
        }

        bCls.getMethod("setSsid", String.class).invoke(builder, ssid);
        bCls.getMethod("setSecurityType", int.class).invoke(builder, sec);
        if (sec == SEC_OPEN) {
            bCls.getMethod("setPassphrase", String.class).invoke(builder, new Object[]{null});
        } else {
            bCls.getMethod("setPassphrase", String.class).invoke(builder, password);
        }
        // 以下为 @hide 成员，运行时反射；个别 ROM 缺失时静默跳过（保留系统默认）
        try { bCls.getMethod("setBand", int.class).invoke(builder, b); } catch (NoSuchMethodException e) {}
        if (channel > 0 && b != BAND_ANY) {
            try { bCls.getMethod("setChannel", int.class).invoke(builder, channel); } catch (NoSuchMethodException e) {}
        }
        if (max > 0) {
            try { bCls.getMethod("setMaxNumberOfClients", int.class).invoke(builder, max); } catch (NoSuchMethodException e) {}
        }
        bCls.getMethod("setHiddenSsid", boolean.class).invoke(builder, hidden);
        Object cfg = bCls.getMethod("build").invoke(builder);

        Object svc = wifiService();
        Method m = svc.getClass().getMethod("setSoftApConfiguration", cfgCls);
        Boolean ok = (Boolean) m.invoke(svc, cfg);
        if (!Boolean.TRUE.equals(ok)) {
            System.err.println("ERROR: setSoftApConfiguration returned false");
            System.exit(1);
        }
        System.out.println("ok=1");
    }

    static String secName(int sec) {
        switch (sec) {
            case SEC_OPEN: return "open";
            case SEC_WPA3: return "wpa3";
            case SEC_WPA3_TRANSITION: return "wpa3_transition";
            default: return "wpa2";
        }
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
