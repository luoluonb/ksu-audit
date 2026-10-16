# KernelSU（tiann/KernelSU, main 快照 · Manager v3.3.1 build 32680）反检测与优化审计

审计对象：`ksu-src/KernelSU-main`（GitHub main 分支源码快照）+ 官方 release APK `ksu/KernelSU_v3.3.1_32680-release.apk`
范围：`kernel/`（内核模块）、`userspace/`（ksud / ksuinit）、`manager/`（管理器 App）、`repack_apk.py`、CI
产出：本报告 + 可直接 `git apply` 的补丁 `ksu-hide-and-perf.patch`（7 文件，已通过 `git apply --check`）

---

## 0. 结论摘要

这套实现的内核侧隐藏设计比 Magisk 一代进步明显（init.rc 内存注入、SELinux backup policy 伪装、fd 路径伪装、默认 umount），但**还剩 4 个能被普通 App（无 root、无 shell）直接命中的指纹**，以及一批只在 shell / dmesg / 内核符号层面暴露的痕迹：

| 编号 | 缺口 | 谁能看到 | 严重度 |
|---|---|---|---|
| B1 | `reboot(KSU_INSTALL_MAGIC1,KSU_INSTALL_MAGIC2,…)` 安装 fd 的通路**没有 uid 门禁**，且 `GET_INFO`/`CHECK_SAFEMODE` 是 `always_allow` → 任意 App 5 行代码定性判定 KSU，还能读出完整版本号 | 普通 App | **P0** |
| B2 | 内核日志指纹：`pr_fmt "KernelSU: "`（每条内核日志都带前缀）、开机 banner 打印版本+包名、开机 dump 30 条 IOCTL 表、zygote fork 热路径 / 每进程 / 每次按键的 `pr_info` | dmesg / `logcat -b kernel` | **P0** |
| B3 | LKM 模式下模块名 `kernelsu` 暴露在 `/proc/modules`、模块参数暴露在 `/sys/module/*/parameters`、符号暴露在 `/proc/kallsyms`（名字部分对非 root 也可见）；**全树没有任何 kallsyms/模块列表过滤** | shell / 部分机型 App | **P0**（LKM 模式） |
| B4 | 路径存在性泄漏：只有 `faccessat`/`newfstatat` 且只针对 allowlist uid 的 `/system/bin/su` 做了伪造，**`statx` 未 hook、`/data/adb` 这类目录的存在性未伪造**；`stat("/data/adb")` 对普通 App 成功返回，成为最高频的 root 存在判定 | 普通 App | **P1** |
| B5 | `/sys/fs/selinux/policy` 导出的仍是打过补丁的策略（含 `ksu` / `ksu_file` 类型与全部放宽规则），`selinux_hide` 只伪装了 `check_context`/`compute_av`/status page | shell | **P1** |
| B6 | `/proc/config.gz`（`CONFIG_KSU=y`）、`/proc/cmdline`、`/sys/module/kernelsu/…` 组合可判定，无 `IKCONFIG` 伪装 | shell / 普通 App（config.gz） | **P1** |
| B7 | anon inode 名 `[ksu_driver]` / `[ksu_driver_su]` / `[ksu_fdwrapper]` 未做中性化（`file_wrapper` 已用 `d_dname` 伪装成功，supercall 这条没做） | 同 uid / root | P2 |
| B8 | userspace：`comm=ksud`、argv/env 含 `KSU_*`、logcat tag `KernelSU`、`/data/adb/ksu/*` 目录族、SELinux 标签 `ksu_file`、`/init` 替换时序、boot.log 落盘、`delete_module("kernelsu")` | shell | **P1** |
| B9 | Manager：UA `KernelSU/<ver>`、`ksu://` 深链、JNI 桥名 `ksu`、组件/快捷方式/通知渠道名、`tiann/KernelSU` release API、`repack_apk.py` 只重签不改包名、CI 证书 CN 带 KernelSU | App 枚举 / 抓包 | P2 |
| B10 | 模块挂载 overlay 的 `st_dev`/inode、`hot_install_trash/<module>.<nanos>`、sepolicy 注入产生的 avc 日志 | App（mountinfo）/ dmesg | P2 |

