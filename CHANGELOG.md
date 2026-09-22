# v1.7.6-beta（2026-09-22）一套配置 + 系统 Framework 持久化

> 架构升级：热点配置不再维护「模块一份 + 系统一份」，改为**系统 SoftApConfiguration 为唯一数据源**，系统设置与 Web 双向同步；新增 **Hotspot Compatibility Layer** 与 **Binder Bridge**，写入一律走 Android Wi-Fi Framework 真实持久化接口。

- **一套配置（消除两套）**：Web 后台「热点设置」与手机系统设置共用同一份 Android 持久 SoftApConfiguration。
  - 系统设置里改热点 → Web 状态/设置页刷新即同步；
  - Web 里保存 → **走 Framework `setSoftApConfiguration()`（→ `WifiApConfigStore.setApConfiguration()` 系统持久化）**，热点开着时立即重启应用、关着时仅保存；启动一律无参（系统 tethering 用已保存配置，与系统设置开启行为一致）；
  - 旧版 `config.conf` 中残留的热点参数在首次启动时自动迁移进系统（经同一 Framework 路径），此后不再保存。
- **Binder Bridge（`lib/softap_bridge.dex`，`tools/softap_bridge/SoftApBridge.java`）**：root 下经 `app_process` 调用 `IWifiManager.get/setSoftApConfiguration()`，即 Android 设置应用同一套持久化 API。
  - 为什么不用 `cmd wifi start-softap <参数>`：AOSP 中该命令只构造临时 SoftApConfiguration 调 `startTetheredHotspot()` 启动，**不写系统持久配置**（设置页不变化、重启丢失）；
  - 明确禁止直接改写 `WifiConfigStore.xml`：内存中配置不会因改文件而更新，随后会被系统写回覆盖；
  - API 30+ 使用 SoftApConfiguration；API < 30 输出明确降级（读走 XML 只读 fallback、写拒绝并提示 Level B/C）。
- **Hotspot Compatibility Layer（`lib/compat.sh`）**：统一 7 接口 `hotspot_get_capabilities / get_config / set_config / get_state / start / stop / restart`；运行时能力检测输出 JSON（Android API、cmd wifi 启停、2.4/5/6 GHz、隐藏 SSID、信道、最大连接数、同步级别 A/B/C），前端按能力动态显示，不再出现「按钮能点、底层报错」。
- **残留清理**：`service.sh` 全新生成配置、`start_hotspot()`、`action.sh hotspot start`、`control.cgi` 配置导入导出与密码读取全部移除对 `SSID_B64/PASS_B64/SECURITY/BAND/CHANNEL/HIDDEN/MAX_CLIENTS` 的依赖（仅在升级迁移时由 `cfg_apply_key` 读取一次）；`get_password` 改从系统读。
- **新增 6 GHz 频段**；README 口径改为「通用兼容架构 + 按设备能力自动降级」，公布已验证机型（Xiaomi 14 / HyperOS 3 / Android 16 / KernelSU）。
- **回归测试**：重写为 Binder Bridge mock（模拟 Framework 持久化闭环：Web 改 → 系统配置变 → 重启/关开仍一致），新增迁移、留空密码沿用系统密码、open 网络、caps 降级断言（87 → 92 用例全部通过）。
- **rc2 — AOSP 签名对齐（依据代码级验收修正）**：
  - `setSoftApConfiguration` 修正为标准 AOSP 两参签名 `(SoftApConfiguration, String packageName)`，运行时枚举方法签名并兼容单参/OEM 变体；不再假设所有 ROM 相同。
  - `SoftApConfiguration.Builder` 改为真实 AOSP 接口：`setPassphrase(String,int)`（密码+加密方式一起）、`setChannel(int,int)`（信道+频段一起）；OEM 变体（`setPassphrase(String)`+`setSecurityType(int)`、`setChannel(int)`）作为兼容路径，运行时探测。
  - 常量修正：SecurityType `OPEN=0 / WPA2=1 / WPA3_TRANSITION=2 / WPA3=3 / OWE_TRANSITION=4 / OWE=5`；Band `2G=1 / 5G=2 / 6G=4 / ANY=7`（禁止 0，`setBand(0)` 会抛 IllegalArgumentException）。运行时优先反射 Framework 常量字段，内置值仅兜底。
  - 热点开关与配置彻底分离：**Generic Backend = 系统 Tethering**（`cmd connectivity tether start/stop`，内部即 TetheringManager.startTethering，与 Android 设置行为一致），启动后轮询 dumpsys/bridge 确认真实 ENABLED；`cmd wifi start-softap` 仅作 capability 验证后的 OEM/老系统 fallback（带参，从系统配置读取），删除"无参 start-softap"错误设计。
  - 保存配置**不再先关闭热点**：先 Framework 持久化 → 读回验证 → 成功才由控制层按需重启一次（热点开着→重启应用新配置；关着→仅保存不偷偷开启）；写失败/验证失败时热点保持原运行状态。
  - 能力检测改为 **probe 实测**：`SoftApBridge probe` 枚举 IWifiManager 方法签名、Builder 方法、反射 Framework 安全/频段常量；`readConfig/writeConfig`/同步级别由 probe 结果决定（不再凭 dex 文件存在），hidden/channel/max/频段能力由 SoftApConfiguration 层决定（不再依赖 cmd wifi help）。
  - 跨厂商接口名：`action.sh status` / 状态读取统一走 `hotspot_get_state` / `get_hotspot_iface`（bridge tether-state 优先，支持 wlan*/ap0/softap0/swlan0 等），不再写死 wlan[1-9]。
  - 业务层全部 stop 调用统一走 `hotspot_stop`（tether 优先）。
  - 回归测试增至 115 用例（新增 AOSP 常量映射、set 不关热点、写失败保持状态、tether 主路径、probe 驱动降级断言），全部通过。
- **rc3 — 第四轮修复（用户 6 项要求）**：
  - **OPEN 网络**：Builder 复制旧配置后显式 `setPassphrase(null, SECURITY_TYPE_OPEN)`（旧实现"不设密码"会保留原 WPA2 安全与密码，WPA2/WPA3 → 开放网络失败）；无 `(String,int)` 签名时降级 `setSecurityType(OPEN)`。
  - **Bridge 真正接管热点开关**：新增 `tether-start` / `tether-stop` 命令，反射 `IConnectivityManager.startTethering(int, boolean, IOnStartTetheringCallback, int)` / `stopTethering(int)`（回调经 Proxy+Binder 静默接受）；`hotspot_start/stop` 优先走 Bridge 系统 Tethering（与 Android 设置行为一致），`cmd connectivity tether` 降为 fallback 2、`cmd wifi start-softap` 为最后 fallback。
  - **旧版一次性迁移**：新增 `migrate_legacy_hotspot_config()`（marker 幂等）：启动时读取旧 `SSID_B64/PASS_B64/...` → 经 Framework `setSoftApConfiguration` 持久化 → `save_config` 重写（旧热点字段清除）→ 写 marker；不依赖 `hotspot_start` 传参（修复旧版升级后 Web 读取不到原模块配置的问题）。
  - **前端 formDirty 双向同步**：`hotspotDirty` 标记 + `sysDirtyHint` 提示条 + `reloadSysCfg()`；未编辑时状态轮询实时同步系统配置，编辑中被外部修改时提示"重新加载系统配置"；保存成功复位。
  - **hidden/channel/maxClients 全由 Framework capability 驱动**：`softap_hidden_supported`/`valid_channel` 改用 probe 实测（`SoftApCapabilities.getSupportedChannelList` 输出 channels2g/5g/6g JSON，前端动态生成信道列表，无列表仅"自动"）；maxClients 显式写 0（恢复系统默认）。
  - **保存验证增强**：读回验证增加 password（`password_readable` 能力时强制一致，ROM 遮蔽则记日志跳过）与 maxclients（能力支持时 0 与正数都必须一致）。
  - **架构修正**：`save_config` 从 control.cgi 移至 common.sh（迁移在 service.sh 启动时调用，此前函数不存在导致迁移后旧字段无法清除）。
  - 回归测试增至 **124 用例**（bridge tether-start/stop 断言、channels 实测断言、一次性迁移与幂等断言），全部通过。

