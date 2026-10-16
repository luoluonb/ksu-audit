#!/system/bin/sh
# KernelSU 管理器模块页的「操作」按钮入口：立即跑一遍自检并把报告打到界面

MODDIR=${0%/*}

chmod 755 "$MODDIR/tools" 2>/dev/null
chmod 755 "$MODDIR"/tools/* 2>/dev/null
chmod 755 "$MODDIR"/*.sh 2>/dev/null

sh "$MODDIR/tools/run-check.sh"
echo ""
echo "完整报告已保存到：/data/adb/ksu_check/report.txt"