性能侧另有一个**明显值得改**的点（P1）：`ksu_sys_read` / `ksu_sys_fstat` 这两个全局 syscall 表 hook 在开机期间对**系统里每一次 `read()` / `fstat()`** 都执行 `fget()` + `dname` 比较（必要时 `d_path()`），而实际上只有 init 会读 `/system/etc/init/hw/init.rc`。加一行 `if (current->pid != 1) return;` 即可在整个系统范围内消除这份开销。

---

## 1. 现有隐藏机制盘点（设计正确，建议保留）

1. **init.rc 内存注入**：`kernel/runtime/ksud_integration.c:288-463` 把 `file->f_op` 换成代理，在 EOF 后追加 KSU 的 rc 文本；`ksu_sys_fstat`（:576-614）同步伪造 `st_size`；首次读取后 `stop_init_rc_hook()`（:634-639）卸载 hook。**磁盘上的 init.rc 保持原样**，这条设计是对的，比 Magisk 改 ramdisk/mainline 的做法更抗检测。
2. **SELinux 双策略**：`apply_kernelsu_rules()`（`kernel/selinux/rules.c:45-166`）先 `ksu_dup_sepolicy` 备份原始策略到 `backup_sepolicy`，再对副本打补丁；`selinux_hide`（`kernel/feature/selinux_hide.c:95-188`）把 `selinux_write_op[SEL_CONTEXT]`、`[SEL_ACCESS]` 与 `sel_handle_status_ops->open` 换成用 **备份策略** 计算的实现，并给 `selinux_status` 提供假页（:312-384、:517-556）。`selinux_hide_drop_backup_if_unused()`（:587-598）在未启用时释放，避免常驻内存特征。
3. **umount 默认开启**：`kernel/policy/allowlist.c:55` `default_non_root_profile.umount_modules = true`，配合 `ksu_handle_umount`（`kernel/feature/kernel_umount.c:75-126`）在 zygote→appuid 的 setresuid 时机卸载模块挂载点；并且校验 `is_zygote(current_cred())` 以免误伤全局 ns。
4. **LKM 模式抹掉 /sys/module**：`kernel/core/init.c:196-200` 在非 debug 构建里 `kobject_del(&THIS_MODULE->mkobj.kobj)`。注意：**这只能消掉 `/sys/module/kernelsu`，`/proc/modules` 与 `/proc/kallsyms` 的模块标记仍在**（见 B3）。
5. **fd 路径伪装**：`kernel/infra/file_wrapper.c:411-425` 用 `d_dname` + `d_op` 把包装 fd 的 `/proc/pid/fd/N` 还原成原始文件路径（:555-558 注释也说明了 tty 场景），这是"匿名 fd 不暴露路径"的正确解法。
6. **管理器身份绑定签名而非包名**：`kernel/manager/apk_sign.c:145-275` 解析 APK v2 签名块比对证书 size+sha256；`throne_tracker.c:199-206` 只在签名校验通过时 `crown_manager()`。`manager_identity.h:47-55` 用 `uid % 100000` 比对，多用户/工作资料也能正确识别。
7. **安全模式**：`ksud_integration.c:616-627` 用 `input_event` kprobe 数音量下键（≥3 次进安全模式），失败时内核侧不加载——比"按住音量键=mount 到安全模式"的检测窗口小。

---

## 2. 隐藏缺口与改造方案

### B1【P0】安装驱动 fd 的通路无 uid 门禁 → 任意 App 可定性检测

- 证据：`uapi/supercall.h:16-17` 魔数是公开常量；`kernel/supercall/supercall.c:116-140` 的 `reboot_handler_pre()` 只比对魔数就 `task_work_add`；`ksu_install_fd_tw_func()`（:102-114）直接 `ksu_install_fd()`，**不检查 uid**；`kernel/supercall/dispatch.c:726-754` 的 `GET_INFO` / `GET_INFO_LEGACY` / `CHECK_SAFEMODE` 是 `always_allow`。
- 检测手法（普通 App 权限即可）：
  ```c
  int out = -1;
  syscall(SYS_reboot, 0xDEADBEEF, 0xCAFEBABE, 0, &out);
  if (out >= 0) { ioctl(out, KSU_IOCTL_GET_INFO, &info); }  // 版本号、flags 全拿到
  ```
- 改造（补丁已含）：
  1. `reboot_handler_pre` 内加门禁：仅 `is_uid_manager()` / uid 0 / `ksu_is_allow_uid_for_current()` 允许安装 fd，其余直接返回，**不写回任何值**（失败要"静默"，不要返回可区分的错误码）。
  2. `GET_INFO` / `GET_INFO_LEGACY` / `CHECK_SAFEMODE` 由 `always_allow` 收紧为 `allowed_for_su`（manager 或已授权 uid）。