# v1.7.5-beta（2026-09-22）稳定性修复版

- **修复代理默认范围错误（P0）**：全新安装默认仅代理热点设备（`PROXY_SCOPE` 默认 `hotspot`），不会再一开启就把手机本机一起加入代理；前端/后端/文档口径统一。旧配置已显式设置 `PROXY_SCOPE` 的保留原值。
- **修复 MAC 白名单切换残留（P0）**：白名单→黑名单切换时旧 `mifi_acl` 链残留、设备仍被旧白名单阻断的问题。新增统一入口 `apply_mac_policy()`：每次应用前先清理黑名单 DROP 规则与白名单链，再按当前模式重建；守护进程主循环、热点启动异步验证、设备操作均改走该入口。
- **白名单模式设备操作按钮**：设备列表按钮随模式变化——白名单模式为「加入白名单 / 移出白名单」（即时生效），黑名单模式保持「禁止上网 / 解除禁止上网」。
- **清空名单按模式拆分**：「清空黑名单」与「清空白名单」；清空白名单属危险操作（清空后所有客户端无法上网），前端二次确认。
- **移除「每日定时重启热点」**：与「定时开关」概念重复，且原实现（停止后等保活拉起）中断时间不可控；配置键、守护进程逻辑、前端 UI、README 全部移除。
- **module.prop / CHANGELOG 清理**：description 与最终功能一致，不再包含已删除的 Server酱 / 新设备通知 / 登录失败锁定 / 每日定时重启；v1.7.4 条目重写为最终功能清单，并合并重复的 v1.7.2-beta.1 记录。
- **回归测试扩充**：新增配置默认值（PROXY_SCOPE 默认 hotspot、旧值保留）、MAC 策略函数存在性与 iptables 清理顺序断言（17 → 32 用例全部通过）。

# v1.7.4-beta（2026-09-22）


- **新增「MAC 访问控制」双模式（设备管理）**：黑名单（禁止名单内设备上网）之外新增**白名单模式**——仅允许名单内设备上网，其余设备即使连上热点也无法访问网络。
  - 配置键 `MAC_MODE`（blacklist/whitelist）与 `ALLOWED_MACS`；白名单走专用 iptables 链 `mifi_acl`（RETURN 放行 + 兜底 DROP），与统计链独立。
  - 模式切换（黑名单 ⇄ 白名单）时自动清理旧策略残留（黑名单 DROP 规则 + 白名单链），统一走 `apply_mac_policy()`，避免旧白名单链残留导致切换后仍按旧规则阻断。
  - 设备列表按钮随模式变化：白名单模式下为「加入/移出白名单」；「清空名单」按钮同样按模式区分，清空白名单前二次确认（清空后所有客户端无法上网）。
- **新增「流量耗尽预测」**：首页套餐栏按当前账期日均消耗估算剩余流量可用天数（`predictDays`）。
- **新增通知渠道：Bark（iPhone 推送）**：通知队列支持渠道独立状态与失败退避重试（PushPlus / 钉钉 / Bark 三渠道）。
- **新增「设备适配检测」**：诊断面板显示 Root 框架（KernelSU/Magisk/APatch）、Android 版本、SDK、busybox/ip/iptables/softap/su 可用性，便于跨机型排查。
- **新增自动化回归测试骨架**：`tests/run_tests.sh` 对 MAC/时间/base64url/厂商识别/配置默认值与 MAC 策略函数做断言（本机与真机均可运行）。
- **文档清理**：删除长期停更的 `README.txt`，已知限制等说明并入 `README.md`。
- **首页信息密度优化**：温度并入顶部紧凑状态栏（`电量 100% · CPU 42°C · 已连接 3 台 · 5GHz` 单行展示）；温度卡仅在「偏高/过热」时自动展开警告，正常时不再占用卡片。
- **设置页精简**：固定「说明」改为页面底部的「帮助与说明」折叠项，默认收起。
- **隐藏 SSID 完善**：保存前自动检测系统是否支持 `cmd wifi start-softap -h`（软检测，仅解析 help 文本）；不支持时开关禁用并标注「当前系统不支持」；若启动失败自动回滚为广播 SSID 并持久化关闭隐藏（同时推送通知）。说明：隐藏 SSID 仅是「不广播名称」，不是安全机制，安全性提升有限。
- **功能归位与精简**：
  - 隐藏 SSID 从「热点设置」移入「高级设置」卡（保留能力检测与失败回滚）；
  - 代理范围（仅热点设备 / 仅手机本机 / 两者）从「科学上网」移入「高级设置」，默认仅代理热点设备（`PROXY_SCOPE` 默认 `hotspot`），不影响手机自身联网；
  - 设备限速从设备列表移入「实验功能」卡，状态接口新增 `tcSupported`，当前系统无 tc 时自动隐藏该入口；
  - 移除「Server酱」通知渠道（与 PushPlus 高度重叠；保留 Bark/PushPlus/钉钉，存量通知队列字段位保留以兼容旧文件）；
  - 移除「新设备接入通知」（随机/私有 MAC 易造成重复通知）；
  - 移除「登录失败锁定」（管理页由 HTTP Basic Auth 保护，CGI 内计数无法保护真实登录）。

# v1.7.3-beta（2026-09-22）

- **新增「隐藏 SSID」开关（热点设置）**：开启后热点不广播名称，客户端需手动输入热点名称和密码连接。
  - `cmd wifi start-softap` 增加 `-h` 选项；配置键 `HIDDEN`（0/1）随配置保存/导入导出。
  - 状态接口返回 `hidden`，前端回显开关状态，实际运行状态标注「已隐藏」。
  - 说明：隐藏 SSID 仅影响广播，不影响已连接设备；首次连接需手动添加网络。

# v1.7.2-beta.1（2026-09-21）

- **修复开机后 Web 一直显示“正在获取设备数据”**：dumpsys 直写文件（根治 ARG_MAX）、蜂窝信息统一 60s 快照、系统命令全部加超时、前端 8s 超时 + 失败 3 次提示重连。
- **状态接口提速**：CGI 只读缓存门 + 子进程削减，冷启动 6 秒内返回完整 JSON。
- **温度细分**：首页底部新增「手机温度」卡片（电池 / CPU / 最高 + 正常/偏高/过热状态）。
- 修正 service.sh 开机自启判断（`_UP_SEC < 120`）。

