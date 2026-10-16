# 打包与"自动修补安装"

管理器里那个"安装 → 直接安装 / 选择文件"能自动修补 boot 镜像，靠的是这三件事串起来的：

```
① 内核侧 .ko   ──┐
② userspace ksud ─┴─► 把 .ko 内嵌进 ksud 二进制（rust-embed）──► libksud.so
                                                                  │
③ 管理器 APK   ◄──────────────────────────────────────────────────┘
                       │
   打开 App → 安装 → ksud boot-patch -b boot.img -f
                       │  （没给 -m 时，ksud 从自己内嵌的 assets 里取 {kmi}_kernelsu.ko）
                       ▼
               patch 后自动刷入 boot / init_boot / 非活动槽
```

关键结论：**要让"自动修补"用上你自己编译的（带补丁的）内核模块，必须把它内嵌进 ksud，再把 ksud 装进 APK。** 只把 `.ko` 丢到手机上，App 的自动流程用的还是官方内置模块。

---

## 0. 准备

```bash
git clone https://github.com/tiann/KernelSU.git && cd KernelSU
# 打上我们的补丁（两个，互不冲突）
git apply /path/to/ksu-audit/patches/ksu-hide-and-perf.patch
git apply /path/to/ksu-audit/patches/ksu-hide-path-and-scrub.patch
```

工具链：Linux/WSL、clang/LLVM（要 `llvm-strip`）、`cargo` + `cargo-ndk` + Android NDK、JDK（签名/构建管理器）、python3（用 repack 路线时）。

---

## 1. 先建 keystore，再拿常量（顺序不能反）

内核里 `KSU_EXPECTED_SIZE` / `KSU_EXPECTED_HASH` / `KSU_PACKAGE_NAME` 是**编译期常量**，必须等于**给管理器 APK 签名的那把证书**，否则内核不认这个 App 是管理器（`kernel/manager/apk_sign.c:119-142`），App 里就会显示"需要手动安装"、也拿不到驱动 fd。

```bash
keytool -genkeypair -alias ksu -keyalg RSA -keysize 2048 -validity 10000 \
  -storetype JKS -keystore ksu.jks \
  -storepass 'KEYSTORE_PASS' -keypass 'KEY_PASS' -dname "CN=MySU"

keytool -exportcert -alias ksu -keystore ksu.jks -storepass 'KEYSTORE_PASS' -file cert.der
EXPECTED_SIZE=$(printf '0x%04x' "$(stat -c%s cert.der)")
EXPECTED_HASH=$(sha256sum cert.der | awk '{print $1}')
echo "size=$EXPECTED_SIZE hash=$EXPECTED_HASH"
```

（官方 CI 就是这么算的：`.github/workflows/build-manager.yml:71-94`。）

---

## 2. 编带补丁的 `.ko`（把常量编进去）

```bash
cd kernel
# 单 KMI（已接进内核源码树，或 ddk 的 local 模式）
CONFIG_KSU=m CC=clang make \
  KSU_PACKAGE_NAME=me.weishu.kernelsu \
  KSU_EXPECTED_SIZE=$EXPECTED_SIZE \
  KSU_EXPECTED_HASH=$EXPECTED_HASH

# 或者用 ddk 逐 KMI 编（和官方 ddk-lkm.yml:55-68 等价）
ddk build android13-5.10 "ODIR=$PWD/out/android13-5.10" -e CONFIG_KSU=m \
  -e KSU_EXPECTED_SIZE=$EXPECTED_SIZE -e KSU_EXPECTED_HASH=$EXPECTED_HASH

# 改名 + 去调试信息（ddk-lkm.yml:77-84 的做法）
cp kernelsu.ko android13-5.10_kernelsu.ko
llvm-strip -d android13-5.10_kernelsu.ko
```

KMI 列表（`kernel/build-all.sh` 预置）：`android12-5.10`、`android13-5.10`、`android13-5.15`、`android14-5.15`、`android14-6.1`、`android15-6.6`、`android16-6.12`、`android17-6.18`。真机只需编自己的那个。

---

## 3. 编 `ksuinit`

```bash
cd ../userspace
cargo build --package ksuinit --target=aarch64-linux-android --release
# 产物 target/aarch64-linux-android/release/ksuinit
```

---

## 4. 把资产放进 `userspace/ksud/bin/<arch>/`

`bin/` 下的内容会被 rust-embed **整目录内嵌**进 ksud 二进制（`userspace/ksud/src/assets.rs:38-57`），设备端 `assets::get_asset("{kmi}_kernelsu.ko")` 就是从这儿取的。

```bash
# 文件名必须严格是 <kmi>_kernelsu.ko，因为设备端按 "{kmi}_kernelsu.ko" 查、
# 并且 list_supported_kmi() 靠 strip_suffix("_kernelsu.ko") 反推 KMI
cp kernel/android13-5.10_kernelsu.ko userspace/ksud/bin/aarch64/
cp kernel/android13-5.10_kernelsu.ko userspace/ksud/bin/x86_64/     # WSA/模拟器才需要
cp target/aarch64-linux-android/release/ksuinit userspace/ksud/bin/aarch64/
```