- 残余风险：如果将来允许第三方 App 免 root 调用 ioctl，需给它们单独的授权通道，不要回退 `always_allow`。

### B2【P0】内核日志指纹

- 证据：`kernel/include/klog.h:8` `#define pr_fmt(fmt) "KernelSU: " fmt` → **每一条**内核日志都带 `KernelSU:` 前缀；`kernel/core/init.c:95` 开机 banner 打印版本与 **Manager 包名**；`dispatch.c:899-907` 开机 dump 全部 IOCTL 命令与编号；`setuid_hook.c:28` 每次 zygote fork 打一条；`tp_marker.c:96-102` 逐进程打 mark/unmark；`kernel_umount.c:118` 逐挂载点打；`ksud_integration.c:486` **每次音量下键**打一条。
- 检测手法：`dmesg | grep -i kernel` / `logcat -b kernel`；机型 `dmesg_restrict=0` 时普通 App 可读。日志同时是最容易被安全厂商做"特征串一票判定"的地方。
- 改造（补丁已含）：release 构建去掉 `pr_fmt` 前缀；banner 与 IOCTL dump 移入 `#ifdef CONFIG_KSU_DEBUG`；热路径 `pr_info` → `pr_debug`（默认不编译进内核日志）。
- 建议追加：给所有 KSU 日志加一个可运行时关掉的开关（`static_branch`），这样出厂固件也能静默。

### B3【P0，LKM 模式】模块名 / 参数 / 符号暴露

- 证据：`kernel/Kbuild:1`（`kernelsu-objs`）、`kernel/Kbuild:93`（`obj-$(CONFIG_KSU) += kernelsu.o`）、`kernel/core/init.c:242-244`（`MODULE_DESCRIPTION("Android KernelSU")`、`MODULE_AUTHOR("weishu")`）；`feature.c:102`（`module_param_cb(force_feature,…)`）、`init.c:83-90`（`allow_shell` / `norc` / `bundled`）、`apk_sign.c:296`（`ksu_debug_manager_appid`）；`module_blacklist.c:43`（`block_modules`）。
- 可见面：`/proc/modules`、`/proc/kallsyms`（符号名可见，地址按 `kptr_restrict` 隐藏）、dmesg 模块加载行、`.ko` 内字符串。
- 改造建议：
  1. 构建产物与模块名中性化：`kbuild` 里把 `kernelsu` 改成 `kvm_amd` 之类的既有内核模块名（装机侧 userspace 也要同步：`userspace/ksud/src/debug.rs:11`、`unload.rs:143-147`、`lkm_image.rs` 的 `embedded_module_name()`）。
  2. 用 `kprobe` 挂 `proc_modules` 的 `m_show()` 与 kallsyms 的 `s_show()`，对非授权 uid 过滤掉名字含 `ksu/kernelsu` 的行（**这是本树完全缺失的能力**，SUSFS 的 `HIDE_KSU_SUSFS_SYMBOLS` 就是干这个）。补丁骨架见 §5.1。
  3. 模块参数改为通过 supercall 下发（而不是 `module_param`），从根上去掉 `/sys/module/*/parameters/*`。
  4. `.ko` 发布时 `llvm-strip -d`（`kernel/build-all.sh:21` 已对部分平台做了，确保全部平台一致）。

### B4【P1】路径存在性泄漏与 `statx` 未覆盖

- 证据：`kernel/feature/sucompat.c:91-159` 只覆盖 `faccessat` / `newfstatat`，且只在 `ksu_is_allow_uid_for_current()` 为真、且路径恰好等于 `/system/bin/su` 时重定向；`kernel/hook/syscall_hook_manager.c:139-143` 只注册了 5 个 syscall hook；**没有任何针对 `/data/adb` 的存在性伪装**。
- 为什么严重：Android 的 `/data` 对 other 有 x 位，`/data/adb` 本身 0700 root。App 执行 `stat("/data/adb")` 时 **stat 只需要父目录可搜索**，因此 magisk/KSU 存在时返回成功，不存在时返回 `ENOENT`；而 `stat("/data/adb/ksu")` 在有 KSU 时返回 `EACCES`、没有时返回 `ENOENT`。**errno 差异本身就足以判定**，无需任何权限。
- 改造（补丁只含注册点提示，主体代码见 §5.2）：
  1. 新增 `ksu_handle_statx()` 并注册 `__NR_statx`（App / 框架 / 部分 bionic 路径会直接走 `statx`，只挂 `newfstatat` 会漏掉一整类调用）。
  2. 建一张 hide 路径表（`/data/adb`、`/data/adb/ksu`、`/data/adb/modules`、`/data/adb/ksud`、`/metadata/ksu`、`/debug_ramdisk/.ksu` 之类），对非 manager / 非 root / 非授权 uid **统一返回 `-ENOENT`**（不是 `-EACCES`）。
  3. 反向规则同样重要：对授权进程必须**照常返回真实结果**，否则 manager 自己会挂。
