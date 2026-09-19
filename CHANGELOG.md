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