# v1.7.2-beta（2026-09-20）

- **修复分流模式（rule）下国内 HTTPS 全部走代理、导致全网断连的问题**（真机故障）。
  - 根因①：`GEOIP,CN,DIRECT,no-resolve` 对已被 sniffer 嗅探出 SNI 的连接无法用 IP 判定，
    国内 HTTPS 全部落入 `MATCH,GLOBAL` 走代理；
  - 根因②：GLOBAL 组当时选中节点不可达（连接超时），走代理的流量全断。
  - 修复：规则新增 `GEOSITE,CN,DIRECT`（按域名判定国内直连），置于 GEOIP 规则之前；
    下载 geosite.dat 国内域名集合（MetaCubeX meta-rules-dat）。
- **GEOSITE 分类名大小写陷阱**：geosite 分类名大小写敏感，必须写大写 `CN`（小写 `cn` 匹配不到任何数据、规则静默失效）。
- **代码落地**：`common.sh` 规则模板与 `proxy_init_dirs` 自动同步 geosite.dat；
  `customize.sh` 安装时多镜像在线下载 geosite.dat（V2Ray protobuf 格式 + 大小校验，失败不阻塞安装但会提示）。
- 验证：微信/豆包/小米/iCloud.cn 直连（`GeoSite(CN) DIRECT`）；google/github 经代理 200。

# v1.7.1-beta.1（2026-09-20）

- **模块目录与 ID 完全统一**：安装目录固定为 `/data/adb/modules/xiaomi_mifi_web`（目录名 = MODID，符合 KernelSU 规范）；所有 CGI/公共脚本不再硬编码 `xiaomi14_mifi_web` 模块路径；`dedup_dup_modules` 改为优先保留标准目录、备份非标准残留副本，运行时不移当前执行目录（避免服务路径失效）。
- **Mihomo 下载供应链加固**：仅允许 arm64/aarch64 安装代理组件；下载后强制校验官方 v1.19.31 SHA-256（`.gz` 与解压后二进制双重校验，`de00bc53…` / `dbd8af27…`），任一校验失败立即删除、绝不执行；临时文件改用 KernelSU `$TMPDIR` 唯一命名，不再共用 `/tmp/mihomo`。
- **后台安全（第一轮）**：首次安装生成随机后台管理密码（安装输出中显示，升级不覆盖已有密码）；新增 Web 管理端口访问控制——仅放行 `lo`、热点接口与 USB 共享接口，其余接口（蜂窝数据等）一律 `DROP`，supervisor 主循环周期性保活规则。
- **修复配置导入校验**：`NOTIFY_TRAFFIC_THRESHOLDS`（1~5 个 1~100 整数）、`PROXY_ROUTE_MODE`（rule/global）、`PROXY_SCOPE`（hotspot/self/both）从“只能是 0 或 1”分支拆出，导入可完整恢复。
- **行为一致性**：`action.sh hotspot start` 改为按模块保存的 SSID/密码/频段/信道/最大客户端启动，与 Web 后台一致。
- **文档/元数据**：README 同步 v1.7.1；新增 `update.json`（KernelSU 在线检查更新）；module.prop 增加 `updateJson`。

# v1.7.0（2026-09-20）

- **修复 KernelSU 管理器下滑模块列表闪退（根治）**：当 `/data/adb/modules/` 下存在多个目录且 `module.prop` 的 `id` 相同（如 `xiaomi14_mifi_web` 与误复制的 `xiaomi_mifi_web` 并存）时，KSU Manager 渲染模块列表 Compose key 冲突崩溃。
- 新增模块目录去重自检 `dedup_dup_modules`：`service.sh` 每次启动自动扫描 `/data/adb/modules/`，将与本模块同 `id` 的其他目录移入 `/data/adb/ksu/modules_dup_bak/` 备份，确保每个模块 `id` 全局唯一。
- `customize.sh` 安装/更新时同样执行去重，杜绝再次出现重复目录。
- 版本号升级：v1.6.2 → v1.7.0（versionCode 1700）。

# v1.6.0-beta.8

- 修复“全部测速”后节点延迟一直显示 `—`：改为等待 Mihomo MANUAL 策略组测速并直接返回结果。
- 测速期间按钮显示“测速中…”，完成后节点右侧显示 `xx ms`，失败节点显示“测速超时”。
- 测速结果不再依赖容易被 CGI 生命周期清理的后台子进程，也不再固定只等待 3.5 秒。

# v1.6.0-beta.7

- 修复科学上网页面引用未定义的 `routeMode` / `scope`，导致保存和启动按钮无响应。
- 补齐“代理模式”（智能分流/全局代理）与“代理范围”（仅热点/仅本机/两者）控件。
- 代理范围保存后同步本机代理兼容开关，并在启动和守护阶段真实控制热点、本机规则范围。

# v1.6.0-beta.4

- 重构“消息”Tab：短信转发置顶，转发渠道居中，提醒设置置底。
- 短信转发、PushPlus、钉钉、低电量、流量阈值、热点异常分别拆为独立卡片，减少设置堆叠。
- 每张卡片独立保存，只提交本功能字段，避免修改一项时连带提交整页配置。
- 渠道与短信运行状态分别就近显示，保留最近发送、失败次数与真实失败原因。

# v1.6.0-beta.3

- 修复 Android 16 本机透明代理：移除 Mihomo 全局 `routing-mark`，避免与 Android netd fwmark 路由冲突。
- 本机 OUTPUT 代理固定使用 root UID 绕过 Mihomo 自身，避免 REDIRECT 回环。
- 增加 Mihomo HTTP/TLS sniffer，改善本机 DNS 未完整被 53 端口劫持时 Google/海外站点的域名恢复。
- 不改动已经工作的热点客户端 `PREROUTING -> MIFI_PROXY` 路径。

# v1.6.0-beta.2

- 修复「手机本机也走代理」已开启但页面误判为未生效的问题：状态判定只检查必要 NAT/OUTPUT 透明代理规则，不再把可选 QUIC 阻断作为生效前提。
- 针对 Android 16 iptables wrapper 增加 `-S` 回退校验，避免 `iptables -C` 在部分环境返回异常造成假阴性。
- 本机 QUIC 阻断改为 best-effort：即使设备不支持 `filter OUTPUT + REJECT`，TCP/DNS 本机代理仍保持工作，不再整体回滚。
- 增加更细的本机代理错误码：NAT 链、DNS、TCP REDIRECT、OUTPUT hook、规则校验可分别定位。
- 状态接口新增 `selfProxyQuic`，前端可区分「TCP/DNS 已生效」和「QUIC 降级不可用」。

## v1.6.0-beta.1（2026-09-20）