- 残余风险：`/proc/mounts` / `/proc/self/mountinfo` 里的 overlay 挂载点（模块目录）需要独立的 mountinfo 过滤，光靠路径 hide 覆盖不到。

### B5【P1】SELinux 策略可被 dump

- 证据：`selinux_hide.c` 只替换了 `SEL_CONTEXT` / `SEL_ACCESS` 写入（:412-430）和 status 页（:536-556）；`rules.c:87-157` 往策略里加了 `ksu` 域、`ksu_file` 类型、`domain ksu_file:file *`、`allow ksu * * *`、`allow domain ksu:unix_stream_socket …` 等一大批规则，`/sys/fs/selinux/policy` 的读取路径（`security_read_policy()` → `policydb_write()`）**没有被替换**。
- 检测手法：shell 身份 `cat /sys/fs/selinux/policy | strings | grep -E 'ksu|kernel_su'`；或对策略做 size/`latest_granting` 与官方 build 的对比。
- 改造：在 `selinux_hide` 里增加 `SEL_POLICY` 的读写代理——把 `sel_read_policy`（或策略文件的 `open`）替换为"对非授权 uid 序列化 `backup_sepolicy`"的实现；`ksu_dup_sepolicy()` 已经能拿到完整策略对象，序列化用内核的 `policydb_write()`（`selinux/sepolicy.c:927` 已在用）即可。同时注意 `SEL_MEMBER` / `SEL_VALIDATE_TRANS` 也应走备份策略，否则补齐度不够。
- 残余风险：策略备份本身占用内存（`ksu_destroy_sepolicy` 的释放路径要一起检查）。

### B6【P1】config / cmdline / 模块参数

- 证据：`kernel/Kconfig:4`（`CONFIG_KSU`）；全树没有对 `IKCONFIG` 的任何处理。
- 检测手法：`cat /proc/config.gz | zcat | grep KSU`（多数自编译内核开了 `IKCONFIG_PROC`）；`cat /proc/cmdline`；`ls /sys/module/`。
- 改造：仿照 SUSFS 的 `SPOOF_CMDLINE_OR_BOOTCONFIG`——挂 `ikconfig` 的 `config_show()`（或 `proc_do_ikconfig`）与 `/proc/cmdline` 的读取路径，过滤 `KSU`/`ksu`/`kernelsu` 行；LKM 模式不要用 cmdline 传参（`module_blacklist.c:19` 注释里就写了 built-in 会走 cmdline），改用 supercall。

### B7【P2】anon inode 名

- 证据：`kernel/supercall/supercall.c:62` `"[ksu_driver]"` / `"[ksu_driver_su]"`；`kernel/infra/file_wrapper.c:524` `"[ksu_fdwrapper]"`（这条被 `d_dname` 掩盖，实际不泄漏路径）。userspace 侧靠名字扫描找 fd（`userspace/ksud/src/ksucalls.rs:81-137`，`unload.rs:67,98`）。
- 改造：把名字集中到一个宏，默认改成中性串；**必须同步改 ksucalls/unload 里的匹配串**（否则 userspace 找不到驱动 fd）。注意"名字伪装成 `[eventpoll]`"这类做法会被行为检测识破（fd 不支持 epoll 操作），中性名 + 必要时给 `/proc/pid/fd` 做过滤更稳。

### B8【P1】userspace 指纹（ksud / ksuinit）

