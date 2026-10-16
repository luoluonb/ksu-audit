# NOTICE / 来源与派生说明

## 上游

- 项目：KernelSU
- 仓库：https://github.com/tiann/KernelSU
- 审计基线：`main` 分支快照，版本 v3.3.1（Manager build 32680）
- 抓取时观测 HEAD：`9f5966b4d534869fd72a79b3c6ea602e5eae3022`
- 许可证：内核部分 GPL-2.0（`kernel/LICENSE`），用户空间/管理器部分 GPL-3.0（仓库根 `LICENSE`）

## 本仓库

| 文件 | 性质 | 许可证 |
|---|---|---|
| `patches/ksu-hide-and-perf.patch` | 对上游内核侧源码的派生改动 | GPL-2.0 |
| `tools/gen-patch.ps1` | 补丁再生脚本 | GPL-2.0 |
| `tools/detect-ksu.c` | 独立检测 PoC（仅使用 `uapi/supercall.h` 公开常量定义，未复制上游实现代码） | GPL-2.0 兼容 |
| `tools/verify-device.sh` | 独立自测脚本 | GPL-2.0 兼容 |
| `docs/kernelsu-hide-audit.md` | 审计报告（引用上游代码位置，属引用/评述） | 同上 |
| `LICENSE` | GPL-2.0 全文（取自上游 `kernel/LICENSE`） | — |

本仓库**不包含**上游源码树。使用前请自行 `git clone` 上游并按 README 应用补丁。

## 补丁上下文

补丁针对的源码上下文与上述基线快照一致；应用到其它提交时先跑 `git apply --check`。若上游改动导致上下文不匹配，用 `tools/gen-patch.ps1 -Source <上游源码目录> -Out <输出路径>` 在本地重新生成。
