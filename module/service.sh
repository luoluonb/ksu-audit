#!/system/bin/sh
# 开机后自动跑一次自检（不想要自动跑就删掉本文件）
# 报告：/data/adb/ksu_check/report.txt

MODDIR=${0%/*}

# 等系统起来，再等模块挂载/权限稳定
for i in $(seq 1 120); do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 2
done
sleep 15

chmod 755 "$MODDIR/tools" 2>/dev/null
chmod 755 "$MODDIR"/tools/* 2>/dev/null
chmod 755 "$MODDIR"/*.sh 2>/dev/null

sh "$MODDIR/tools/run-check.sh" >/dev/null 2>&1