- 证据：`userspace/ksud/src/cli.rs:493-497`（logcat tag `KernelSU`）、`cli.rs:502-512`（直接分发 `std::env::args()`）；`defs.rs:13-64`（`/data/adb/ksu/`、`/data/adb/ksud`、`bin/`、`lib/`、`log/`、`.ksurc`、`module_configs/`、`hot_install_trash/`、`stock_image.sha1`）；`restorecon.rs:9-63`（SELinux type `ksu_file`）；`ksuinit/src/lib.rs:16-27`（临时把 `/proc/sys/kernel/kptr_restrict` 写成 1）、`lib.rs:88-116`（`/dev/kmsg` 直写）；`init.rs:98-136`（`Hello, KernelSU!`、`Loading kernelsu.ko..`、回显全部模块参数）；`init.rs:116-124`（`unlink("/init")` + symlink）；`init_event.rs:26-27`（`logcat -b all`、`dmesg -w -r` 落盘到 `/data/adb/ksu/log/`）；`unload.rs:143-147`（`delete_module("kernelsu")`）。
- 改造（按收益排序）：
  1. `comm` / `argv` 中性化：入口 `prctl(PR_SET_NAME,"kworker/u8:2")` + argv 内存覆盖（长度等长覆写，不改长度避免 `/proc/pid/cmdline` 空洞特征）。
  2. 环境变量改名：模块脚本的 `KSU_*` 换成中性前缀（`KSUD_*` 之类），并默认 `env_clear()` 后按白名单下发。
  3. 目录与 SELinux 标签：`/data/adb/ksu` → 中性目录名（如 `/data/adb/adbd_cache`），标签从自定义 `ksu_file` 改成已存在的 `system_file`/`metadata_file`，避免 `ls -Z` 一眼看出。
  4. 关掉敏感日志落盘（`/data/adb/ksu/log/boot.log` 等于把全部指纹写成一本书）。
  5. `magica.rs:45-87` 不要改全局 `ro.debuggable` / `ro.adb.secure`（这两个属性是强特征，且会被 `getprop` 直接命中）。
  6. `/init` 替换时序：尽量让 `/proc/1/exe` 保持指向 `/init`（例如把真实 init 放到别的路径、用 mount bind 而不是 symlink）。
- 残余风险：目录改名牵动内核侧 `KSUD_PATH`（`kernel/runtime/ksud.h:6`）与 `ksu_file` 标签，属于跨组件改动，别单改一边。

### B9【P2】Manager 与发行链

- 证据：`manager/app/src/main/java/me/weishu/kernelsu/KernelSUApplication.kt:70` `User-Agent: KernelSU/${VERSION_CODE}`；`manager/app/src/main/AndroidManifest.xml:51-63`（`ksu://action|webui` 深链）、`:100-110`（进程名 `:magica_boot`、组件名 `ui.webui.WebUIActivity` 等）；`WebViewHelper.kt:192`（`addJavascriptInterface(...,"ksu")`）；`manager/app/src/main/java/.../ui/util/Downloader.kt:56`（直连 `api.github.com/repos/tiann/KernelSU/releases/latest`）；`kernelsu.org` / `modules.kernelsu.org` / `mui.kernelsu.org` 等域名散在 DEX 里。
- **改名机制不完整（最关键）**：`repack_apk.py` 只做"塞 libksud.so + zipalign + v2 重签"（`repack_apk.py:255-289, 388-417`），**不改包名、不回写证书 hash**；包名/签名是编译期常量：`kernel/Kbuild:136-150`（`KSU_PACKAGE_NAME ?= me.weishu.kernelsu`、`KSU_EXPECTED_SIZE ?= 0x033b`、`KSU_EXPECTED_HASH ?= c37106…d2d6`）+ `kernel/manager/apk_sign.c:119-142`（size 不等直接 false，再比 sha256）+ `manager/app/build.gradle.kts:28,149`（gradle 属性 `KSU_PACKAGE_NAME`）+ `userspace/ksud/build.rs:236-237`。
- 改造：
  1. 让 `repack_apk.py` 支持 `--package-name`：改写 AndroidManifest（binary AXML）的 `package`（只改 `applicationId` 层面，Java 包名不动，避免 `Java_me_weishu_*` JNI 符号断裂），同时**打印/写出**对应的 `KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH`。
  2. CI 里生成 `-DKSU_PACKAGE_NAME=... -DEXPECTED_SIZE=... -DEXPECTED_HASH=...` 的构建参数（`.github/workflows/build-manager.yml:65,78` 已经有生成 hash 的步骤，只差回写）。
  3. UA / 通知渠道 / 快捷方式 / 进程名 / 桥名 / 域名做批次中性化；`throne_tracker.c:344` 的 `pr_info("Searching manager " KSU_PACKAGE_NAME)` 会**把包名打进 dmesg**，必须删（已包含在 §3 P2 的日志清理范围内）。
  4. 签名保持 v2-only（`userspace/ksud/src/apk_sign.rs:68-85` 明确拒绝 v3/v3.1），否则内核校验会失败。

