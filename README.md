# KernelSU 反检测与性能审计（KernelSU v3.3.1 / main 快照）

对 [tiann/KernelSU](https://github.com/tiann/KernelSU) 的**对抗性代码审计 + 可直接应用的加固补丁**。
目标只有一个：找出这套实现里还能被"反 root 检测"命中的地方，并给出补丁级、可回归的改法。

## 审计基线

| 项 | 值 |
|---|---|
| 上游仓库 | `https://github.com/tiann/KernelSU` |
| 分支 | `main`（本会话抓取快照；抓取时观测到 HEAD = `9f5966b4d534869fd72a79b3c6ea602e5eae3022`） |
| 版本 | KernelSU v3.3.1，Manager build 32680 |
| 审计范围 | `kernel/`（内核模块）、`userspace/`（ksud / ksuinit）、`manager/`（管理器 App）、`repack_apk.py`、CI |

## 仓库内容

```
docs/kernelsu-hide-audit.md        完整审计报告（证据 file:line / 检测手法 / 改造方案 / 验收清单 / 路线图）
patches/ksu-hide-and-perf.patch    可直接 git apply 的补丁（7 文件，已通过 git apply --check）
tools/detect-ksu.c                 检测 PoC：验证补丁前/后"任意 App 能否判定 KernelSU"
tools/verify-device.sh             设备端自测清单（在 shell uid 下逐条回归）
tools/gen-patch.ps1                从新鲜的上游源码重新生成补丁（可复现）
upload.ps1                         推送助手（token 走环境变量，不落盘）
```

## 补丁包含什么

1. **驱动 fd 安装通路的 uid 门禁**（`kernel/supercall/supercall.c`）
   原实现只比对公开魔数 `0xDEADBEEF/0xCAFEBABE` 就安装驱动 fd，任何 App 一行 `syscall()` 即可判定 KernelSU 并读出版本号。补丁改为仅 manager / root / 已授权 uid 放行，其余静默无回写。
2. **`GET_INFO` / `GET_INFO_LEGACY` / `CHECK_SAFEMODE` 权限收紧**（`kernel/supercall/dispatch.c`，`always_allow` → `allowed_for_su`）。
3. **内核日志指纹清理**：release 构建去掉 `"KernelSU: "` 前缀（`kernel/include/klog.h`）、开机 banner 与 IOCTL 表 dump 收进 `CONFIG_KSU_DEBUG`、zygote fork / 逐进程标记 / 音量键等热路径 `pr_info` → `pr_debug`。
4. **热路径门禁**：`ksu_handle_sys_read` / `ksu_sys_fstat` 加 `current->pid != 1` 快速返回，消除"系统每一次 `read()`/`fstat()` 都要 `fget()`+`d_path()`"的开销。

## 应用补丁

```sh
git clone https://github.com/tiann/KernelSU.git && cd KernelSU
git checkout 9f5966b4d534869fd72a79b3c6ea602e5eae3022   # 或任意接近的 main 提交
git apply --check /path/to/patches/ksu-hide-and-perf.patch
git apply /path/to/patches/ksu-hide-and-perf.patch

# 内核模块
cd kernel && ./build-all.sh            # 或 make -C $KDIR M=$PWD CONFIG_KSU=m modules
```

补丁是纯文本改动，不依赖本次快照的绝对路径，可直接对上一条主线提交使用（`--check` 通过即上下文匹配）。

## 验证

```sh
# 1) 未授权 uid 下：应当"检测不到"
adb push tools/detect-ksu.c /data/local/tmp/ && adb shell sh /data/local/tmp/... 
# 用 NDK 编译后执行：输出应为 "reboot probe: no driver fd"，而不是 "KERNELSU PRESENT"

# 2) 设备端逐条自测（普通 App / shell uid）
adb shell sh tools/verify-device.sh
```

验收必须同时保证**反向**成立：管理器能正常打开、能授权 App、`su` 会话正常、模块能挂载卸载。隐藏过度最先坏的就是管理器自己。

## 主要发现（摘要）

| 编号 | 缺口 | 谁能看到 | 状态 |
|---|---|---|---|
| B1 | 驱动 fd 安装通路无 uid 门禁 + `GET_INFO` 是 `always_allow` | 普通 App | 补丁已修 |
| B2 | 内核日志指纹（全局 `pr_fmt`、banner、IOCTL dump、热路径日志） | dmesg | 补丁已修 |
| B3 | LKM 模式模块名/参数/符号暴露（`/proc/modules`、`/proc/kallsyms`、`/sys/module/*/parameters`） | shell | 报告含骨架，未在补丁内 |
| B4 | 路径存在性泄漏（`stat("/data/adb")` 的 errno 差异；`statx` 未 hook） | 普通 App | 报告含骨架 |
| B5 | `/sys/fs/selinux/policy` 仍导出打过补丁的策略 | shell | 报告含骨架 |
| B6 | `/proc/config.gz` / `/proc/cmdline` 无伪装 | App / shell | 报告含骨架 |
| B7–B10 | anon inode 名、userspace/manager 字符串与目录族、`repack_apk.py` 改名闭环缺失 | shell / App 枚举 | 报告含方案 |

性能侧另记：`tp_marker` 的全进程标记策略、`seccomp_cache` 直接复制内核结构体布局、`lsm_hook` 的 16 槽静态表（详见报告 §3）。

## 许可与来源

- `patches/`、`docs/`、`tools/` 中的内容针对 KernelSU 内核侧（GPL-2.0）修改，随附 `LICENSE`（GPL-2.0）。
- KernelSU 上游版权归其作者所有（`weishu` / tiann 及贡献者）；本仓库只包含审计报告与补丁，不包含上游源码树。
- 补丁为派生作品，按 GPL-2.0 分发。
