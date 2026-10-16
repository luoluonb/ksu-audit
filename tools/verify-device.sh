#!/system/bin/sh
# verify-device.sh -- KernelSU 隐藏效果设备端自测清单
#
# 用法：以**未授权**身份运行（普通 App 的 shell 环境，或 adb shell / uid 2000）：
#   adb push verify-device.sh /data/local/tmp/
#   adb shell sh /data/local/tmp/verify-device.sh
#
# 判读：每一行输出以 ok / LEAK / SKIP / INFO 开头。
#   ok    = 期望的"看不到"
#   LEAK  = 该路径仍能判定 KernelSU 存在
#   SKIP  = 当前身份无权限读取，需换身份或用 detect-ksu（编译产物）复核
#

UID_NOW=$(id -u 2>/dev/null || echo "?")
LEAK=0
SKIP=0

say()  { printf '%-5s %s\n' "$1" "$2"; }
leak() { LEAK=$((LEAK+1)); say LEAK "$1"; }
ok()   { say ok   "$1"; }
skip() { SKIP=$((SKIP+1)); say SKIP "$1"; }
info() { say INFO "$1"; }

echo "== verify-device.sh  uid=$UID_NOW =="

# ---- 1. 驱动 fd 通路（B1）--------------------------------------------------
if [ -x /data/local/tmp/detect-ksu ]; then
    /data/local/tmp/detect-ksu >/dev/null 2>&1
    if [ $? -eq 0 ]; then ok "driver fd path: detect-ksu 未检测到 KernelSU"
    else leak "driver fd path: detect-ksu 判定 KernelSU 存在（B1 未修）"; fi
else
    info "未找到 /data/local/tmp/detect-ksu，跳过 B1（请用 tools/detect-ksu.c 编译后推送）"
    info "手工复核：syscall(SYS_reboot, 0xDEADBEEF, 0xCAFEBABE, 0, &fd) 后 fd 应为 -1"
fi

# ---- 2. 内核日志指纹（B2）--------------------------------------------------
if command -v dmesg >/dev/null 2>&1; then
    N=$(dmesg 2>/dev/null | grep -ci 'kernelsu\|ksu')
    if [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null; then
        leak "dmesg 命中 kernelsu/ksu 相关行：$N 行"
    elif dmesg >/dev/null 2>&1; then
        ok "dmesg 无 kernelsu/ksu 关键字"
    else
        skip "dmesg 不可读（dmesg_restrict）"
    fi
else
    skip "无 dmesg 命令"
fi

# ---- 3. 路径存在性（B4）----------------------------------------------------
check_path() {
    P="$1"
    ERR=$(stat -c '%n' "$P" 2>&1 >/dev/null)
    if [ -z "$ERR" ]; then
        leak "$P 可 stat（存在性泄漏）"
    else
        case "$ERR" in
            *"No such file"*)     ok   "$P -> ENOENT" ;;
            *"Permission denied"*) leak "$P -> EACCES（路径存在但被拒，可区分于 ENOENT）" ;;
            *)                    skip "$P -> $ERR" ;;
        esac
    fi
}
for p in /data/adb /data/adb/ksu /data/adb/ksud /data/adb/modules /metadata/ksu /debug_ramdisk/.ksu; do
    check_path "$p"
done

# ---- 4. 模块列表 / 内核符号（B3）-------------------------------------------
if [ -r /proc/modules ]; then
    if grep -qi 'kernelsu\|ksu' /proc/modules 2>/dev/null; then
        leak "/proc/modules 出现模块条目"
    else
        ok "/proc/modules 干净"
    fi
else
    skip "/proc/modules 不可读"
fi

if [ -r /proc/kallsyms ]; then
    N=$(grep -ci 'ksu_\|kernelsu' /proc/kallsyms 2>/dev/null || echo 0)
    if [ "$N" -gt 0 ]; then leak "/proc/kallsyms 命中 $N 个 ksu 符号名"
    else ok "/proc/kallsyms 无 ksu 符号名"; fi
else
    skip "/proc/kallsyms 不可读"
fi

if [ -d /sys/module ]; then
    if ls /sys/module 2>/dev/null | grep -qi 'kernelsu\|ksu'; then
        leak "/sys/module 出现 kernelsu 目录"
    else
        ok "/sys/module 无 kernelsu"
    fi
fi

# ---- 5. 内核配置 / 命令行（B6）---------------------------------------------
if [ -r /proc/config.gz ]; then
    if zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_KSU'; then
        leak "/proc/config.gz 含 CONFIG_KSU"
    else
        ok "/proc/config.gz 无 CONFIG_KSU"
    fi
else
    skip "/proc/config.gz 不存在或不可读（若内核未开 IKCONFIG_PROC 则天然安全）"
fi
if [ -r /proc/cmdline ]; then
    if tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -qi 'ksu\|kernelsu'; then
        leak "/proc/cmdline 含 ksu 参数"
    else
        ok "/proc/cmdline 干净"
    fi
fi

# ---- 6. SELinux 策略（B5）--------------------------------------------------
if [ -r /sys/fs/selinux/policy ]; then
    N=$(grep -a -c -E 'ksu|kernel_su' /sys/fs/selinux/policy 2>/dev/null || echo 0)
    if [ "$N" -gt 0 ]; then leak "SELinux 策略文本命中 ksu（$N 处）"
    else ok "SELinux 策略文本干净"; fi
else
    skip "/sys/fs/selinux/policy 不可读"
fi

# ---- 7. 挂载视图（B10）----------------------------------------------------
for f in /proc/mounts /proc/self/mountinfo; do
    [ -r "$f" ] || continue
    if grep -qi 'ksu\|modules' "$f" 2>/dev/null; then
        info "$f 含 ksu/modules 相关挂载点（对未 umount 的 uid 可见）"
    else
        ok "$f 无 KSU 相关挂载"
    fi
done

# ---- 8. 进程与 fd（B7/B8）--------------------------------------------------
if command -v ps >/dev/null 2>&1; then
    if ps -A 2>/dev/null | grep -i 'ksud\|kernelsu' >/dev/null; then
        leak "ps 输出命中 ksud/kernelsu 进程"
    else
        ok "ps 无 ksud/kernelsu"
    fi
fi
if ls -l /proc/self/fd 2>/dev/null | grep -qi 'ksu'; then
    leak "自身 fd 表出现 ksu 相关 anon inode"
else
    ok "自身 fd 表干净"
fi

# ---- 9. 已安装包（B9，需在 App 侧执行）-------------------------------------
if command -v pm >/dev/null 2>&1; then
    if pm list packages 2>/dev/null | grep -i 'kernelsu\|ksu' >/dev/null; then
        leak "已安装包名命中 kernelsu（应用侧 packageManager 枚举同样可见）"
    else
        ok "已安装包名无 kernelsu"
    fi
else
    info "无 pm 命令：请在 App 侧用 PackageManager 复核包名/签名"
fi

echo
echo "== 汇总：LEAK=$LEAK  SKIP=$SKIP =="
[ "$LEAK" -eq 0 ] && echo "结果：在本身份下未发现可判定线索" || echo "结果：仍有 $LEAK 处泄漏，见上面的 LEAK 行"
[ "$LEAK" -eq 0 ]
