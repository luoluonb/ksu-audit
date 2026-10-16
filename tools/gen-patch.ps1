# gen-patch.ps1 -- 从新鲜的 KernelSU 源码重新生成 ksu-hide-and-perf.patch
#
# 用途：当上游 main 继续前进、仓库内的补丁上下文不再匹配时，用本脚本在本地重新生成。
# 它把下面的改动就地施加到源码的副本上，然后产出与提交基线无关的统一 diff（仅文本改动）。
#
# 用法：
#   git clone https://github.com/tiann/KernelSU.git
#   ./tools/gen-patch.ps1 -Source ./KernelSU -Out ./patches/ksu-hide-and-perf.patch
#
# 结果：脚本末尾会执行 `git apply --check` 自检，退出码 0 表示补丁可干净应用。

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out = 'ksu-hide-and-perf.patch',
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'

$source = (Resolve-Path $Source).Path
if (-not (Test-Path (Join-Path $source 'kernel/include/klog.h'))) {
    throw "不是 KernelSU 源码根目录（缺少 kernel/include/klog.h）：$source"
}
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ksupatch_' + [guid]::NewGuid().ToString('N')) }
$work    = $WorkDir
$workA   = Join-Path $work 'a'
$workB   = Join-Path $work 'b'
New-Item -ItemType Directory -Force -Path $workA, $workB | Out-Null

$files = @(
    'kernel/include/klog.h',
    'kernel/core/init.c',
    'kernel/hook/setuid_hook.c',
    'kernel/hook/tp_marker.c',
    'kernel/supercall/dispatch.c',
    'kernel/supercall/supercall.c',
    'kernel/runtime/ksud_integration.c'
)
foreach ($f in $files) {
    foreach ($w in @($workA, $workB)) {
        $t = Join-Path $w $f
        New-Item -ItemType Directory -Force -Path (Split-Path $t) | Out-Null
        Copy-Item (Join-Path $source $f) $t
    }
}

function Edit([string]$rel, [string]$old, [string]$new) {
    $p = Join-Path $workB $rel
    $t = [System.IO.File]::ReadAllText($p)
    if (-not $t.Contains($old)) { throw "PATTERN NOT FOUND in $rel :`n$old" }
    if ($t.IndexOf($old) -ne $t.LastIndexOf($old)) { throw "PATTERN NOT UNIQUE in $rel :`n$old" }
    [System.IO.File]::WriteAllText($p, $t.Replace($old, $new))
    Write-Host "ok  $rel"
}

# --- B2: klog.h 前缀只在 debug 构建保留 ---
Edit 'kernel/include/klog.h' @'
#ifdef pr_fmt
#undef pr_fmt
#define pr_fmt(fmt) "KernelSU: " fmt
#endif
'@ @'
#ifdef pr_fmt
#undef pr_fmt
#ifdef CONFIG_KSU_DEBUG
#define pr_fmt(fmt) "KernelSU: " fmt
#else
// Release builds must not stamp every kernel message with a KernelSU marker:
// the "<N>KernelSU: ..." prefix in dmesg is a one-line root fingerprint.
#define pr_fmt(fmt) fmt
#endif
#endif
'@

# --- B2: 开机 banner 收进 debug ---
Edit 'kernel/core/init.c' @'
    pr_info("welcome to KernelSU version " __stringify(KERNEL_SU_VERSION) ", package name " KSU_PACKAGE_NAME "\n");
'@ @'
#ifdef CONFIG_KSU_DEBUG
    pr_info("welcome to KernelSU version " __stringify(KERNEL_SU_VERSION) ", package name " KSU_PACKAGE_NAME "\n");
#endif
'@

# --- B2/P2: zygote fork 热路径日志 ---
Edit 'kernel/hook/setuid_hook.c' @'
    pr_info("handle_setresuid from %d to %d\n", old_uid, new_uid);
'@ @'
    // Hot path: every zygote fork lands here. Keep it silent unless debug
    // logging is enabled, otherwise the kernel log carries one line per app
    // process and leaks the whole uid transition history.
    pr_debug("handle_setresuid from %d to %d\n", old_uid, new_uid);
'@

# --- B2/P2: 逐进程标记日志 ---
Edit 'kernel/hook/tp_marker.c' `
    '            pr_info("tp_marker: mark process: pid:%d, uid: %d, comm:%s\n", t->pid, uid, t->comm);' `
    '            pr_debug("tp_marker: mark process: pid:%d, uid: %d, comm:%s\n", t->pid, uid, t->comm);'
Edit 'kernel/hook/tp_marker.c' `
    '            pr_info("tp_marker: unmark process: pid:%d, uid: %d, comm:%s\n", t->pid, uid, t->comm);' `
    '            pr_debug("tp_marker: unmark process: pid:%d, uid: %d, comm:%s\n", t->pid, uid, t->comm);'

# --- B2/P6: IOCTL 表 dump 收进 debug ---
Edit 'kernel/supercall/dispatch.c' @'
void __init ksu_supercall_dump_commands(void)
{
    int i;

    pr_info("KernelSU IOCTL Commands:\n");
    for (i = 0; ksu_ioctl_handlers[i].handler; i++) {
        pr_info("  %-18s = 0x%08x\n", ksu_ioctl_handlers[i].name, ksu_ioctl_handlers[i].cmd);
    }
}
'@ @'
void __init ksu_supercall_dump_commands(void)
{
#ifdef CONFIG_KSU_DEBUG
    int i;

    pr_info("KernelSU IOCTL Commands:\n");
    for (i = 0; ksu_ioctl_handlers[i].handler; i++) {
        pr_info("  %-18s = 0x%08x\n", ksu_ioctl_handlers[i].name, ksu_ioctl_handlers[i].cmd);
    }
#endif
}
'@