### 新增：手机本机也走代理
- 科学页新增「手机本机也走代理」开关，默认关闭；热点客户端代理逻辑保持不变。
- 开启后使用独立 `MIFI_PROXY_SELF` NAT OUTPUT 链，将普通 Android App 的 TCP 流量透明转发到 Mihomo `redir-port: 7893`。
- 本机 TCP/UDP 53 自动重定向到 Mihomo DNS `1053`。
- Mihomo 配置使用 `routing-mark: 6666`；OUTPUT 链优先按 mark 放行核心自身出站，避免回环且尽量不放过 Android 系统流量；内核不支持 mark match 时降级为 uid 0 兼容模式。
- REDIRECT 模式下可同步阻止本机 UDP/443，让 Chrome / YouTube 等优先回落到 TCP/HTTPS。
- 本机代理与热点代理拆成两套独立链；热点关闭、接口变化时不会误拆手机本机代理。
- service 守护每 30 秒检查并恢复本机代理规则；核心/Provider 异常时自动 fail-open。
- 状态接口新增 `selfProxy` / `selfProxyActive` / `selfProxyError`，页面可区分「已配置」和「实际生效」。
- 卸载模块时完整清理 OUTPUT 本机代理链。

## v1.5.24-beta.5

- 修复科学插件 `Mihomo 配置校验失败`：收敛为更保守、当前文档支持的基础配置，移除首启阶段非必要 DNS/GEO 可选项。
- 保留 `GEOIP,CN,DIRECT` + `MATCH,GLOBAL`，国内 IP 直连、其它流量进入代理策略组。
- 配置校验失败时把 Mihomo 的真实错误摘要写入状态接口并显示在科学页，不再只显示泛化“配置错误”。
- Provider/AUTO/FALLBACK/MANUAL、DNS 劫持和 REDIRECT 逻辑保持不变。

## v1.5.24-beta.4
- 修复 Safari/移动端启动科学上网时 `Load failed`：代理启动改为后台任务，CGI 立即返回，不再用 20~40 秒长请求阻塞 Web 控制。
- `status.cgi` 改为读取代理健康快照，不再每 5 秒同步调用 Mihomo API/Provider，避免状态接口被代理网络请求拖死。
- service 守护每 30 秒更新 API/Provider/节点数量快照，并异步恢复 Mihomo。
- 更新订阅/全部测速改为后台任务，避免控制接口长时间占用。
- proxy.cgi 移除重复 API 预检查，减少节点列表失败时等待。
- 前端接口缓存版本升至 v142，并显示科学页自身接口错误。


## v1.5.24-beta.3
- 修复科学插件配置持久化：PROXY_ENABLE / PROXY_SUB_B64 / PROXY_MODE / PROXY_BLOCK_QUIC 正确读写。
- 修复订阅/节点 Base64URL 解码与 proxy.cgi action 解析。
- 修复节点列表：正确解析 Mihomo `/proxies` 的 `data.proxies` 结构。
- Provider 必须实际加载到节点后才挂透明代理；启动失败自动 fail-open。
- 国内 GEOIP 继续直连，GEO 数据改用内置 `geoip.metadb` + `geodata-mode: false`。
- DNS 增加境外 fallback（经 GLOBAL）与 Google/YouTube 污染过滤。
- iptables 仅挂到热点接口，修复 beta2 全局 PREROUTING 风险；支持热点接口变化自动重挂。
- service.sh 增加 Mihomo/API/iptables 守护；uninstall.sh 完整清理代理规则和核心进程。
- 去除重复代理 JS；新增核心/订阅/API/节点数量状态。
## v1.5.24-beta.1（2026-09-20）

### 新增：科学上网 / Mihomo 代理
- 内置 Mihomo v1.19.31 ARM64 核心（随模块打包，不在线下载）。
- 新增"科学"Tab：订阅填写、开关、节点选择、自动测速、故障切换。
- 三策略组：AUTO(url-test 自动测速) / FALLBACK(故障转移) / MANUAL(手动选择) / GLOBAL。
- 节点切换走 Mihomo RESTful API（PUT /proxies/GLOBAL），不重启核心。
- REDIRECT TCP 7893 + DNS 1053，只处理热点客户端，不影响手机本机。
- GEOIP,CN,DIRECT 规则：国内直连，国外走代理。
- health-check 120秒自动检测节点可用性。
- proxy.cgi 只读转发 Mihomo API，前端 JS 解析节点列表和延迟。

### 修复
- proxy_core_ok() 增加 ELF magic 校验和细分错误状态。
- DNS REDIRECT 替代 DNAT 到 127.0.0.1。
- config 模板加 geodata-mode 和 geoip.path 指向本地 MMDB。
## v1.5.23-beta.1（2026-09-19）

### 稳定性修复
- 修复 renderThChips() 引号嵌套导致整段 JavaScript 语法错误、页面永久卡在"检测中"；改用 DOM createElement + 事件绑定。
- 修复停止热点用后台子 shell 被 cgroup 杀掉、cmd wifi stop-softap 未执行的问题；改为同步执行。
- 修复 module.prop 开头 UTF-8 BOM 导致 KernelSU 识别异常；改为无 BOM。
- 修复历史账期 JSON 字段名缺引号和双层数组包裹。
- 修复 b64u -> b64url 函数名不匹配。

### UI / 交互
- 主题切换 280ms 平滑过渡（首屏不播动画），安卓状态栏 theme-color 同步。
- 所有按钮/折叠标题去除安卓默认矩形点击高亮，点击时轻微缩放反馈。
- 输入框统一 46px 高 / 16px 字号（防止 iOS 聚焦自动缩放），focus 只保留一层光晕。
- 提醒节点输入区重构：type=text + inputmode=numeric，数字键盘，自动过滤非数字字符。
- 设置页所有保存类按钮统一全宽 44px；低电量单独保存按钮合并到"保存通知事件"。
- 折叠区（details）分割线移到 summary，点击不闪灰色。
- 卡片移动端内边距 17px，统一间距规范。

### 其它
- 新增 LICENSE（MIT）、.gitignore、GitHub README。
## v1.5.20（2026-09-19）

### 页面结构
- 5 Tab 导航：首页 / 设备 / 流量 / 通知 / 设置；切换后 URL hash 记忆，刷新恢复上次 Tab。
- 首页重构：热点控制单按钮（根据运行状态显示"开启/关闭"，不再用颜色判断操作）+ 流量主卡片 + 紧凑状态栏；固定管理地址、备用网关、频段等低频信息移出首页。
- "开机自动启动"开关从首页移到"设置→定时与自动"。
- 删除测速外链（Speedtest.cn / Speed.do / 中科大测速）。

### 后端逻辑
- MANUAL_OFF 开机级临时状态：手动关闭后本次开机期间保活/定时/空闲不再拉起热点，重启手机后按 AUTOSTART 决定；后台服务、短信转发、PushPlus/钉钉推送不受影响。
- 账期剩余天数后端计算：29~31 日账期在短月份正确截断（min(账期日, 当月最后一天)），不再按 30 天硬算。
- 新设备接入通知彻底删除（后端触发块、common.sh 导入白名单、默认值）；known_macs 仍保留供历史设备/备注。
- HOLD_OFF 旧字段彻底清理（导入忽略、状态接口、前端摘要、保存函数）。
- 新增热点异常通知开关 NOTIFY_HOTSPOT_EVT（默认开）：保活自动恢复/启动失败时推送，可单独关闭。

### 通知
- "保存通知渠道"与"保存通知事件"拆成两个按钮，修改 Token 不再覆盖事件配置。
## v1.5.13（2026-09-19）

