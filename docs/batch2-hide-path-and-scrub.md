# 第 2 批：路径隐藏（hide_path）+ 读取内容擦除（scrub）

补丁文件：`patches/ksu-hide-path-and-scrub.patch`
对应审计报告里的缺口：**B4（路径存在性泄漏 / `statx` 未覆盖）**、**B5（`/sys/fs/selinux/policy` 可 dump）**、**B6（`/proc/config.gz`、`/proc/cmdline`）**，以及部分 B3（`/proc/kallsyms`、`/proc/modules` 里的名字）。

基线：`tiann/KernelSU` main 快照（v3.3.1）。
规模：8 个文件，759 行新增（其中 4 个新文件）。

---

## 1. 要解决的问题（为什么必须在内核里做）

在真机上用一个普通 App（无 root、无 SELinux 特权）就能完成的判定：

```c
struct stat st;
stat("/data/adb", &st);          // 有 KernelSU → 0；原生设备 → -1/ENOENT
stat("/data/adb/ksu", &st);      // 有 KernelSU → -1/EACCES；原生 → -1/ENOENT
```

`stat()` 只要求**父目录可搜索**，不要求目标本身可读：`/data` 对 other 有 x 位，所以 `/data/adb` 这个 0700 目录的**存在性**对任何 App 都是可见的。errno 从 `ENOENT` 变成 `EACCES`/`0`，就是一句最廉价、也最难辩解的特征。

同类问题还有三条：`/proc/config.gz`（`CONFIG_KSU=y`，GKI 默认没有这个文件，一出现反而更显眼）、`/proc/kallsyms` 与 `/proc/modules`（`ksu_*` 符号名、`kernelsu` 模块名）、`/sys/fs/selinux/policy`（`ksu` / `ksu_file` 类型和那一批 `allow` 规则）。

---

## 2. 为什么走 LSM，而不是现成的 syscall dispatcher

KernelSU 已经有 syscall hook 基础设施（`hook/syscall_hook_manager.c`），但它**只对被打标记的进程生效**：`hook/tp_marker.c` 只给 ksu 域 root、zygote、shell、init 和已授权 uid 打 `TIF_SYSCALL_TRACEPOINT`，普通 App 恰恰是被特意清掉标记的那一类。所以基于 dispatcher 的过滤看不到最需要防的进程。

LSM 钩子是每个任务、每次调用都会被咨询的。核对上游 v6.12 源码确认的调用链：

| 用户态操作 | 内核路径 | 证据 |
|---|---|---|
| `stat` / `lstat` / `fstatat` / `statx` / `fstat` | `vfs_getattr()` → `security_inode_getattr()` | `fs/stat.c:196,204` |
| `access` / `faccessat` / `open` / `opendir` / exec | `inode_permission()` → `security_inode_permission()` | `fs/namei.c:510,543`；`fs/open.c:509`（`do_faccessat` 传入 `mode \| MAY_ACCESS`） |
| 打开文件（用于装 read 代理） | `do_dentry_open()`：先 `f->f_op = fops_get(inode->i_fop)`，再 `security_file_open(f)` | `fs/open.c:915,939,945` |

两个额外确认过的事实：

- `security_inode_getattr()` 的返回值会直接从 `vfs_getattr()` 返回，所以在这里返回 `-ENOENT` 就是一个干净的“文件不存在”。
- procfs 在 6.x 里**不再**在 `proc_reg_open()` 中替换 `file->f_op`（`fs/proc/inode.c:469`），`proc_reg_read()` 是从 inode 反查 `pde->proc_ops->proc_read`。因此在 `security_file_open` 里换掉 `file->f_op` 之后不会被覆盖，而我们的代理转发回 `proc_reg_read` 也能正常工作。

子路径不用单独处理：要解析 `/data/adb/ksu` 就必须先对 `/data/adb` 拿到 `MAY_EXEC`（search），我们在 `inode_permission` 里拒掉，查找直接以 `ENOENT` 结束。

---

## 3. 实现

### 3.1 `kernel/include/ksu_hide.h`（共享判定）

```c
static inline bool ksu_uid_is_authorized(uid_t uid);      // root / manager / 已授权 uid
static inline bool ksu_uid_is_hidden_target(uid_t uid);   // app、isolated、shell 且未授权
static inline int  ksu_lsm_hook_first(...)                // SELinux → BPF LSM 依次尝试
```

