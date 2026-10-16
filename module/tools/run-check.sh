#!/system/bin/sh
# run-check.sh -- 自检主程序
#
# 设计要点：本脚本通常由 root 执行（模块的 service.sh / action.sh），
# 但"能不能被检测到"这个问题只有未授权身份问了才有意义，所以每一步都用
# 自带的 runas 把 uid 降到 2000(shell) 再执行。
#
# 报告：/data/adb/ksu_check/report.txt

BASE=$(dirname "$0")            # .../modules/<id>/tools
MODDIR=$(dirname "$BASE")       # .../modules/<id>
OUT=/data/adb/ksu_check
REPORT="$OUT/report.txt"

DETECT="$BASE/detect-ksu"
RUNAS="$BASE/runas"
VERIFY="$BASE/verify-device.sh"

TEST_UID="${TEST_UID:-2000}"    # 默认 shell；改成 10098 之类可测真实 App uid

mkdir -p "$OUT" 2>/dev/null
chmod 755 "$BASE" 2>/dev/null
chmod 755 "$DETECT" "$RUNAS" "$VERIFY" 2>/dev/null

# verify-device.sh 的第 1 项会找这个路径，这里替它准备好
if [ -x "$DETECT" ]; then
    cp -f "$DETECT" /data/local/tmp/detect-ksu 2>/dev/null
    chmod 755 /data/local/tmp/detect-ksu 2>/dev/null
fi

{
    echo "==================================================="
    echo " KernelSU 反检测自检报告"
    echo "==================================================="
    echo "时间     : $(date)"
    echo "内核     : $(uname -r)"
    echo "Android  : $(getprop ro.build.version.release) (SDK $(getprop ro.build.version.sdk))"
    echo "机型     : $(getprop ro.product.brand) $(getprop ro.product.model)"
    echo "模块版本 : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
    echo "测试身份 : uid $TEST_UID（未授权身份；root 视角的检查没有意义）"
    echo
    echo "说明：所有检查都以 uid $TEST_UID 运行。runas 只降 uid/gid、不改 SELinux 域，"
    echo "      因此按 uid 判定的检查（路径存在性、/proc 内容擦除）是准确的，"
    echo "      涉及 SELinux 域的判定仍建议用真实 App 或 adb shell 复测一次。"
    echo
} > "$REPORT"

section() {
    echo "" >> "$REPORT"
    echo "---- $1 ----" >> "$REPORT"
}

if [ ! -x "$RUNAS" ]; then
    echo "致命：缺少可执行文件 $RUNAS" >> "$REPORT"
    cat "$REPORT"
    exit 1
fi

section "[A] detect-ksu：驱动 fd 安装通路（B1）"
if [ -x "$DETECT" ]; then
    "$RUNAS" "$TEST_UID" "$DETECT" >> "$REPORT" 2>&1
    echo "exit=$?（0=未检测到 / 1=检测到）" >> "$REPORT"
else
    echo "跳过：缺少 $DETECT" >> "$REPORT"
fi

section "[B] verify-device.sh：路径存在性 / 符号擦除 / SELinux 策略 / 挂载 / 进程"
if [ -f "$VERIFY" ]; then
    "$RUNAS" "$TEST_UID" sh "$VERIFY" >> "$REPORT" 2>&1
else
    echo "跳过：缺少 $VERIFY" >> "$REPORT"
fi

section "[C] 反向验收（必须以 root 侧确认，隐藏不能把管理器自己搞坏）"
echo "下面 4 条需要你人工确认，脚本只能给出参考值：" >> "$REPORT"
echo "  1) 管理器能打开、显示工作中、能授权/取消授权 App" >> "$REPORT"
echo "  2) su 会话正常（允许名单里的 App 调 su 能拿到 root）" >> "$REPORT"
echo "  3) 模块能挂载 / umount / 卸载" >> "$REPORT"
echo "  4) root 侧仍能读写 /data/adb 与查看 /proc/kallsyms" >> "$REPORT"
echo "root 侧参考：" >> "$REPORT"
{
    echo "  /data/adb 可列目录 : $(ls -d /data/adb >/dev/null 2>&1 && echo yes || echo no)"
    echo "  /data/adb/ksud 存在: $([ -e /data/adb/ksud ] && echo yes || echo no)"
    echo "  内核符号可读      : $(grep -c ' ksu' /proc/kallsyms 2>/dev/null || echo 'n/a')"
} >> "$REPORT"

section "[D] 汇总"
LEAK=$(grep -c '^LEAK' "$REPORT" 2>/dev/null)
OKN=$(grep -c '^ok' "$REPORT" 2>/dev/null)
SKIPN=$(grep -c '^SKIP' "$REPORT" 2>/dev/null)
[ -z "$LEAK" ] && LEAK=0
[ -z "$OKN" ] && OKN=0
[ -z "$SKIPN" ] && SKIPN=0
echo "LEAK=$LEAK   ok=$OKN   SKIP=$SKIPN" >> "$REPORT"
if [ "$LEAK" -eq 0 ]; then
    echo "结论：在 uid $TEST_UID 视角下未发现可判定线索。" >> "$REPORT"
else
    echo "结论：仍有 $LEAK 处泄漏，见上面以 LEAK 开头的行。" >> "$REPORT"
fi
echo "" >> "$REPORT"
echo "对照基线：打补丁前 detect-ksu 会打出 fd=3 且 GET_INFO 成功；" >> "$REPORT"
echo "打上 patches/ksu-hide-and-perf.patch 之后必须变成 fd=-1。" >> "$REPORT"

cat "$REPORT"
[ "$LEAK" -eq 0 ]