### P0 修复
- 空闲自动关闭改用"已连接设备"口径：邻居状态变 STALE/ARP 只表示一段时间无通信、Wi-Fi 实际仍连着，此前只算 REACHABLE/DELAY/PROBE 会把已连接设备误判为离线，导致有设备时仍倒计时并误关热点。新增 count_connected_clients() 供空闲判断使用；页面"活跃设备"仍用活跃口径，接口同时返回 activeClientCount / connectedClientCount；前端倒计时增加双保险。
- 顶部提示条"收起"后改为单行省略显示（不再彻底隐藏），按钮随状态在"展开/收起"间切换。

### 通知中心重构
- 消息通知卡片拆为"通知渠道"（PushPlus / 钉钉机器人 / 加签 / 测试）与"通知事件"（低电量 / 短信转发 / 流量阈值）两组，不再混淆"钉钉机器人"与"短信转发"。
- 低电量提醒从"定时与自动"移入"通知事件"，后端逻辑不变。
- 删除"新设备接入通知"开关（UI 与默认值）；后端默认 NOTIFY_NEWDEV=0，仍记录 known_macs 供历史设备/备注使用。
- 流量提醒节点可配置：NOTIFY_TRAFFIC_THRESHOLDS（逗号分隔 1~5 个、1~100、自动去重排序），替代原硬编码 80/90/100；与"超限自动关闭"相互独立。

### 其它
- 修复 service.sh 出窗分支 rm 列表重复 4 次 SKIP_WINDOW_FILE 的笔误。
- status.cgi 通知对象增加 thresholds 字段；control.cgi/导入配置白名单同步新字段。

## v1.5.12（2026-09-19）

### P0 修复
- 升级不再清空流量统计：老版本（1.5.10 及以前）升级时识别 config 已存在且无迁移目录，只补迁移标记、不执行破坏性清零；字段合并照常。
- SoftAP 缓存文件不再 source（安全）：改为逐行白名单解析，SSID 走 Base64 存储，状态/安全/频段/信道只接受枚举或数字，SSID 中的引号/反引号/$() 不再有代码执行风险。
- ZIP 打包改用正斜杠路径（web/cgi-bin/...），KernelSU/桌面 unzip 均能正确还原目录。

### P1 修复
- 账期 29~31 日跨月：上月起始日从原始账期日重新截断（31 日在 2 月不再错算成 28 日）。
- 一键关闭（不保活）在定时窗口内不再被 15 秒后重开：写入 skip_window 标记，当前窗口结束后自动清除；一键开启会立即清除该标记。
- 异步启动回滚保护：备份时记录配置 md5，异步期间用户若又改过配置则不回滚旧备份，只报告失败。
- 保存配置失败时显式释放操作锁，不再残留 120 秒。

### P2 修复
- usage.over 改按账期用量判断，不再按历史总累计。
- 只读操作（导出配置、测试通知/低电量、读密码、短信列表、鉴权）不再占用配置写锁，测试通知十几秒不再阻塞其它保存。
- 一键关闭按钮在"热点恢复中"也可点击（可取消正在进行的开启）。
- 后端业务失败（ok:false）统一显示错误色 Toast。
- service.sh 新建配置模板补全 DATA_PLAN_MB/DATA_PLAN_DAY/DATA_LIMIT_ACTION/LOWBATT_ENABLE/LOWBATT_THRESHOLD，删除废弃的 DATA_LIMIT_MB。
- UI 残留清理：旧内联分割线改 section-divider；通知说明负边距 margin-top:-8px 去除。

## v1.5.11（2026-09-19，热推增量）

### 新增功能
- 快速控制区改为“一键开启 / 一键关闭（不保活）”两个独立按钮：
  - 一键开启：用已保存配置直接开启热点，并解除手动关闭（HOLD_OFF=0 + DESIRED=1），保活/定时恢复自动拉起；
  - 一键关闭（不保活）：关闭热点并写入 DESIRED=0 + STOP_REASON=manual，保活不会自动重启。
- 按钮状态联动：热点运行中/正在开启时禁用“一键开启”；未运行时禁用“一键关闭”，避免误操作。

### 语义修正
- 一键关闭不再写入 HOLD_OFF=1（旧逻辑会连带禁用定时自动开启）：
  - 现在手动关闭仅阻止保活自动重启（DESIRED=0），定时计划到点仍按窗口自动开启；
  - 与“手动保持关闭”复选框相互独立、互不覆盖：复选框仍表示暂停全部自动开启（定时+保活）。
- 操作提示与二次确认文案同步更新（“保活不会自动重启，但定时计划到点仍会按设定自动开启”）。

### 回归
- it_v158 第 6 项断言更新为新语义（stop 不修改 HOLD_OFF、DESIRED=0、STOP_REASON=manual）。
- 全部 10 组回归 harness 通过（170 项断言）。

## v1.5.11（2026-09-18）

### P0 修复
- 迁移状态不再依赖版本号比较：改为独立迁移标记（.migrated/v1_5_2、v1_5_10），每个迁移只执行一次，服务重启不再反复清空流量统计。
- 今日/本月/近11天流量展示单位修正：后端已按字节返回，前端按字节换算（不再把 1MB 显示成 1TB）。
- 套餐/限额可调小或关闭：用户明确提交的值直接保存，不再取较大值；旧 DATA_LIMIT_MB 合并只在 1.5.10 迁移时执行一次。

### P1 修复
- 账期起始日 29–31 日跨月修正：当月/上月按各自真实天数独立截断，纯 shell 计算，不依赖 date -d。
- 工作日/周末跨午夜计划收尾修正：昨天存在跨午夜窗口且已过结束时间（如周五23:00–周六07:00）会正常关闭。
- 配置写锁覆盖“加锁→读→改→写→解锁”全过程，并发保存不再互相覆盖字段。
- 所有保存操作检查写入结果，磁盘满/锁失败时返回 ok:false，不再误报成功。
- 热点启动后尽力核验实际 SSID/安全/频段/信道（取不到明确值时显示“无法核验”，不误判失败）。

### P2 / UI
- SoftAP 状态缓存 15 秒：状态接口每 5 秒轮询不再重复执行两次 dumpsys wifi。
- 短信完整正文需后台密码二次验证（full=1&pw），页面提供“查看完整正文”按钮。
- 诊断页 Root/CSRF 状态改为真实检测结果（不再写死“正常”）。
- 在线设备数直接用后端 activeClientCount（含 PROBE），不再前端重算漏统计。
- 低电量状态补充中文映射（提醒已进入发送队列/未配置可用通知渠道）。
- 信号字段改名“频点编号（EARFCN/NRARFCN）”，不再误称 Band。
## v1.5.10（2026-09-18）
### 123 项问题清单（编号 24–146）全部落地
- P0-24~27 账期与限额：超限按账期 PLAN_PERIOD_BYTES 判断；100% 提醒与"限额用尽"合并为一次事件；
  80/90/100% 分级提醒统一受 NOTIFY_LIMIT 开关控制；重置流量同时清除设备累计、客户端快照、账期基线与提醒标记。
