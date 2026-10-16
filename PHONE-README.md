# 手机端使用说明（怎么把东西弄到手机上、怎么跑）

这个仓库有两条"手机可用"的通道：**GitHub Release 下载 ZIP**（推荐）和**直接刷模块**。

---

## 一、最省事：下载 Release 里的 ZIP

在手机浏览器打开：

**https://github.com/luoluonb/ksu-audit/releases/latest**

两个附件：

| 附件 | 是什么 | 怎么用 |
|---|---|---|
| `ksu-audit-v1.0.0.zip` | 全套：报告、两批补丁、脚本、以及**预编译好的 arm64/arm/x86 二进制** | 用 ZArchiver / MT 管理器解压到手机任意目录，看里面的 `PHONE-README.md` 和 `USAGE.md` |
| `ksu-hide-verify-v1.0.0.zip` | **KernelSU 模块包**，刷进管理器就能用 | 见下面第二节 |

ZIP 里的 `bin/` 目录已经放好了预编译二进制，**不需要在手机上编译任何东西**：

```
bin/detect-ksu-arm64      检测 KernelSU 是否存在（B1 通路），不需要 root，普通权限就能跑
bin/detect-ksu-arm        armeabi-v7a 版本
bin/detect-ksu-x86_64     x86_64 版本（模拟器）
bin/detect-ksu-i686       x86 版本（模拟器）
bin/runas-arm64           以指定 uid 运行命令（root 侧复现"未授权身份"视角）
bin/runas-arm             同上，armeabi-v7a
```

都是**静态链接**的 aarch64/arm ELF，Android 5.0+ 直接能跑，不依赖 libc 版本。

### 不想装管理器？用模拟器/手上只有 adb 的情况

```sh
adb push bin/detect-ksu-arm64 /data/local/tmp/detect-ksu
adb shell chmod 755 /data/local/tmp/detect-ksu
adb shell /data/local/tmp/detect-ksu ; echo "exit=$?"
```

## 二、刷模块：一个按钮出体检报告（推荐）

`ksu-hide-verify-v1.0.0.zip` 是一个 **KernelSU / Magisk 通用模块**，作用是：把检测工具装到手机上，并在管理器里给你一个按钮，**自动以"未授权身份"跑完整套自检**，报告写进 `/data/adb/ksu_check/report.txt`。

### 安装

1. 把 `ksu-hide-verify-v1.0.0.zip` 下载到手机（**不要解压**）。
2. 打开 KernelSU 管理器 → 「模块」→「从本地安装」→ 选这个 ZIP。
3. 重启（或直接进模块页）。

### 用

- **手动跑**：管理器 → 模块页 → 找到「KSU Hide Self-Test」→ 点右下角 **「操作」** 按钮，几秒后弹出报告。
- **自动跑**：重启后模块的 `service.sh` 会在 `sys.boot_completed` 之后自动跑一次，报告同样落在 `/data/adb/ksu_check/report.txt`。
- **看历史报告**：`/data/adb/ksu_check/report.txt`（root 文件管理器或 Termux 里看）。

报告长这样（节选）：

```
===================================================
 KernelSU 反检测自检报告
===================================================
时间     : ...
内核     : 5.15.xxx-android13-...
Android  : 13 (SDK 33)
机型     : ...

---- [A] detect-ksu（驱动 fd 通路 / B1） ----
detect-ksu: uid=2000 euid=2000 pid=...
[1] reboot(0xdeadbeef, 0xcafebabe, 0, &fd): ret=-1 errno=1 (Operation not permitted) fd=-1
    -> 没有拿到驱动 fd：本路径检测不到 KernelSU（已加固或未运行）
exit=0（0=未检测到，1=检测到）

---- [B] verify-device.sh（路径存在性 / 符号擦除 / SELinux 策略 / 挂载） ----
ok    driver fd path: detect-ksu 未检测到 KernelSU
ok    /data/adb -> ENOENT
ok    /proc/modules 干净
...
== 汇总：LEAK=0  SKIP=2 ==
结果：在本身份下未发现可判定线索
```

### 为什么报告要"降权跑"

`action.sh` / `service.sh` 本身是 **root** 跑的，而"能不能被检测到"这个问题只有**未授权身份**问了才有意义（root 本来就能看到一切）。所以模块内部用自带的小工具 `runas` 把权限降到 **uid 2000（shell）** 再执行检测：

```sh
runas 2000 /data/adb/modules/ksu_hide_verify/tools/detect-ksu
runas 2000 sh /data/adb/modules/ksu_hide_verify/tools/verify-device.sh
```

想换成某个真实 App 的 uid（比如 `10098`）复测：

```sh
su -c 'runas 10098 sh /data/adb/modules/ksu_hide_verify/tools/verify-device.sh'
```

> 注意：`runas` 降的是 **uid/gid**，SELinux 域不变。所以路径存在性、`/proc/kallsyms` 内容这类**按 uid 判定**的检查是准确的；涉及 SELinux 域的判定仍建议用真实 App 或 `adb shell` 复测一次。

### 卸载

管理器里直接卸载模块即可（`uninstall.sh` 会清掉 `/data/adb/ksu_check` 和 `/data/local/tmp/detect-ksu`）。

**验完建议卸载**：这个模块本身会在 `/data/adb/modules/` 下留一个目录，属于 KSU 痕迹，只当体检工具用。

## 三、只有 Termux（没有管理器/没有 adb）？

Termux 里的 `~` 不是 `/data/local/tmp`，但可以直接在 Termux 自己的目录里跑：

```sh
# 假设已把 bin/detect-ksu-arm64 放到 ~/storage/downloads/
cp ~/storage/downloads/detect-ksu-arm64 ~/detect-ksu
chmod 755 ~/detect-ksu
~/detect-ksu ; echo "exit=$?"
```

（检测本身不需要 root，Termux 普通权限就够。）

## 四、要"真正加固"手机上的 KernelSU？

Release 里的补丁**不能直接在手机上生效** —— 它们改的是 KernelSU 的**内核侧 C 代码**，必须重新编译（LKM 的 `.ko` 或整个内核）。手机上没法做这件事，需要在电脑上：

```sh
git clone https://github.com/tiann/KernelSU.git && cd KernelSU
git apply /path/to/patches/ksu-hide-and-perf.patch
git apply /path/to/patches/ksu-hide-path-and-scrub.patch
cd kernel && ./build-all.sh          # 产出 .ko，按你的 KMI 选
```

然后把 `.ko` 推回手机、`ksud insmod`（或 `ksud late-load`）。完整步骤（含编译、部署、正向+反向验收、回滚）在仓库的 `USAGE.md` 里。

编译完的 `.ko` 想从电脑"发到手机"：

```sh
adb push kernelsu-aarch64-<你的KMI>.ko /data/local/tmp/
adb shell su -c '/data/local/tmp/ksud insmod /data/local/tmp/kernelsu-aarch64-<你的KMI>.ko'
# 或者：文件传到手机后用管理器的"本地安装"刷（如果是模块包）
```
