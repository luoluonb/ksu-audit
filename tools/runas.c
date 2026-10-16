// runas.c -- 以指定 uid/gid 运行命令
//
// 为什么需要它：KernelSU 模块的脚本（post-fs-data.sh / service.sh / action.sh）是以
// **root** 身份运行的，而"能不能检测到 KernelSU"这个问题只有在**未授权身份**下问才有意义
// —— root 本来就能看到一切。这个小工具把权限降到指定 uid 再 exec，用于在设备上从
// root 侧复现普通 App / shell 视角的检测结果。
//
// 用法：
//   runas 2000 /data/adb/ksu_check/verify-device.sh      # 以 shell uid 运行
//   runas 10000 /data/adb/ksu_check/detect-ksu           # 以 app uid 运行（实测换成某个应用 uid）
//
// 编译（NDK）：
//   aarch64-linux-android24-clang -O2 -static -s runas.c -o runas-arm64

#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <uid> <cmd> [args...]\n", argv[0]);
        return 2;
    }

    uid_t uid = (uid_t)strtoul(argv[1], NULL, 10);
    gid_t gid = (gid_t)uid;

    // 只有 root（或带 CAP_SETUID/CAP_SETGID 的进程）能走到这里；失败一般说明权限不够
    if (setgroups(0, NULL) != 0 && errno != EPERM) {
        perror("setgroups");
    }
    if (setresgid(gid, gid, gid) != 0) {
        perror("setresgid");
        return 1;
    }
    if (setresuid(uid, uid, uid) != 0) {
        perror("setresuid");
        return 1;
    }

    execvp(argv[2], &argv[2]);
    perror("execvp");
    return 127;
}