- P0-28~33 流量口径：账期原始记录保留至少 62 天（daily 按字节 tail -n 62）；日流量按字节保存不再截断；
  套餐与限额合并为唯一字段 DATA_PLAN_MB（DATA_LIMIT_MB 导入时升级迁移，避免新旧口径混用）；
  状态接口返回真实 limitAction；纯上行设备不再漏计（read_all_stats 遍历 rx/tx 键并集）。
- P1-34~41 统计细节：首次启用前流量明确"从启用时开始统计"；跨日约 15 秒误差可接受并说明；
  统计链被系统清空时记录原因和时间；接口变化时清理旧 FORWARD 跳转（usage_iface 记录）；
  usage 输出改为字节，前端统一 MB/GB/TB 换算。
- P0-42~51 设备管理：历史设备路径统一 KNOWN_MACS；"禁止上网"只 DROP FORWARD 不再阻断管理页；
  黑名单规则验证真实添加、循环删除至无残留；历史在线标记用活跃邻居状态；
  限速增加 1:30 默认类并验证 tc 规则与匹配包数；MAC/IP 映射变化时刷新限速规则。
- P1-52~63 通知/短信可靠性：通知队列按到期时间取文件（修复队头死循环与阻塞）；
  短信队列 4 字段双渠道独立重试（pp/dt 分开、失败渠道单独重试）；白名单逐项 trim；
  短信正文按 `_id:address:date:body` 投影解析不再被 `, date=` 截断；
  通知健康文件原子锁 + 错误内容清洗；钉钉签名探测 sha256sum/xxd/base64；
  测试通知防重复点击；短信开关开启但无渠道时明确警告；低电量锁存区分已入队/已发送/最终失败。
- P0-64~79 配置与升级：save_config 保留 PORT80_MIGRATED/MIGRATE_REMOVED 迁移标记（不再重复清理）；
  迁移键分别处理；DDNSTO 只杀本模块记录的 PID；导入配置跨字段校验（频段×信道）+ valid_channel 严格校验；
  DATA_PLAN_DAY/DATA_LIMIT_ACTION 非法值列入无效字段；导入明确为"合并导入"；
  配置写入统一 mkdir 锁串行化、mv 失败返回错误保留旧配置；卸载清理 mifi_up/mifi_dn 链与限速 qdisc；
  默认配置补全全部当前字段；安装页版本从 module.prop 动态读取。
- P1-80~92 状态/安全：信号接口 60 秒缓存 + dumpsys 落临时文件；状态接口只读（防火墙维护移入主循环）；
  诊断页真实检测 Root/命令能力/CSRF（csrfOk）；NAT 检测校验热点源网段、出口接口与计数；
  页面锁定改为会话令牌语义并暂停轮询；记住会话不保存密码本身；
  CSRF 提示明确风险；短信查看默认脱敏（full=1 才返回正文）。
- UI 93~146：.hint 选择器修复；分页/导航说明；顶部两行布局、防闪白（head 提前读主题+跟随系统）；
  操作结果回填后端实际值；Toast aria+错误卡片；极窄屏单列；设备按钮折叠"更多/收起"；
  历史设备删除/清空；页面内限速/备注弹窗；导入前差异预览；改密码后倒计时重载；
  账期行拆两行；危险操作集中；配置最后保存时间；:focus-visible 与按钮加载态等 54 项。
### 前端
- index.html 两轮共 33 处 JS/HTML/CSS 修改，node --check 与 HTML 标签闭合校验通过。
### 回归
- harness 10 组脚本共 168 项断言全部通过（含单独运行的 it_notify18 通知队列专项）。
### 遗留（待真机验证）
- cmd wifi / dumpsys / 信号字段解析、wlan2 接口、SELinux、tc/iptables 内核能力需小米 14 真机确认。

## v1.5.7（2026-09-18）
### UFI-TOOLS 借鉴五项（用户确认范围）
- 通知通道健康检测：notifyHealth 面板展示 PushPlus/钉钉/短信转发 配置状态、脱敏凭据、
  最近发送/成功时间、连续失败次数与失败原因；写入 notify_health（CH|last_send|last_ok|err|fails）。
- 流量账期管理：DATA_PLAN_MB 套餐总量与 DATA_LIMIT_MB 限额合并为单一套餐口径（plan_total_mb，
  取非零较大值，0=不限）；账期起始日 DATA_PLAN_DAY（1–31，每月 N 日滚账，含跨月判断）；
  使用率分级提醒 80%/90%/100%（plan_th_mark 跨期自动重置）；超限动作 DATA_LIMIT_ACTION=stop/notify。
- 只读信号面板：status.cgi 新增 signal{network,operator,sim,band,pci,rsrp,rsrq,sinr,level}；
  get_signal_info 依次尝试 dumpsys telephony.registry / dumpsys phone / getprop，取不到字段前端隐藏。
- 客户端历史信息：client_stats（MAC|first|last|online）累计首见/最近上线/在线秒数，
  在线设备与历史设备行展示；服务循环按周期累加在线时长。
- 自动化冲突检测 + 统一诊断：auto 状态含 desired/keepalive/holdOff/idleMin/sched/stopReason；
  页面展示策略优先级（流量超限>低电量>定时>空闲>保活，策略关闭后保活不拉起）；
  诊断面板改为能力检测表（renderDiagTable：Root/热点接口/管理地址/期望状态/转发/NAT/Web/CSRF/SELinux/在线客户端/FORWARD/日志）。
- 修复：DATE_CMD 未定义导致账期/队列时间戳在真机失效；status stopReason 被无条件清空。
## v1.5.6（2026-09-18）
### 功能精简（按用户确认清单移除 8 项）
- 移除：网页终端、DDNSTO 远程控制、普通 Wi-Fi 开关、80 端口转发、本机 IP 列表、
  配置预设、热点启停通知、热点二维码。
- 完整清理：lib/common.sh（相关函数/变量/配置字段）、service.sh（自启/通知/端口应用逻辑）、
  control.cgi（对应 action 与白名单）、status.cgi（wifi/ips/port80/notify.hotspot 字段）、
  index.html（HTML/CSS/JS 与内联二维码库）、README。
- 一次性迁移：新增 migrate_removed_once（仅执行一次）——删除旧版 DDNSTO 目录与进程、
  网页终端工作目录文件、热点启停通知状态文件（ap_state），并从 config 清理已删字段
  （PORT80/NOTIFY_HOTSPOT/DDNSTO_TOKEN_B64/DDNSTO_BOOT），保留 PORT80_MIGRATED 标记。
- 兼容：导入旧版导出配置时自动忽略已删除字段（ALLOWED 白名单已同步），不报错。
- 保留核心：热点开关与参数、定时/保活/空闲关闭、设备管理（在线/黑名单/备注/限速）、
  流量统计/限额/套餐/MB-GB-TB 单位、通知（新设备/流量超限/低电量）、
  PushPlus/钉钉/短信转发、后台安全、日志/诊断/模块重启。

