# 使用说明：仓库怎么用、补丁怎么上、效果怎么验

本仓库是 **[tiann/KernelSU](https://github.com/tiann/KernelSU) 的对抗性审计 + 两批可应用的内核侧加固补丁**，不含上游源码树。

---

## 0. 分支地图（先看这个）

| 分支 | 内容 | 用途 |
|---|---|---|
| **`main`** | 全部内容：审计报告、两批补丁、两批设计说明、打包闭环说明、工具 | **默认分支，看文档/取补丁都从这里** |
| `feature/hide-path-and-scrub` | 第 2 批（路径隐藏 + 读取擦除）的开发分支 | 只想看第 2 批的改动历史 |
| `audit/kernelsu-hide-and-perf` | 最早的批次：仓库初版（第 1 批补丁 + 检测工具） | 历史存档；内容 `main` 全都有 |

`main` 是超集（`main` ⊇ `feature/hide-path-and-scrub` ⊇ `audit/kernelsu-hide-and-perf`），三个分支都已推到 `origin`。

```sh
git clone https://github.com/luoluonb/ksu-audit.git
cd ksu-audit            # 默认就在 main
```

### 文件一览（`main`）

```
README.md                               项目概览 + 缺口摘要表
USAGE.md                                本文件：操作手册
docs/kernelsu-hide-audit.md             完整审计报告（证据 file:line / 检测手法 / 改造方案 / 路线图）
docs/batch2-hide-path-and-scrub.md      第 2 批设计：LSM 钩子点与 VFS 调用链证据、代价、7 条限制、验证方法
docs/packaging-and-auto-install.md      打包闭环：keystore → 内核常量 → .ko → ksud → APK
patches/ksu-hide-and-perf.patch         第 1 批：日志 / 权限 / 热路径（7 文件，+333 行）
patches/ksu-hide-path-and-scrub.patch   第 2 批：路径隐藏 + 读取擦除（8 文件，+759 行，4 个新文件）
tools/detect-ksu.c                      检测 PoC：证明"任意 App 能否判定 KernelSU"
tools/verify-device.sh                  设备端自测清单（未授权 uid 下逐条回归）
tools/gen-patch.ps1                     从新鲜上游源码重新生成第 1 批补丁（可复现）
upload.ps1                              推送助手（token 走环境变量，不落盘）
```

---

## 1. 两条路：先体检，再改内核

| 路径 | 目的 | 改内核吗 | 耗时 |
|---|---|---|---|
| **A. 体检** | 确认当前设备/固件到底有哪些可判定线索（改前基线） | 不用 | 10 分钟 |
| **B. 加固** | 打补丁 → 编译 → 刷入 → 验收 | 要 | 1–2 小时（含编译） |
| **C. 续期** | 上游 KernelSU 更新后重新生成补丁 | 不用 | 5 分钟 |

---

## 2. 路径 A：体检（不改任何东西）

### A1. 编译检测 PoC

```sh
# 把 $NDK 换成你的 Android NDK 路径
$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android24-clang \
    -O2 -static tools/detect-ksu.c -o detect-ksu
```

### A2. 推到设备并运行

```sh
adb push detect-ksu /data/local/tmp/
adb shell chmod 755 /data/local/tmp/detect-ksu
adb shell /data/local/tmp/detect-ksu ; echo "exit=$?"     # 0 = 未检测到；1 = 检测到
```

**未打补丁**的 KernelSU 会输出（关键：`fd=3`）：

```
[1] reboot(0xdeadbeef, 0xcafebabe, 0, &fd): ret=-1 errno=1 (Operation not permitted) fd=3
    -> KERNELSU PRESENT：未授权 uid 也能拿到驱动 fd
[2] /proc/self/fd/3 -> anon_inode:[ksu_driver]
[3] KSU_IOCTL_GET_INFO 成功：
        version=32680 uapi_version=5 features=6
        flags=0x00000001 LKM
```

**打补丁后 `[1]` 必须变成 `fd=-1`**，脚本走"没有拿到驱动 fd"分支并以 0 退出。这是第 1 批是否生效的唯一标准。

### A3. 跑全套自测

```sh
adb push tools/verify-device.sh /data/local/tmp/
adb shell sh /data/local/tmp/verify-device.sh ; echo "exit=$?"
```

每行 `ok` / `LEAK` / `SKIP` / `INFO`，末尾汇总 `LEAK=n SKIP=n`。把**改前 / 改后**两次输出都留档，作为回归基线。

---

## 3. 路径 B：打补丁 → 编译 → 部署 → 验收

### B1. 准备源码

```sh
git clone https://github.com/tiann/KernelSU.git
cd KernelSU
git checkout 9f5966b4d534869fd72a79b3c6ea602e5eae3022   # 本仓库的审计基线
```

### B2. 应用补丁

补丁打在 KernelSU 目录这一层（路径就是 `kernel/...`，与它在内核树里的位置无关）：

```sh
cd /path/to/kernel/drivers/kernelsu

git apply --check /path/to/patches/ksu-hide-and-perf.patch          # 先干跑
git apply --check /path/to/patches/ksu-hide-path-and-scrub.patch
git apply /path/to/patches/ksu-hide-and-perf.patch                  # 第 1 批
git apply /path/to/patches/ksu-hide-path-and-scrub.patch            # 第 2 批
```

- **两批互不重叠，可以只打其中一个**；两种顺序都验证过（`b1→b2` 与 `b2→b1` 都能干净应用）。
- `--check` 报 `patch does not apply` → 上游那几行上下文变了，走路径 C 重新生成，别用 `-3` / `--reject` 硬塞。

确认落位：

```sh
grep -n 'ksu_is_allow_uid_for_current' kernel/supercall/supercall.c      # 第 1 批：B1 门禁
grep -n 'perm_check = allowed_for_su'   kernel/supercall/dispatch.c      # 第 1 批：3 处权限
grep -n 'current->pid != 1'             kernel/runtime/ksud_integration.c# 第 1 批：热路径门禁（2 处）
grep -n 'hidden_paths\|ksu_hide_path_init' kernel/feature/hide_path.c    # 第 2 批：路径表
grep -n 'zram_mod\|_Static_assert'         kernel/feature/scrub.c        # 第 2 批：等长改名
```

### B3. 编译

**LKM 模式（GKI 设备，不用刷 boot）**

```sh
cd kernel
./build-all.sh                                            # 需要 ddk，产出各 KMI 的 .ko
# 或单编一个 KMI：
make -C $KDIR M=$PWD "MO=$PWD/out" CONFIG_KSU=m modules
```

产物形如 `kernelsu-aarch64-android14-6.1.ko`，选与 `uname -r` 匹配的 KMI。

**built-in 模式**：把 KernelSU 接进内核源码（见上游 `kernel/setup.sh`），`CONFIG_KSU=y` 后正常编内核。

> ⚠️ 本仓库的**第 2 批补丁在本环境没有做过编译验证**（这里没有内核头文件与 KMI 工具链）。能保证的只有：补丁干净应用、所有 LSM 签名与 VFS 调用链都对着上游 `v6.1/v6.6/v6.12` 源码核对过。编译必须按你的 KMI 走一遍。

### B4. 部署

```sh
adb push ksud /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/ksud
adb shell su -c '/data/local/tmp/ksud install'                       # 装用户空间

# LKM
adb push kernelsu-aarch64-<你的KMI>.ko /data/local/tmp/
adb shell su -c '/data/local/tmp/ksud insmod /data/local/tmp/kernelsu-aarch64-<你的KMI>.ko'

# 或 late-load（免重启）
adb shell su -c '/data/local/tmp/ksud late-load --kmi android14-6.1 --package-name <你的manager包名>'

# 卸载（LKM）
adb shell su -c '/data/local/tmp/ksud unload'
```

built-in 则备份 boot 后刷入（`ksud boot-patch` / `boot-restore`，或你惯用的方式）。

### B5. 验收（正向 + 反向，缺一不可）

**正向（未授权身份下应看不出来）**

```sh
adb shell /data/local/tmp/detect-ksu               # 期望 exit=0（第 1 批）
adb shell sh /data/local/tmp/verify-device.sh      # 期望 LEAK=0（第 1+2 批）

# 第 2 批单独复核
adb shell 'for p in /data/adb /data/adb/ksu /metadata/ksu /proc/config.gz; do
             stat -c "%n" "$p" >/dev/null 2>&1 && echo "LEAK $p" || echo "ok $p"; done'   # 期望全 ok（ENOENT）
adb shell 'grep -c -i ksu /proc/kallsyms; grep -c -i kernelsu /proc/modules; grep -c -i ksu /proc/cmdline'   # 期望全 0
adb shell 'strings /sys/fs/selinux/policy 2>/dev/null | grep -c -i ksu'      # 期望 0（有权限时）
# statx 也要验（旧实现只挂 newfstatat 会漏）：
#   statx(AT_FDCWD, "/data/adb", AT_STATX_SYNC_AS_STAT, STATX_BASIC_STATS, &stx) 应为 ENOENT
```

**反向（授权侧必须仍然可用 —— 隐藏过度最先坏的是管理器自己）**

1. 管理器能打开、显示"工作中"、能授权/取消授权 App。
2. `su` 会话正常（允许名单里的 App 调 `su` 能拿到 root）。
3. 模块能挂载 / umount / 卸载。
4. `adb root` 或 root shell 仍能正常读写 `/data/adb`、`cat /proc/kallsyms`。

### B6. 回滚

```sh
git apply -R /path/to/patches/ksu-hide-path-and-scrub.patch
git apply -R /path/to/patches/ksu-hide-and-perf.patch
# LKM：ksud unload；built-in：刷回备份的 boot
```

---

## 4. 补丁逐条：改了什么 / 影响面 / 出问题怎么办

### 第 1 批 `ksu-hide-and-perf.patch`（7 文件）

| # | 改动 | 为什么 | 出问题怎么办 |
|---|---|---|---|
| 1 | `supercall.c`：驱动 fd 安装通路加 uid 门禁 | 原来只比对公开魔数 `0xDEADBEEF/0xCAFEBABE` 就装 fd，任何 App 一行 `syscall()` 就能判定 KSU 并读版本 | 只有 manager / root / 已授权 uid 放行；su 会话走独立通道，不受影响。确有非授权 App 需要 fd 时，做独立授权设计，**不要回退 `always_allow`** |
| 2 | `dispatch.c`：`GET_INFO` / `GET_INFO_LEGACY` / `CHECK_SAFEMODE` → `allowed_for_su` | 挡住"随便一个 App 探测内核接口" | 管理器报权限错误时，先确认它真被内核认成 manager（包名/签名对上 `KSU_PACKAGE_NAME` / `KSU_EXPECTED_HASH`），而不是把权限放宽回去 |
| 3 | `klog.h` + `init.c`：release 去掉 `"KernelSU: "` 前缀、banner 收进 debug | 每条内核日志都带品牌前缀 / banner 打印版本+包名 | 要日志时用 `CONFIG_KSU_DEBUG=y` 重编 |
| 4 | `setuid_hook.c` / `tp_marker.c` / `ksud_integration.c`：热路径日志 → `pr_debug` | zygote fork、逐进程标记、音量键、init.rc 注入都是高频日志 | 纯日志量差异，无行为变化 |
| 5 | `ksud_integration.c`：`ksu_sys_read` / `ksu_sys_fstat` 加 `current->pid != 1` | 原来系统每一次 `read()`/`fstat()` 都要 `fget()`+`d_path()` | 只有 init 会读 `init.rc`，注入逻辑不变 |

### 第 2 批 `ksu-hide-path-and-scrub.patch`（8 文件 / +759 行）

| # | 改动 | 关键点 |
|---|---|---|
| 1 | `feature/hide_path.c`（新）：对 `/data/adb`、`/metadata/ksu`、`/metadata/watchdog/ksu`、`/debug_ramdisk/.ksu`、`/proc/config.gz` 返回 **`-ENOENT`**（不是 `EACCES`） | 走 LSM（`selinux_inode_getattr` / `selinux_inode_permission`）而不是 syscall dispatcher —— dispatcher 只对打标记的进程生效，而普通 App 恰恰没标记；`statx` 由 `vfs_getattr → security_inode_getattr` 天然覆盖 |
| 2 | `feature/scrub.c`（新）：对 `/proc/kallsyms`、`/proc/modules`、`/proc/cmdline`、`/sys/fs/selinux/policy` 做**等长改名** | `ksu_`→`zram_`、`kernelsu`→`zram_mod`、`kernel_su`→`zram_file`、`ksud`→`zram`、`KernelSU`→`ZramMods`；读取照常成功但 `grep -i ksu` 一条不中；策略是二进制带长度前缀，等长所以仍可解析（6 条 `_Static_assert` 编译期兜底） |
| 3 | 接线：`Kbuild` 两个新对象、`init.c` 的 init/exit、`boot_event.c` 在 post-fs-data / module-mounted / boot-completed 重新解析 inode | `/data` 在 init 阶段还没挂载，built-in 模式必须靠后面三次刷新 |

**开关**：`kernel/feature/hide_path.c` 的 `KSU_HIDE_PATH_ENABLE`、`kernel/feature/scrub.c` 的 `KSU_SCRUB_ENABLE`，改成 `0` 即整体关闭该特性（LKM 外部模块构建不走 Kconfig，所以用源码内开关）。

**第 2 批的 7 条已知限制**（详见 [docs/batch2-hide-path-and-scrub.md](docs/batch2-hide-path-and-scrub.md) §5）：

1. 若设备上还有别的方案（Shamiko / SUSFS / 其他自定义 LSM）也替换了 `selinux_inode_permission` 槽位，`ksu_lsm_hook()` 会失败 → 路径隐藏不生效（读取擦除的 `file_open` 槽独立，不受影响）。
2. SELinux 编成模块的少见配置下解析不到符号 → 特性自动失效并打告警。
3. **shell 也在隐藏对象内**：`adb shell` 下 `stat /data/adb` 变"不存在"、`grep ksu /proc/kallsyms` 查不到 —— 刻意取舍；要放开就去掉 `ksu_uid_is_hidden_target()` 里的 `uid == KSU_SHELL_UID`。
4. 擦除是**内容层**不是语义层：凡含 `ksu_` 的名字都被改名（为避免误伤 `checksum` 之类，needle 用的是 `ksu_` 而不是 `ksu`）。
5. 未覆盖：`/proc/self/mountinfo` 里 overlay 的 `st_dev`/inode、模块自创目录、userspace/manager 侧指纹、以及**内核里模块名本身仍叫 `kernelsu`**。
6. 运行期卸载时若仍有进程打开着被代理的文件，`f_op` 会指向模块内存（与 KSU 自带 `file_wrapper` 同类限制）。
7. **本环境未做编译验证**（没有内核头文件/KMI 工具链），只验证了干净应用与调用链核对。

---

## 5. 路径 C：上游更新后重新生成第 1 批补丁

```powershell
git clone https://github.com/tiann/KernelSU.git KernelSU-new
git -C KernelSU-new checkout <新的 main>
.\tools\gen-patch.ps1 -Source .\KernelSU-new -Out .\patches\ksu-hide-and-perf.patch
```

脚本末尾自带 `git apply --check` 自检，输出 `git apply --check: OK` 即成功（本仓库里这份补丁就是脚本生成的，SHA256 可复现）。
若报 `PATTERN NOT FOUND`，打开 `tools/gen-patch.ps1`，把对应 `Edit '...'` 的旧文本换成新代码里的等价片段即可。

> 第 2 批目前没有对应的生成脚本（它是新增文件为主，上下文少），上游改动影响到它时按 `git apply --check` 的报错手工 rebase。

---

## 6. 还没做、值得做的（按收益排序）

1. **B3 的模块列表过滤**：`/proc/modules` 的 `m_show()` 与 kallsyms 的 `s_show()` 做**条目级**过滤（第 2 批只做了改名，模块在内核里仍叫 `kernelsu`）。
2. **挂载视图过滤**：对非授权 uid 过滤 `/proc/self/mountinfo` / `/proc/mounts` 里的 KSU 相关 overlay 行。
3. **`/proc/<pid>/fd` 与 anon inode 名（B7）**：`[ksu_driver]` / `[ksu_driver_su]` 中性化，并同步 userspace 的扫描字符串（`userspace/ksud/src/ksucalls.rs`、`unload.rs`）。
4. **userspace / manager 去特征化（B8/B9）**：含 `repack_apk.py` 的"改包名 + 回写证书 hash"闭环，见 [docs/packaging-and-auto-install.md](docs/packaging-and-auto-install.md)。

---

## 7. FAQ

**Q：打完之后管理器打不开了？**
第 1 批把 `GET_INFO` 收成了 `allowed_for_su`。先确认 manager 被内核认定为 manager：包名要对上编译期 `KSU_PACKAGE_NAME`，签名要对上 `KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH`（见 `docs/packaging-and-auto-install.md`）。确认无误后再查门禁。

**Q：`dmesg` 里还能看到 `KernelSU:` 前缀？**
检查是否编了 `CONFIG_KSU_DEBUG`；release 构建才有前缀移除。

**Q：`adb shell` 下 `/data/adb` 都看不见了，脚本跑不动？**
这是第 2 批的刻意取舍（shell 也属于隐藏对象）。用 root shell（`adb root` / `su`）复测，或去掉 `ksu_uid_is_hidden_target()` 里的 shell 判断。

**Q：只想要最小的改动？**
只打第 1 批（`ksu-hide-and-perf.patch`）：它修掉的正是"任意 App 一行 syscall 判定 KSU"这条最致命的通路，外加日志与热路径。

**Q：补丁会破坏现有模块吗？**
第 2 批的路径隐藏只对 App / isolated / shell 生效，`uid < 2000` 的系统守护进程一律不动（它们确有理由遍历 `/data` 与 `/proc`）；root / ksu 域 / 管理器 / 已授权 App 永远放行。模块挂载与 umount 逻辑没有被触碰。

**Q：我要在自己仓库里改？**
本仓库是 GPL-2.0（`LICENSE`）下的派生作品，直接 fork / clone 改都行；`docs/`、`patches/`、`tools/` 都保留了来源说明（`NOTICE.md`）。