# --- B1: 三个 always_allow 收紧 ---
Edit 'kernel/supercall/dispatch.c' @'
        .name = "GET_INFO",
        .handler = do_get_info,
        .perm_check = always_allow
'@ @'
        .name = "GET_INFO",
        .handler = do_get_info,
        .perm_check = allowed_for_su
'@
Edit 'kernel/supercall/dispatch.c' @'
        .name = "GET_INFO_LEGACY",
        .handler = do_get_info_legacy,
        .perm_check = always_allow
'@ @'
        .name = "GET_INFO_LEGACY",
        .handler = do_get_info_legacy,
        .perm_check = allowed_for_su
'@
Edit 'kernel/supercall/dispatch.c' @'
        .name = "CHECK_SAFEMODE",
        .handler = do_check_safemode,
        .perm_check = always_allow
'@ @'
        .name = "CHECK_SAFEMODE",
        .handler = do_check_safemode,
        .perm_check = allowed_for_su
'@
Edit 'kernel/supercall/dispatch.c' `
    '    pr_warn("ksu ioctl: unsupported command 0x%x\n", cmd);' `
    '    pr_debug("ksu ioctl: unsupported command 0x%x\n", cmd);'

# --- B1: 驱动 fd 安装通路加 uid 门禁 ---
Edit 'kernel/supercall/supercall.c' @'
#include "klog.h" // IWYU pragma: keep
'@ @'
#include "klog.h" // IWYU pragma: keep
#include "manager/manager_identity.h"
#include "policy/allowlist.h"
#include <linux/cred.h>
'@
Edit 'kernel/supercall/supercall.c' @'
    if (magic1 == KSU_INSTALL_MAGIC1 && magic2 == KSU_INSTALL_MAGIC2) {
        struct ksu_install_fd_tw *tw;
'@ @'
    if (magic1 == KSU_INSTALL_MAGIC1 && magic2 == KSU_INSTALL_MAGIC2) {
        /*
         * Fail closed. Only the manager, root, or an already granted uid may
         * obtain a driver fd. Any other process that replays the public magic
         * numbers from uapi/supercall.h gets nothing back, so the install path
         * can no longer be used to fingerprint the kernel from an ordinary app.
         */
        if (unlikely(!is_uid_manager(current_uid().val) && current_uid().val != 0 &&
                     !ksu_is_allow_uid_for_current(current_uid().val))) {
            return 0;
        }

        struct ksu_install_fd_tw *tw;
'@

# --- P1: init.rc 代理 hook 只服务 pid 1 ---
Edit 'kernel/runtime/ksud_integration.c' @'
static void ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr)
{
    struct file *file = fget(fd);
'@ @'
static void ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr)
{
    /*
     * Only init reads /system/etc/init/hw/init.rc, and only during early boot.
     * Returning before fget()/d_path() keeps this hook off the system-wide
     * read() hot path instead of paying for it on every read in the system.
     */
    if (current->pid != 1)
        return;

    struct file *file = fget(fd);
'@
Edit 'kernel/runtime/ksud_integration.c' @'
static long ksu_sys_fstat(const struct pt_regs *regs)
{
    unsigned int fd = PT_REGS_SYSCALL_PARM1(regs);
'@ @'
static long ksu_sys_fstat(const struct pt_regs *regs)
{
    // Same reasoning as ksu_handle_sys_read(): only init fstat()s init.rc.
    if (current->pid != 1)
        return orig_sys_fstat(regs);

    unsigned int fd = PT_REGS_SYSCALL_PARM1(regs);
'@

# --- B2: init.rc 注入与按键相关日志降噪 ---
foreach ($pair in @(
        @('pr_info("read_proxy:', 'pr_debug("read_proxy:'),
        @('pr_info("read_iter_proxy:', 'pr_debug("read_iter_proxy:'),
        @('pr_info("stat init.rc")', 'pr_debug("stat init.rc")'),
        @('pr_info("read init.rc, comm:', 'pr_debug("read init.rc, comm:'),
        @('pr_info("adding rc len:', 'pr_debug("adding rc len:'),
        @('pr_info("added rc len")', 'pr_debug("added rc len")'),
        @('pr_info("unregister init_rc syscall hook', 'pr_debug("unregister init_rc syscall hook'),
        @('pr_info("KEY_VOLUMEDOWN val:', 'pr_debug("KEY_VOLUMEDOWN val:'),
        @('pr_info("unregister input kprobe:', 'pr_debug("unregister input kprobe:'),
        @('pr_info("ksud: input_event_kp:', 'pr_debug("ksud: input_event_kp:')
    )) {
    $p = Join-Path $workB 'kernel/runtime/ksud_integration.c'
    $t = [System.IO.File]::ReadAllText($p)
    if (-not $t.Contains($pair[0])) { throw "PATTERN NOT FOUND: $($pair[0])" }
    [System.IO.File]::WriteAllText($p, $t.Replace($pair[0], $pair[1]))
}

# --- 产出 diff（LF 行尾，路径前缀 a/ b/）---
$lines = & git -C $work -c core.autocrlf=false diff --no-index --no-color --src-prefix= --dst-prefix= a b
$text  = ($lines -join "`n") + "`n"
$outPath = [System.IO.Path]::GetFullPath($Out)
[System.IO.File]::WriteAllText($outPath, $text)
Write-Host "`nwrote $outPath ($($text.Length) bytes)"

# --- 自检：能否干净应用到源码 ---
& git -C $source apply --check --verbose $outPath
if ($LASTEXITCODE -ne 0) { throw "git apply --check 失败：补丁与 $source 的上下文不匹配" }
Write-Host "git apply --check: OK"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