## v1.5.5（2026-09-18）
- 修复：流量限额缺失保存按钮（saveDataLimit 已定义但从未被调用）→ 限额表单补"保存"按钮
- 修复：切换限额/套餐单位时换算错误（旧代码用新单位解释旧值，1GB 切 TB 会变 1TB）→ 先按旧单位转 MB 再按新单位显示
- 修复：横向表单被 .primary{width:100%} 挤压（数字输入框窄条、按钮占满整行、测试提醒换行）→ 新增 .inline-form 布局，手机端自动换行
- 修复：配置加载三个回归——WPA2/WPA3 混合（wpa3_transition）重启后回退 WPA2；定时模式 weekday/weekend 重启后回退 daily；黑名单按逗号拆分导致整串被丢弃（统一回空格分隔）
- 修复：低电量关闭后页面残留旧状态 → 关闭时写 disabled 快照；日志文案改为"已进入发送队列"（入队≠发送成功）
- 功能：手机套餐流量支持 MB/GB/TB 单位选择（与限额/显示单位统一换算）
- 口径：套餐文案修正为"统计热点客户端转发流量，不含手机自身"；"暂无数据"细分文案→"等待首次流量统计"（区分 0 流量与未初始化）
- 安全：load_config 彻底去除 source，配置逐行白名单解析 + 全字段校验（P0-1）
- 并发：通知/短信队列改为"一消息一文件"目录式 + mkdir 原子锁，busy 误杀/丢消息/并发重复全部消除（P0-2）
- 通知队列统一走 b64url_decode，中文标题正文无损往返
- 短信重试改为 1/5/15 分钟退避、共尝试 4 次；状态拆分"待发送/重试中"两条计数
- 实时速度按真实采样时间差计算（B/s），图上直接显示当前下行/上行速率
- 备注长度口径统一：24 字符（约 72 字节），前后端一致校验
- UI：定时保存按钮移回卡片内；顶部改 Grid 两行（去掉负边距挤压）；接口异常只禁用控制按钮、保留日志/诊断/复制等只读操作；热点按钮三态（运行/正在开启/已关闭）
# CHANGELOG — Xiaomi14_MiFi_Web

## v1.5.4（已交付）

### 修复（P0-1）
- **切换频段时信道校验误用旧频段**：valid_channel() 原为读取全局 `${BAND:-2}` 的单参数函数，热点保存流程先校验信道、后赋值 NEW_BAND，导致"当前 2.4G 保存 5G + 信道 36"被旧频段判定为非法、无法从 2.4G 切到 5G 指定信道（反向同理）。
  已改为 `valid_channel <band> <channel>` 双参数纯函数（channel=0 自动信道任何频段合法；自动频段 + 手动信道拒绝；非数字信道拒绝），并同步全部 4 个调用点：
  - start（热点保存/启动）：`valid_channel "$NEW_BAND" "$NEW_CHANNEL"`
  - import_config（配置导入）：`valid_channel "$BAND" "$CHANNEL"`
  - set_settings（仅改信道，基于当前已保存频段）：`valid_channel "$BAND" "$NEW_CHANNEL"`
  - profile_apply（应用预设）：`valid_channel "$BAND" "$CHANNEL"`
  集成验证（Mac harness 实跑 control.cgi，CSRF+QUERY_STRING 模拟真实请求）：当前 2.4G → 5G/36 通过校验；5G/6、2.4G/149、any/36 均被正确拒绝。

### 新增（动态设备信息）
- **顶部设备信息动态读取**：status.cgi 通过 read_device_info()（common.sh）读取 ro.product.marketname → ro.product.model → ro.product.device 作为机型，ro.mi.os.version.name + ro.mi.os.version + Android 版本作为系统版本，输出 `deviceModel` / `osVersion` 字段；前端顶部由写死的"小米14 · HyperOS 3"改为动态显示（`设备型号 · 系统版本 · 模块版本`），属性缺失时显示"未知设备"。换机安装无需改页面。

### 修复（v1.5.3 复查批次，确定 Bug + 稳定性 + UI）
- **页面版本动态化**：status.cgi 读 module.prop 的 version 输出 `"version"` 字段，前端 verBadge 动态填充（原页面硬编码 v1.5.2，与实际包版本脱节）。
- **成功提示 30 秒隐藏生效**：改为按后端 operation.time 计算 age（原实现每次轮询 clearTimeout 重置 timer，30s 永远不触发）；working 超过 120 秒自动追加"可能已超时"提示。
- **80 端口旧规则只清理一次**：新增 migrate_port80_once()，升级后首次运行清理 v1.5.2 及更早的无 comment 残留规则并写入 PORT80_MIGRATED 标记；clear_port80() 只删本模块带 comment 的精确规则，不再持续扫删其他模块同目标规则。
- **NAT 检测排除固定管理别名**：新增 get_native_hotspot_ip()（排除 STABLE_IP 别名取热点真实网关）、get_hotspot_subnet()（优先内核 route scope link 含真实掩码，回退 /24 推导，再回退固定网段）；check_tethering 与 status.cgi 的 nativeIp 均改用原生地址。
- **NAT 网段固定字符串匹配**：原 `grep -cE "$AP_SUBNET|$iface"` 将网段点号当正则元字符；改为 `grep -Fc` 分别精确计数后相加。
- **HyperOS NAT 共享误报修复（真机验证）**：小米14 的 MASQUERADE 规则只按出口接口匹配（`-o wlan0` / `-o miw_oem0`），不含热点子网/接口名，导致"共享条件未完全确认"误报。新增推断分支：MASQUERADE 未命中热点时，若 NAT 规则存在 且 FORWARD 链已建立热点接口转发路径，判定共享 NAT 就绪；真机 hotspotNat 由 0 修正为 1，页面恢复"✅ 已观测到客户端转发流量"（实测转发包 10 万+）。
- **通知队列化（不丢事件）**：notify_all_async 先入队 notify.queue 再触发后台 worker；busy 仅是并发锁（30s 超时自愈），worker 忙碌时新事件入队等待而非丢弃；worker 发送失败记录日志并丢弃该条（避免失败事件无限重试堵队列）；先删后发，worker 异常中断不无限重发。
- **短信队列化 + 重试上限**：check_sms_forward 检测阶段只负责"过滤 + 推进游标 + 入队 sms.queue"，推送由独立 worker 按 ID 顺序处理；失败按 1/5/15 分钟退避，最多 3 次后放弃并推进（不再无限重试、不再阻塞主守护循环）；status.cgi 输出 smsPending 待重试数，前端短信卡片显示。
- **非法设置明确报错**：set_settings 对已提供的 idleShutdown/channel/maxClients/schedOn/schedOff/schedOnWd/schedOffWd/schedOnWe/schedOffWe/dataLimitMb 严格校验，非法值直接返回明确错误（原静默忽略且返回"设置已保存"）。
- **流量限额上限**：新增 valid_data_limit()（0–10,000,000 MB），set_settings 与 import_config 均接入。
- **配置导入彻底取消 source**：import_config 与 profile_apply 由 `. "$TMP_CFG"` 改为逐行白名单 case 赋值（未知键直接跳过），上传内容永不作为脚本执行；ALLOWED 白名单补充 PORT80_MIGRATED。
- **轻量开启热点**：control.cgi 新增 `start_softap` action（用已保存配置直接启动、不修改热点参数；手动开启即解除"手动保持关闭"），前端快速控制增加动态"开启热点/关闭热点"按钮（按 running 状态切换文案与样式）。
- **网页终端二次验证**：打开终端需先输入后台管理密码（auth_check 校验），通过后临时启用 10 分钟自动过期；再次打开验证有效期。
- **系统状态折叠**：普通 Wi‑Fi/内核转发/NAT 规则/运营商/信号/蜂窝流量/实时速度/内存/存储/负载/温度/运行时长收进"技术状态与高级信息"折叠区；网络共享状态保留在外。
- **流量趋势改实时速度**：traffic.push 改为相邻采样差值（下/上行速率），标签改"热点实时速度"。
- **UI 细节**：顶部改两行布局（标题+版本 | 主题+状态徽标 | 更新时间独立一行，去掉负边距挤压）；more-actions 增加独立样式（背景/内边距）与 [hidden] 声明、多设备展开互斥；短信关键词/白名单标签文案修正（"留空=不修改已保存值"，消除与"留空=全部"的歧义）；在线设备标注"（邻居表估算）"；被禁止上网设备行加"· 已禁止上网"标注；普通 Wi‑Fi 共存文案改为"实验性功能…取决于当前系统与驱动"；接口连续失败 3 次后页面卡片置灰（.stale 遮罩）并禁用点击，恢复后自动解除；短信待重试提示（⚠ 待重试短信 N 条）。