**隐藏对象刻意限定在 App（含 isolated）与 shell**。系统守护进程（uid < 2000 的 `system`、`system_server`、zygote 等）一律不动：它们确有合法理由遍历 `/data` 与 `/proc`，把它们弄坏比现在这个泄漏显眼得多。root / ksu 域 / 管理器 / 已授权 App 永远放行。

### 3.2 `kernel/feature/hide_path.c`

- 目标表：`/data/adb`、`/metadata/ksu`、`/metadata/watchdog/ksu`、`/debug_ramdisk/.ksu`、`/proc/config.gz`（不存在的项自动跳过，所以顺带列上不花成本）。
- 启动各阶段解析一次并缓存 `struct inode *`，命中判定是**指针相等 + `(dev, ino)` 双校验**（不持有引用，双校验用来防止 inode 地址被回收后复用造成误伤）。
- 两个槽位替换：`selinux_inode_getattr`、`selinux_inode_permission`；命中时返回 `-ENOENT`。
- 重新解析的时机：init、post-fs-data、module-mounted、boot-completed（`/data` 在 init 阶段还没挂载，built-in 模式下必须靠后面三次）。

代价：热路径上先读一次 `current_uid()`，系统流量立刻返回；只有 App/shell 才会走那 5 次指针比较。

### 3.3 `kernel/feature/scrub.c`

对“不能隐藏”的文件做**等长改写**，读取照常成功：

| 文件 | 改写 | 效果 |
|---|---|---|
| `/proc/kallsyms` | `ksu_` → `zram_`，`kernelsu` → `zram_mod` | `ksu_handle_setresuid` → `zram_handle_setresuid`；`grep -i ksu` 一条都不命中 |
| `/proc/modules` | `kernelsu` → `zram_mod` | 模块列表看着像多了一个普通模块 |
| `/proc/cmdline` | `ksu*` → `zram*` | 启动参数里的痕迹 |
| `/sys/fs/selinux/policy` | `ksu` → `zrm`，`ksu_file` → `zrm_file`，`kernel_su` → `zram_file` | 二进制策略里的类型名被**一致地**改名，长度不变所以仍然可解析、自洽 |

为什么必须等长：策略 dump 是带长度前缀的二进制格式，等长替换才不会破坏结构；行式的文件也避免让读取方的偏移失效。三条 `_Static_assert` 在编译期就把长度不一致拦下来。

安装方式：`file_open` LSM 钩子在每次打开时比对 inode（O(1) 指针比较），命中且当前 uid 属于隐藏对象时，把 `file->f_op` 换成**原 `file_operations` 的副本**，只包 `read` / `read_iter` 两个入口，其余（`owner`、`llseek`、`release`、`poll`…）原样继承——所以没被我们碰过的路径行为完全不变。

覆盖的读取路径：

- `read()` → `vfs_read()` 优先用 `f_op->read`（`fs/read_write.c:566`）→ 命中我们的代理 → 在用户缓冲区里分块擦除；
- `readv()` 单 iovec → 同样走 `f_op->read`（`fs/read_write.c:854`）；
- `pread64` / 多段迭代器 → 走 `read_iter` 代理，仅当目标是单缓冲区（`ITER_UBUF`）时擦除，pipe/splice 与多段目标原样透传，不改零拷贝语义。

擦除在用户缓冲区上按 512 字节 + 16 字节重叠滚动处理（栈占用固定 ~528B），重叠是为了避免 needle 正好跨块边界被漏掉。

---

## 4. 接线点（补丁里改了 4 处）

- `kernel/Kbuild`：新增 `feature/hide_path.o`、`feature/scrub.o` 两个对象。**没有加 Kconfig 开关**（LKM 外部模块构建不会处理 Kconfig），改用源码内的 `KSU_HIDE_PATH_ENABLE` / `KSU_SCRUB_ENABLE` 两个编译期开关，改一个数字就能整体关掉。
- `kernel/core/init.c`：`ksu_hide_path_init()` / `ksu_scrub_init()`（放在 `ksu_lsm_hook_init()` 之后），以及对应的 exit（放在 `ksu_lsm_hook_exit()` 之前显式反挂）。
- `kernel/runtime/boot_event.c`：post-fs-data / module-mounted / boot-completed 三个时机调用 `*_refresh()`。

---

## 5. 已知限制（必须在真机上回归）

