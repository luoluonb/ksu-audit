# v1.0.0 · KernelSU 反检测审计 + 两批内核侧加固补丁

给 [tiann/KernelSU](https://github.com/tiann/KernelSU)（基线 main 快照 · v3.3.1 / Manager build 32680，HEAD `9f5966b`）做的一次对抗性审计，外加两批可直接 `git apply` 的加固补丁，以及一套**手机上能直接跑**的验证工具。

## 下载什么

| 附件 | 大小 | 是什么 |
|---|---|---|
| `ksu-hide-verify-v1.0.0.zip` | 389 KB | **KernelSU / Magisk 模块包**，刷进管理器就能用：装上后点模块页的「操作」，自动以"未授权身份"跑完自检并出报告 |
| `ksu-audit-v1.0.0.zip` | 1.5 MB | 整套：审计报告、两批补丁、设计说明、脚本，以及 **预编译好的 arm64 / arm / x86_64 / x86 静态二进制** |

两个附件的 SHA256：

```
ksu-audit-v1.0.0.zip        916EF01EA7D83EA8A9C78E9127843B3296384459F9E0B787DC4DE1DEC243E52B
ksu-hide-verify-v1.0.0.zip  0E42F5E132AD1CF3C55F2CA94568F7AA84C189C393A7D62E48E40E5E20AE45E2
```

## 手机上三步

1. 手机浏览器下载 `ksu-hide-verify-v1.0.0.zip`（**不要解压**）。
2. KernelSU 管理器 → 「模块」→「从本地安装」→ 选这个 ZIP → 重启。
3. 模块页点「KSU Hide Self-Test」的**「操作」**按钮，几秒后弹出报告；完整报告在 `/data/adb/ksu_check/report.txt`。

想不开模块也行：把 `ksu-audit-v1.0.0.zip` 解压，用里面 `bin/detect-ksu-arm64` 直接跑（**不需要 root**）：

```sh
adb push bin/detect-ksu-arm64 /data/local/tmp/detect-ksu
adb shell chmod 755 /data/local/tmp/detect-ksu && adb shell /data/local/tmp/detect-ksu
```

**判读标准**：补丁前会打出 `fd=3` + `anon_inode:[ksu_driver]` + 版本号；打完 `patches/ksu-hide-and-perf.patch` 后必须是 `fd=-1`、`exit=0`。

## 两批补丁

- **第 1 批 `patches/ksu-hide-and-perf.patch`**（7 文件）：修掉"任意 App 一行 `syscall(SYS_reboot, 0xDEADBEEF, 0xCAFEBABE, …)` 就能判定 KernelSU 并读出版本号"这条无权限通路（驱动 fd 安装加 uid 门禁 + `GET_INFO`/`CHECK_SAFEMODE` 权限收紧），并清理内核日志指纹（`"KernelSU: "` 前缀、开机 banner、IOCTL 表 dump、zygote fork / 音量键等热路径日志），以及给 `ksu_sys_read`/`ksu_sys_fstat` 加 `pid!=1` 门禁消掉全系统 read/fstat 开销。
- **第 2 批 `patches/ksu-hide-path-and-scrub.patch`**（8 文件 / +759 行）：`/data/adb`、`/metadata/ksu`、`/proc/config.gz` 等**存在性**对 App/shell 返回 `ENOENT`（走 LSM，因为普通 App 没有 syscall tracepoint 标记，KSU 自带的 dispatcher 看不到它们；`statx` 顺带覆盖）；`/proc/kallsyms`、`/proc/modules`、`/proc/cmdline`、`/sys/fs/selinux/policy` 做**等长改名**（`ksu_`→`zram_` 等），读取照常成功但 `grep -i ksu` 一条不中。

两批**互不重叠**，可以只打一个；`b1→b2` 与 `b2→b1` 两种顺序都验证过可以干净应用。开关：`KSU_HIDE_PATH_ENABLE` / `KSU_SCRUB_ENABLE`。

```sh
git clone https://github.com/tiann/KernelSU.git && cd KernelSU
git checkout 9f5966b4d534869fd72a79b3c6ea602e5eae3022
git apply --check /path/to/patches/ksu-hide-and-perf.patch
git apply --check /path/to/patches/ksu-hide-path-and-scrub.patch
git apply /path/to/patches/ksu-hide-and-perf.patch
git apply /path/to/patches/ksu-hide-path-and-scrub.patch
cd kernel && ./build-all.sh
```

## 分支

| 分支 | 内容 |
|---|---|
| `main` | 全部内容（超集）：报告 + 两批补丁 + 设计说明 + 工具 + 模块源码 |
| `feature/hide-path-and-scrub` | 第 2 批的开发分支 |
| `audit/kernelsu-hide-and-perf` | 仓库初版（第 1 批 + 检测工具） |

## 验证状态（重要）

- ✅ 两批补丁在基线快照上**都能干净应用**，两种顺序均通过 `git apply --check`
- ✅ 第 2 批的改名表**长度逐一相等**（`kernel_su→zram_file` 9/9、`kernelsu→zram_mod` 8/8、`ksud→zram` 4/4、`ksu_→zram_` 4/4），6 条 `_Static_assert` 编译期兜底
- ✅ 发布包里的二进制都是 **静态链接的 arm64/arm/x86 ELF**（`e_machine` 已校验、无 `/system/bin/linker` 依赖），Android 5.0+ 直接可跑
- ⚠️ **两批补丁都没有做过内核编译验证**（构建环境没有内核头文件/KMI 工具链），只核对了 LSM 签名与 VFS 调用链。编译必须按你的 KMI 走一遍
- ⚠️ 第 2 批已知限制 7 条，最需要注意：`shell` 也在隐藏对象内（`adb shell` 下 `/data/adb` 会"不存在"，用 root shell 复测）；若设备已挂 Shamiko/SUSFS 等占用同一个 `selinux_inode_permission` 槽位，路径隐藏会静默失效（会打一条 `pr_warn`，读取擦除不受影响）

## 只用来验证，验完请卸载

`ksu-hide-verify` 这个模块本身会在 `/data/adb/modules/` 下留目录，属于 KernelSU 痕迹。它是体检工具，拿到报告后建议卸载（`uninstall.sh` 会清掉 `/data/adb/ksu_check` 与 `/data/local/tmp/detect-ksu`）。

## 许可

补丁与模块脚本针对 KernelSU 内核侧（GPL-2.0）修改，随附 `LICENSE`（GPL-2.0）。KernelSU 上游版权归其作者所有。本仓库不含上游源码树。