## v1.5.3（已发布）

### 修复（v1.5.2 复查批次，P0/P1/P2 + UI）
- **清除通知配置按钮可用**：clear_notify 改用 `FIELD=$(get_param field)`（原实现读取未定义的 $QUERY 且 BusyBox sed BRE 无捕获组，点击一直"未知字段"）。
- **记住密码二次编码**：手动解锁成功后直接保存已 Base64URL 编码的密码（原实现再编码一次导致自动解锁永远失败）；修改后台密码后自动清除本地记住值。
- **设备备注可清空**：set_note 允许留空清除（原 valid_b64url 拒绝空值，备注无法删除）。
- **短信游标逻辑**：关键词/白名单过滤的短信即时推进游标（不再每 15s 重复扫描）；应转发但全部渠道失败的短信不推进且立即停止本轮（原实现会被后续成功短信跨过导致丢失）。
- **notify.busy 残留恢复**：busy 文件超过 30 秒视为上次发送异常中断，自动清理并继续本次；子进程 trap EXIT 保证发送完成必删；服务启动时清理残留；丢弃事件写日志。
- **NAT 动态网段**：check_tethering 用热点接口实际地址推导 /24 网段匹配（原固定 192.168.43.0/24，本 ROM 热点网关是 10.x 时误判无 NAT），接口无地址时回退固定网段。
- **80 端口转发精确删除**：创建/删除均优先带 `-m comment --comment xiaomi14_mifi_web`；删除时先按 comment 精确匹配，再清旧版无 comment 的残留规则，不误删其他模块规则。
- **客户端流量持久化顺序**：persist_client_usage 移到 cleanup_stats_rules 之前（原顺序导致设备刚离线时最后一个周期流量漏记）。
- **配置导入白名单**：import_config 只允许明确字段键（SSID_B64/PASS_B64/…），不再放行任意大写变量。
- **输入范围校验**：valid_hhmm（00–23/00–59）、valid_channel（2.4G:1/3/6/9/11/13，5G:36/40/44/48/149/153/157/161/165，自动仅0）、valid_max_clients（0–32）、valid_idle（0 或 1–600）接入保存/导入/预设全部入口。

### UI / 交互
- 通知设置改为显式「保存通知设置」按钮（移除全部 onchange 自动保存，防止误触提交与半套配置）。
- 定时设置改为显式「保存定时设置」按钮；定时模式切换保留即时联动显示。
- 已连接设备按钮折叠为 [限速↓] [更多]（更多内：禁止上网/解除、临时断网、备注），手机端列表不再拥挤。
- 网页终端移入「危险操作」分组（红色标识），与常用工具分离。
- 状态栏新增最后更新时间；接口异常时显示「⚠ 接口异常 · 上次更新 HH:MM:SS」。
- 操作成功提示带时间戳且 30 秒自动隐藏；失败提示保留。
- 清空日志增加确认对话框。
- 二维码文案与「显示当前密码」功能统一（说明可先查看密码再输入生成）。
- 热点 NAT 状态标签改为「热点网段，动态检测」。

## v1.5.2（已发布）

### 修复（P0/P1）
- **control.cgi 语法错误（原版 v1.5.0 遗留）**：sms_list 分支在 `$(...)` 命令替换内使用 `while + case`，
  case 的 `)` 会干扰 `$()` 的括号配对，导致整文件语法错误（sh -n 必挂，页面 SMS 列表功能不可用）。
  已重写：循环移出命令替换，逐行写入临时文件，最后用 `paste -sd ','` 合并为 JSON 数组。
- **在线设备计数口径**：`clientCount` 原为客户端列表长度，STALE/FAILED 设备也被计入"在线"。
  现仅统计 REACHABLE / DELAY / ARP 三种在线状态；STALE 设备仍显示在列表并标记"待机"。

### v1.5.2 迭代中的既有修复（回顾）
- 热点状态分层：服务运行 / 接口 / 转发 / NAT 精确匹配（192.168.43.0/24），"客户端应可正常上网"需观测到转发包。
- 普通 Wi‑Fi 状态行（wifiInfo/wifiQuick）：已开启·已连接 SSID / 未连接上游 / 未开启。
- 流量口径拆分：页面文案改为"已用流量（累计，仅统计客户端转发流量）"；今日/本月热点流量带 valid 标记，无数据时显示"暂无数据"。
- 客户端累计流量按 MAC 持久化（IP 变化/离线不丢失）。
- 限速按 IP 变化自动重建 tc 规则（RATE_IPS_FILE 快照）。
- count_online_clients 排除 STALE/FAILED；设备徽标区分 在线/待机/离线。
- accumulate_usage 处理 iptables 链归零（保持累计，不产生负数跳变）。
- 设备按钮文案：禁止上网（iptables MAC DROP）/ 解除禁止上网 / 临时断网（15s）/ 限速↓。
- check_version_upgrade：v1.5.2 首次运行清理旧版流量统计残留（usage 快照/traffic_base），仅一次。

### 自测记录（2026-09-18, macOS 模拟环境）
- 单元测试（zsh mock + 真实 common.sh 函数）22/22 通过：count_online_clients 分级、accumulate_usage 增量与链归零、
  persist_client_usage（MAC 基线/增量/IP 变化/离线保留）、apply_rate_limits（快照/不重建/重建）、
  get_wifi_status 缓存解码、check_tethering 精确 NAT、check_version_upgrade 清理。
- 全部 shell 文件 sh -n 语法通过（service.sh/action.sh/customize.sh/uninstall.sh/lib/common.sh/4 个 cgi）。
- 前端 headless Edge + mock status 渲染验证：wifi 状态行、热点分层、NAT 命中、流量文案、设备按钮、
  clientCount 在线过滤、STALE"待机"徽标。
- sms_list 冒烟：解析/无效行过滤/`|` 保留/逗号合并正确。

### 遗留（待真机验证，HyperOS 相关）
- cmd wifi / dumpsys 输出解析、wlan2 接口名、SELinux 对 su 调用限制需在小米 14 真机确认。
- tc / iptables 对 HyperOS 内核的可用性未真机验证。