1. **挂了 SELinux 的 `inode_permission` 槽位**：如果设备上还有别的方案（Shamiko、SUSFS、其他自定义 LSM）也替换了同一个槽，`ksu_lsm_hook()` 会失败并打一条 `pr_warn`，此时路径隐藏不生效（读取擦除的 `file_open` 槽位是独立的，互不影响）。
2. **`selinux_file_open` / `selinux_inode_*` 解析不到**（SELinux 编成模块的少见配置）→ 特性自动失效，只留一条告警；BPF LSM 名称作为备选已写在表里。
3. **shell 也在隐藏对象内**：`adb shell` 下 `stat /data/adb` 会变成“文件不存在”，`cat /proc/kallsyms | grep ksu` 也查不到。这是刻意取舍；要放开就把 `ksu_uid_is_hidden_target()` 里的 `uid == KSU_SHELL_UID` 去掉。
4. **擦除是内容层的，不是语义层的**：`/proc/kallsyms` 里凡含 `ksu_` 的名字都会被改名，包括理论上无关的符号；我们在 needle 选择上刻意避开 `checksum` 这类常见子串（用 `ksu_` 而不是 `ksu`）。若要连模块列表也彻底消失，仍需 B3 的 `/proc/modules` 条目过滤（本批未做）。
5. **未覆盖**：`/proc/self/mountinfo` 里模块 overlay 的 `st_dev`/inode（需要独立的 mount 视图过滤）、`/data/adb` 之外的路径（例如各模块自创目录）、userspace/manager 侧指纹（B8/B9）、LKM 模块名本身（`/proc/modules` 里我们只是改名，模块在内核里仍叫 `kernelsu`）。
6. **运行期卸载**：如果卸载 KSU 时恰好有进程正打开着被代理的文件，`f_op` 会指向模块内存。与 KSU 自带的 `infra/file_wrapper.c` 属于同一类限制，正常用法（先重启/先关掉读取方）不会触发。
7. **本补丁在本环境未做编译验证**：这里没有内核头文件与 KMI 工具链，只能保证①补丁能干净应用（`git apply --check` 通过）、②所有用到的 LSM 签名与 VFS 调用链都对着上游 `v6.1`/`v6.6`/`v6.12` 源码核对过（`inode_permission(struct inode *, int)`、`inode_getattr(const struct path *)`、`file_open(struct file *)` 三个签名在这三个版本上一致，`struct iov_iter.ubuf` 与 `ITER_UBUF` 也一致）。**编译仍必须按你的 KMI 走一遍**（`kernel/build-all.sh` 或 `make -C $KDIR M=$PWD CONFIG_KSU=m modules`）。

---

## 6. 怎么验证

编译并刷新后，用**未授权**身份（普通 App，或 `adb shell`）执行：

```sh
# 1) 路径存在性：全部应为 ENOENT
for p in /data/adb /data/adb/ksu /metadata/ksu /proc/config.gz; do
  stat -c '%n' "$p" >/dev/null 2>&1 && echo "LEAK $p" || echo "ok   $p"
done

# 2) statx（只挂 newfstatat 的旧实现会漏掉这条）
#    Native 侧：statx(AT_FDCWD, "/data/adb", AT_STATX_SYNC_AS_STAT, STATX_BASIC_STATS, &stx)

# 3) 名字擦除
grep -c -i 'ksu' /proc/kallsyms            # 期望 0
grep -c -i 'kernelsu' /proc/modules        # 期望 0
grep -c -i 'ksu' /proc/cmdline             # 期望 0
strings /sys/fs/selinux/policy | grep -c -i 'ksu'   # 期望 0（有权限时）

# 4) 反向验收（必须同时成立，否则是隐藏过度）
#    - 管理器能打开、能授权 App
#    - su 会话正常，/data/adb/ksud 能执行
#    - 模块挂载/umount 正常
#    - adb root 或 root shell 仍可正常读写 /data/adb
```

`tools/verify-device.sh` 里的第 3/4/5/6/7 项覆盖了上面大部分检查。

---

## 7. 下一批可以做什么

- **B3 的模块列表过滤**：`/proc/modules` 的 `m_show()` 与 kallsyms 的 `s_show()` 条目级过滤（本批只做了改名，模块名在内核里没变）。
- **挂载视图过滤**：对非授权 uid 过滤 `/proc/self/mountinfo` / `/proc/mounts` 里 KSU 相关的 overlay 行。
- **`/proc/<pid>/fd` 与 anon inode 名**（B7）：`[ksu_driver]` / `[ksu_driver_su]` 中性化，并同步 userspace 的扫描字符串。
- **userspace / manager 去特征化**（B8/B9）：含 `repack_apk.py` 的改名闭环。
