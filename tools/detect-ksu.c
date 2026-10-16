// detect-ksu.c -- KernelSU 存在性检测 PoC
//
// 用途：验证内核侧"驱动 fd 安装通路 uid 门禁"补丁是否生效（对应审计报告 B1）。
//
// 原理：未加固的 KernelSU 在 reboot(0xDEADBEEF, 0xCAFEBABE, ...) 的 kprobe pre-handler
//       （kernel/supercall/supercall.c）里只比对魔数，就通过 task_work 把驱动 fd 写回
//       用户态指针，完全不检查调用者 uid。于是任意普通 App 可以：
//         1) 判断 KernelSU 是否在跑；
//         2) 通过 ioctl KSU_IOCTL_GET_INFO 读出内核版本号、构建标志与 UAPI 版本；
//         3) 通过 /proc/self/fd/<n> 读到 `anon_inode:[ksu_driver]`，暴露驱动名。
//       打上补丁后，未授权 uid 走这条路径拿不到 fd，也读不到任何信息。
//
// 编译（NDK）：
//   aarch64-linux-android24-clang -O2 -D__ANDROID__ detect-ksu.c -o detect-ksu
// 运行：
//   adb push detect-ksu /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/detect-ksu
//   adb shell /data/local/tmp/detect-ksu
// 退出码：0 = 未检测到；1 = 检测到（说明门禁缺失）
//
// 说明：本文件只使用上游 uapi/supercall.h 中的公开常量与结构体定义，不包含上游实现代码。

#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

// ---- 来自 uapi/supercall.h 的公开定义（逐字对应） ----
#define KSU_INSTALL_MAGIC1 0xDEADBEEF
#define KSU_INSTALL_MAGIC2 0xCAFEBABE

struct ksu_get_info_cmd {
    uint32_t version;      /* KERNEL_SU_VERSION */
    uint32_t flags;        /* KSU_GET_INFO_FLAG_* */
    uint32_t features;     /* max feature ID */
    uint32_t uapi_version; /* KERNEL_SU_UAPI_VERSION */
};

#define KSU_IOCTL_GET_INFO _IOR('K', 2, struct ksu_get_info_cmd)

#define KSU_GET_INFO_FLAG_LKM       (1U << 0)
#define KSU_GET_INFO_FLAG_MANAGER   (1U << 1)
#define KSU_GET_INFO_FLAG_LATE_LOAD (1U << 2)
#define KSU_GET_INFO_FLAG_PR_BUILD  (1U << 3)
#define KSU_GET_INFO_FLAG_BUNDLED   (1U << 4)

static void decode_flags(uint32_t f)
{
    printf("        flags=0x%08x", f);
    if (f & KSU_GET_INFO_FLAG_LKM)       printf(" LKM");
    if (f & KSU_GET_INFO_FLAG_MANAGER)   printf(" MANAGER");
    if (f & KSU_GET_INFO_FLAG_LATE_LOAD) printf(" LATE_LOAD");
    if (f & KSU_GET_INFO_FLAG_PR_BUILD)  printf(" PR_BUILD");
    if (f & KSU_GET_INFO_FLAG_BUNDLED)   printf(" BUNDLED");
    printf("\n");
}

int main(void)
{
    int fd = -1;
    long ret;
    int err;

    printf("detect-ksu: uid=%d euid=%d pid=%d\n", (int)getuid(), (int)geteuid(), (int)getpid());

    // ---- 探针 1：reboot 魔数安装驱动 fd ----
    errno = 0;
    ret = syscall(SYS_reboot, (long)KSU_INSTALL_MAGIC1, (long)KSU_INSTALL_MAGIC2, 0L, &fd);
    err = errno;
    printf("[1] reboot(0x%08x, 0x%08x, 0, &fd): ret=%ld errno=%d (%s) fd=%d\n",
           KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, ret, err, strerror(err), fd);

    if (fd < 0) {
        printf("    -> 没有拿到驱动 fd：本路径检测不到 KernelSU（已加固或未运行）\n");
        return 0;
    }

    printf("    -> KERNELSU PRESENT：未授权 uid 也能拿到驱动 fd\n");

    // ---- 探针 2：anon inode 名（B7） ----
    {
        char link[128];
        char proc[64];
        ssize_t n;
        snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);
        n = readlink(proc, link, sizeof(link) - 1);
        if (n > 0) {
            link[n] = '\0';
            printf("[2] %s -> %s\n", proc, link);
            if (strstr(link, "ksu"))
                printf("    -> fd 名泄漏内核内部标识（应为中性名或不可读）\n");
        }
    }

    // ---- 探针 3：GET_INFO（补丁后应返回 EPERM） ----
    {
        struct ksu_get_info_cmd info;
        memset(&info, 0, sizeof(info));
        errno = 0;
        if (ioctl(fd, KSU_IOCTL_GET_INFO, &info) == 0) {
            printf("[3] KSU_IOCTL_GET_INFO 成功：\n");
            printf("        version=%u uapi_version=%u features=%u\n",
                   info.version, info.uapi_version, info.features);
            decode_flags(info.flags);
            printf("    -> 完整版本信息对未授权进程可见\n");
        } else {
            printf("[3] KSU_IOCTL_GET_INFO 被拒绝：errno=%d (%s) <- 权限主键生效\n",
                   errno, strerror(errno));
        }
    }

    close(fd);
    printf("结果：检测到 KernelSU（细节见上）\n");
    return 1;
}