`bootctl` / `busybox` / `waitsys` 仓库里已经带了（`bin/aarch64`、`bin/x86_64`、`bin/riscv64`），**不要动**。riscv64 目录里没有 bootctl 是正常的。

---

## 5. 编 ksud（Android）

```bash
cd userspace/ksud
export KSU_PACKAGE_NAME=me.weishu.kernelsu      # 必须和第 2 步、第 6 步一致
cargo ndk -t arm64-v8a -t x86_64 build --release
# 产物 target/aarch64-linux-android/release/ksud
```

---

## 6. 把 ksud 装进管理器 APK

### 路线 A：Gradle 全量构建（要 Android SDK/JDK）

```bash
mkdir -p manager/app/src/main/jniLibs/arm64-v8a
cp userspace/ksud/target/aarch64-linux-android/release/ksud \
   manager/app/src/main/jniLibs/arm64-v8a/libksud.so
# x86_64 同理

cd manager
KEYSTORE_FILE=$(realpath ../ksu.jks) KEYSTORE_PASSWORD='KEYSTORE_PASS' \
KEY_ALIAS=ksu KEY_PASSWORD='KEY_PASS' \
  ./gradlew assembleRelease
```

### 路线 B：拿官方 APK 重打包（省事，推荐）

`repack_apk.py` 会把 `userspace/ksud/target/*/release/ksud` 注射成 `lib/<abi>/libksud.so`，然后 zipalign(16K) + v2 重签：

```bash
python3 repack_apk.py repack \
  -b release -t release \
  -a arm64-v8a -a x86_64 \
  -K /abs/path/ksu.jks -A ksu -P 'KEYSTORE_PASS' -S 'KEY_PASS' \
  --strip -o dist
```

⚠️ 路线 B **只能沿用 `me.weishu.kernelsu` 这个包名**（`repack_apk.py` 不重写 AndroidManifest，见审计报告 B9）。要换包名就走路线 A：
`./gradlew assembleRelease -PKSU_PACKAGE_NAME=com.example.mysu -PKSU_NAME="MySU"`，并让第 2 步、第 5 步的 `KSU_PACKAGE_NAME` 也用同一个值。

---

## 7. 安装与使用（这就是"自动修补安装"）

```powershell
adb install -r dist\<输出>.apk
```

打开管理器 → 右上角安装图标，四个选项都走 `ksud boot-patch`：

| 选项 | 场景 | 内部行为 |
|---|---|---|
| **直接安装** | 设备已 root / 已装过 KSU | 自动找 boot 或 init_boot → patch → 自动刷入当前槽 |
| **选择文件** | 无 root，第一次装 | 你选官方 boot.img → 导出补丁后的 img → 自己 `fastboot flash boot` |
| **安装到非活动槽** | A/B 设备 OTA 后 | patch 后写另一个槽，重启切槽 |
| **上传 LKM 文件**（可选） | 临时换用某个特定 .ko | 把 `-m <该文件>` 传给 ksud，覆盖内嵌模块 |

不带 `-m` 时 ksud 从自己内嵌的 assets 取 `{kmi}_kernelsu.ko`（`userspace/ksud/src/boot_patch.rs:765-783`）——**也就是你在第 4 步塞进去的那个带补丁的模块**。

补丁后的行为可以按 `docs/batch2-hide-path-and-scrub.md` §6 和 `tools/verify-device.sh` 验收。

---

## 8. 常见坑

1. **keystore 一换，`.ko` 必须重编**（常量是编译期写死的）。换 keystore 而没重编内核 → 管理器不被认作 manager。
2. **KMI 文件名一个字符都不能错**：`bin/aarch64/android13-5.10_kernelsu.ko`。错了就是启动时 `Failed to load android13-5.10_kernelsu.ko`，或者 App 列表里选不到 KMI。
3. **签名必须 v2-only**：`userspace/ksud/src/apk_sign.rs` 明确拒绝 v3/v3.1（`repack_apk.py` 默认就是 v2-only）。
4. **包名三处一致**：gradle 属性、ksud 编译环境变量、内核 `KSU_PACKAGE_NAME`。
5. **架构目录**：真机 `aarch64`，模拟器/WSA `x86_64`；只做了 aarch64 就别在 x86_64 上装。
6. **官方 CI 就是这条流水线的参考实现**：`build-manager.yml`（keystore/常量/打包）→ `ksud.yml`/`ksud-extra.yml`（资产落地）→ `ddk-lkm.yml`（带常量编 .ko）→ `release.yml`（产物命名）。`repack-config.example.json` 是 `repack_apk.py -c` 的配置示例。
7. **刷机前备份 stock boot/init_boot**；恢复用 App 里的卸载、`ksud boot-restore`，或直接刷回备份。
