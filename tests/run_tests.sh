#!/bin/sh
# ============================================================
# 自动化回归测试骨架（v1.7.4）
#
# 用法：
#   sh tests/run_tests.sh          # 本机开发环境（macOS/Linux）
#
# 说明：
#   - source lib/common.sh 后对核心纯函数做断言，不触碰任何真实设备状态；
#   - 系统路径（BB/IPT 等）自动回退到测试机 PATH 中的命令；
#   - 新增用例：在下方按 assert_eq / ok 格式追加即可。
#   - 发布前建议在真机 KernelSU 环境跑一次（sh tests/run_tests.sh）。
# ============================================================
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD

PASS=0; FAIL=0; FAILED=""
assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); FAILED="$FAILED\n  x $1 (期望[$2] 实际[$3])"; echo "  FAIL  $1 (期望[$2] 实际[$3])"; fi
}
ok() { # desc rc
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); FAILED="$FAILED\n  x $1 (rc=$2)"; echo "  FAIL  $1 (rc=$2)"; fi
}

echo "== 加载 lib/common.sh =="
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh" 2>/dev/null || { echo "source 失败：请确认在仓库根目录下运行"; exit 1; }
# 测试机 mock：macOS/Linux 无 /system/bin/*，
# 用 /usr/bin/env 作为命令前缀（"$BB" cmd → env cmd，走 PATH）
BB=/usr/bin/env

echo "== MAC 校验 =="
valid_mac 'AA:BB:CC:DD:EE:FF'; ok 'valid_mac 标准大写格式' $?
valid_mac 'aa:bb:cc:dd:ee:ff'; ok 'valid_mac 小写格式' $?
! valid_mac 'AA-BB-CC-DD-EE-FF'; ok 'valid_mac 连字符格式拒绝' $?
! valid_mac 'AA:BB:CC:DD:EE'; ok 'valid_mac 短格式拒绝' $?
! valid_mac 'GG:BB:CC:DD:EE:FF'; ok 'valid_mac 非法字符拒绝' $?
! valid_mac ''; ok 'valid_mac 空串拒绝' $?

echo "== 时间格式 =="
valid_hhmm '0000'; ok 'valid_hhmm 0000 接受' $?
valid_hhmm '2359'; ok 'valid_hhmm 2359 接受' $?
! valid_hhmm '2500'; ok 'valid_hhmm 2500 拒绝' $?
! valid_hhmm '2360'; ok 'valid_hhmm 2360 拒绝' $?
! valid_hhmm '12:00'; ok 'valid_hhmm 含冒号拒绝' $?
! valid_hhmm '700'; ok 'valid_hhmm 三位数拒绝' $?

echo "== base64url 往返 =="
E=$(b64url_encode '热点测试 Hello 123')
D=$(b64url_decode "$E")
assert_eq 'b64url 中文+英文往返' '热点测试 Hello 123' "$D"
assert_eq 'b64url 不含 =/+ 字符' 0 "$(printf '%s' "$E" | tr -d '=' | grep -c '+')"

echo "== 厂商识别 =="
assert_eq 'mac_vendor Apple' 'Apple' "$(mac_vendor 'F0:18:98:12:34:56')"
assert_eq 'mac_vendor Xiaomi' 'Xiaomi' "$(mac_vendor 'F4:8E:38:12:34:56')"
assert_eq 'mac_vendor 未知厂商为空' '' "$(mac_vendor '00:00:00:00:00:01')"

echo
echo "== 结果：$PASS 通过 / $FAIL 失败 =="
if [ "$FAIL" -gt 0 ]; then
  printf '%b\n' "$FAILED"
  exit 1
fi
echo "全部通过 ✓"
exit 0