### B10【P2】挂载与残留

- 证据：模块 overlay 的挂载点（umount 只覆盖到 `ksu_uid_should_umount(uid)` 命中的 uid，`kernel_umount.c:97-99`）；`userspace/ksud/src/hot_install.rs:86-96`（`hot_install_trash/<module>.<nanos>` 命名带模块名）；`module.rs:486-597`（`/metadata/watchdog/ksu/modules.rc`）。
- 改造：umount 之外补一层 mountinfo/mounts 过滤（对非授权 uid 过滤 KSU 相关挂载行）；`hot_install` 临时名改成纯 hex；`modules.rc` 路径去掉 `ksu` 字样（内核侧读取路径要同步改）。

---

## 3. 性能与健壮性优化（与隐藏同等重要）

| 编号 | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1 | `read()` / `fstat()` 全局 syscall 表 hook 在开机窗口内对**系统每一次调用**执行 `fget()` + `dname` 比较（必要时 `d_path()`），而其实只有 init 会读 init.rc | `kernel/runtime/ksud_integration.c:465-473, 576-594, 653-658` | 两个 handler 首行加 `if (current->pid != 1) return;`（**已含在补丁**）。收益：整个开机窗口的系统级 syscall 开销归零 |
| P2 | 热路径日志：每次 zygote fork（`setuid_hook.c:28`）、逐进程 mark（`tp_marker.c:96-102`）、逐挂载点（`kernel_umount.c:118`）、每次按键（`ksud_integration.c:486`） | 同上 | `pr_info` → `pr_debug`（**已含在补丁**）；`ksu_handle_umount` 的逐条日志建议只在 debug 保留 |
| P3 | `tracepoint_reg_count > 1` 时把**全系统所有进程**打上 `TIF_SYSCALL_TRACEPOINT`（`tp_marker.c:66-78`、`syscall_hook_manager.c:59-73`） | 同上 | 只要其它 ftrace/perf 用户注册就"全标记"，既是全系统 per-syscall 开销，又让所有进程都带上该 trace 位。建议改成按需标记（只标 KSU 关心的 uid/进程），并在 `reg_count>1` 时改为"hook 失效但不动全系统标记"的策略 |
| P4 | `infra/seccomp_cache.c:18-31` **按位复制内核 `struct seccomp_filter` 的内存布局**，随内核升级极易错位写内存 | `app_profile.c:242-254` 里只对 `seccomp_filter_release` 做了符号探测，filter 布局没探测 | 改为通过 `kallsyms` 校验关键偏移或直接在 `seccomp_filter` 里定位 `cache` 字段；至少在布局变化时拒绝启用而非盲写 |
| P5 | `lsm_hook.c:22` 静态 16 槽跟踪表，超限即 `-ENOSPC` | 同上 | 改成链表；同时保留"就地替换既有 hook 项"的现有策略（比新增 LSM 项隐蔽，值得保持） |
| P6 | `ksu_supercall_dump_commands()` 每次开机打印 30 行（还带 IOCTL 编号） | `dispatch.c:899-907` | 收进 `CONFIG_KSU_DEBUG`（**已含在补丁**） |
| P7 | `is_ksud_exists()` 每次 `faccessat/stat("/system/bin/su")` 都 `kern_path()` | `sucompat.c:80-89, 108-119, 143-154` | 结果缓存（boot_completed 后 ksud 路径不变），或改成一次性的 `kern_path` + 失效回调 |
| P8 | `selinux_hide` 的 `my_write_context` / `my_write_access` 每次都做 `sidtab` 查询 + `kmalloc`，且 `avd.seqno` 恒为 1 | `selinux_hide.c:95-188` | 高频调用可加 per-uid 结果缓存；`seqno=1` 建议改成与 `backup_sepolicy->latest_granting` 一致，避免与 status 页自相矛盾 |
| P9 | `ksu_module_blacklist_exit()` 故意泄漏合并后的字符串并**不还原** `module_blacklist` 指针 | `module_blacklist.c:82-92` | 行为有注释解释（避免 NULL 竞态），可接受；但模块卸载后该指针仍指向 KSU 堆内存，建议卸载时把内容复制到内核自有分配再替换指针 |

