#!/system/bin/sh
# KernelSU / Magisk 模块安装脚本
#
# 不使用 ui_print / set_perm_recursive 这类安装器框架函数，改用纯 shell，
# 这样在不同版本的 ksud / Magisk 安装器下都不会因为缺函数而中断。

MODDIR_HINT="${MODPATH:-$MODDIR}"

echo "- KSU Hide Self-Test v1.0.0"
if [ -n "$MODDIR_HINT" ]; then
    chmod 755 "$MODDIR_HINT" 2>/dev/null
    chmod 755 "$MODDIR_HINT/tools" 2>/dev/null
    chmod 755 "$MODDIR_HINT"/tools/* 2>/dev/null
    chmod 755 "$MODDIR_HINT"/*.sh 2>/dev/null
    echo "- 工具已就位：$MODDIR_HINT/tools"
fi
echo "- 重启后自动跑一次；也可以直接回管理器模块页点「操作」立即跑"
echo "- 报告路径：/data/adb/ksu_check/report.txt"