---

## 4. 补丁：`ksu-hide-and-perf.patch`

内容（7 个文件，均已 `git apply --check` 通过，可直接打到 main 快照）：

1. `kernel/include/klog.h`：release 构建去掉 `"KernelSU: "` 前缀（`CONFIG_KSU_DEBUG` 下保留）。
2. `kernel/core/init.c`：开机 banner（版本 + Manager 包名）收进 `CONFIG_KSU_DEBUG`。
3. `kernel/hook/setuid_hook.c`：zygote fork 热路径 `pr_info` → `pr_debug`。
4. `kernel/hook/tp_marker.c`：逐进程 mark/unmark 日志 → `pr_debug`。
5. `kernel/supercall/dispatch.c`：`GET_INFO` / `GET_INFO_LEGACY` / `CHECK_SAFEMODE` 从 `always_allow` 收紧为 `allowed_for_su`；IOCTL 表 dump 收进 `CONFIG_KSU_DEBUG`；未知 ioctl 的 `pr_warn` → `pr_debug`。
6. `kernel/supercall/supercall.c`：**安装 fd 的 reboot 魔数通路加 uid 门禁**（B1 核心），并补 `manager/manager_identity.h` / `policy/allowlist.h` / `linux/cred.h` 头文件。
7. `kernel/runtime/ksud_integration.c`：`ksu_handle_sys_read` / `ksu_sys_fstat` 加 `current->pid != 1` 快速门禁（P1）；init.rc 注入与按键相关的 `pr_info` → `pr_debug`。

应用与验证：

```sh
cd KernelSU-main
git apply --check /path/to/ksu-hide-and-perf.patch    # 已通过
git apply /path/to/ksu-hide-and-perf.patch
# 内核模块编译（示例，按自己的 KMI 选）
cd kernel && ./build-all.sh          # 或 make -C $KDIR M=$PWD CONFIG_KSU=m modules
```

落地后必须回归的 4 件事：
1. Manager 能正常打开、能授权 App（`GET_INFO` 权限收紧后的唯一风险点）。
2. ksud 的 `su`/`post-fs-data`/`boot-completed` 流程正常（走 uid 0，不受门禁影响）。
3. 模块挂载与 umount 正常。
4. `adb shell`（uid 2000，未被授权）执行 §6 的自测脚本应当**检测不到**。

---

## 5. 需要新增代码的较大改造（骨架）

### 5.1 kallsyms / `/proc/modules` 过滤（补 B3）

```c
// 复用现有 kprobe + ksu_patch_text 基础设施（参考 hook/lsm_hook.c:64-74）
static int ksu_kallsyms_show(struct seq_file *m, void *v)
{
    // 授权进程（manager / root / 已授权 uid）不干预
    if (ksu_is_authorized(current_uid().val))
        return ((kallsyms_show_fn)orig_s_show)(m, v);
    // 非授权：先让原函数渲染，再判断本行是否含 KSU 符号（或用 v 指针判 module）
    // 实践中直接 hook kallsyms 的 s_show 并在 module 指针命中 KSU 时返回 0 更省事
    return 0;
}
// /proc/modules：hook m_show(struct seq_file*, void*)，对 KSU 自己的 module 条目返回 0
// 注册点：kernel/hook/syscall_hook_manager_init() 之后的 init 阶段
// 同时需要 hook "modules" 的 seq_file 遍历（/proc/modules 的 m_show 走 module list）
```
配套：`kernel/include/klog.h` 增加 `ksu_is_authorized()` 辅助函数（manager || uid==0 || `ksu_is_allow_uid_for_current()`），上面 B1/B4/B5 三处都可以复用。

### 5.2 路径存在性伪装（补 B4）

```c
// kernel/feature/hide_path.c（新增，Kbuild 里 feature/hide_path.o 一行）
static const char *hide_prefixes[] = {
    "/data/adb", "/data/adb/ksu", "/data/adb/modules", "/data/adb/ksud",
    "/metadata/ksu", "/debug_ramdisk/.ksu",
};

// 与 sucompat 同风格，注册到 dispatcher：__NR_newfstatat / __NR_faccessat / __NR_statx
long ksu_handle_statx(int orig_nr, struct pt_regs *regs)
{
    char path[128];
    const char __user *fn = (const char __user *)PT_REGS_PARM2(regs);
    if (!ksu_is_authorized(current_uid().val) &&
        ksu_read_user_path(fn, path, sizeof(path)) &&
        ksu_path_is_hidden(path))
        return -ENOENT;              // 注意：要返回 ENOENT，不能返回 EACCES
    return ksu_syscall_table[orig_nr](regs);
}
```
注册点：`kernel/hook/syscall_hook_manager.c:139-143` 增加 `__NR_statx`（以及 `__NR_openat` 若要连 open 一起伪装）。

### 5.3 策略 dump 伪装（补 B5）

复用 `selinux_hide.c` 里已有的 `ksu_patch_text` 槽替换方式（:412-430、:536-556），把策略文件的读路径换成"序列化 `backup_sepolicy`"：

```c
static ssize_t my_read_policy(struct file *filp, char __user *buf, size_t count, loff_t *ppos)
{
    if (likely(current_uid().val < 10000) || !ksu_selinux_hide_enabled)
        return orig_read_policy(filp, buf, count, ppos);
    // 用 backup_sepolicy 调 policydb_write() 到内核 buffer，再 copy_to_user
    // （selinux/sepolicy.c:927 已有 policydb_write 的用法可抄）
}
```

---

## 6. 检测视角自测清单（改完请逐条回归）

在**未被授权**的普通 App / uid 2000 上执行，全部应为"检测不到"：

1. **B1**：`reboot(0xDEADBEEF,0xCAFEBABE,0,&out)` 后 `out` 必须仍是 -1；拿到 fd 后 `ioctl(GET_INFO)` 必须 `EPERM`。
2. **B2**：`dmesg | grep -ci kernel`（同时按 F-音量键几次）。
3. **B4**：`stat("/data/adb")`、`stat("/data/adb/ksu")`、`statx(AT_FDCWD,"/data/adb/ksu",…)` 全部 `ENOENT`。
4. **B3**：`cat /proc/modules`、`grep -i ksu /proc/kallsyms`、`ls /sys/module | grep -i ksu`。
5. **B5**：`strings /sys/fs/selinux/policy | grep -iE 'ksu|kernel_su'`。
6. **B6**：`zcat /proc/config.gz | grep KSU`、`cat /proc/cmdline`。
7. **B7**：`ls -l /proc/self/fd | grep -i ksu`（在 su 会话与 manager 进程内各看一次）。
8. **B8**：`ps -A -o pid,comm,args | grep -Ei 'ksud|ksu|kernelsu'`；`ls /data/adb`；`ls -Z /data/adb`。
9. **B9**：`pm list packages | grep -i kernel`；`dumpsys package | grep -i kernel`；抓包看 UA。
10. 现成的第三方检测器（Rikka 的 NativeDetector、Momo、Hunter、各类 "root 检测" 与银行 App）作为端到端验收。

建议同时保留一个**反向验收**：授权 App（比如 manager 自己、`su` 会话）必须仍能正常拿到 fd、正常读 `/sys/fs/selinux/*`、正常 `ls /data/adb`——隐藏过度的第一种症状就是 manager 打不开。

---

## 7. 优先级路线图

| 批次 | 内容 | 工作量 | 风险 |
|---|---|---|---|
| 第 1 批（立即） | `ksu-hide-and-perf.patch`（B1 门禁 + B2 日志 + P1 热路径门禁） | 0.5 天 | 低（仅 `GET_INFO` 权限收紧需回归 manager） |
| 第 2 批 | B4 路径伪装（含 `statx`）+ B3 kallsyms/module 过滤 | 2–3 天 | 中（syscall hook 增多，注意 dispatcher 开销） |
| 第 3 批 | B5 策略 dump 伪装 + B6 config/cmdline 伪装 | 2 天 | 中（SELinux 侧改动需充分回归） |
| 第 4 批 | B8/B9/B10 userspace + manager 去特征化，含 `repack_apk.py` 改名闭环 | 3–5 天 | 中高（跨组件改名，必须一起改） |
| 第 5 批 | P3/P4/P5 的架构性优化（tracepoint 标记策略、seccomp 布局、lsm 槽表） | 3 天 | 中（动的是核心 hook 机制） |

> 一句话：**先补那个"任意 App 一行 syscall 就能判定 KSU"的门禁**，再处理日志与热路径；改名/符号隐藏这类"看起来更酷"的改造，收益反而不如这两条直接。
