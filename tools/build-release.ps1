# build-release.ps1 -- 生成可下载/可刷入的发布包
#
# 产出：
#   bin/detect-ksu-{arm64,arm,x86_64,i686}   静态检测二进制（NDK 交叉编译）
#   bin/runas-{arm64,arm}                    降权执行器（模块用它复现"未授权身份"视角）
#   dist/ksu-hide-verify-<ver>.zip           KernelSU/Magisk 模块包（直接刷）
#   dist/ksu-audit-<ver>.zip                 整套源码包（文档+补丁+脚本+二进制+模块包）
#
# 用法：
#   ./tools/build-release.ps1 -Ndk C:\path\to\android-ndk-r28b
#   ./tools/build-release.ps1 -Ndk <ndk> -SkipBinaries        # 只重新打包
#
# 依赖：Android NDK（编译）、bsdtar（Windows 自带 tar.exe 即可，用于打 zip）

param(
    [string]$Ndk = $env:ANDROID_NDK_HOME,
    [string]$Version = 'v1.0.0',
    [string]$OutDir = 'dist',
    [switch]$SkipBinaries
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot          # 仓库根
Set-Location $repo

function Write-Step($m) { Write-Host "== $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. 编译二进制
$targets = @(
    @{ abi = 'arm64';  cc = 'aarch64-linux-android24' },
    @{ abi = 'arm';    cc = 'armv7a-linux-androideabi24' },
    @{ abi = 'x86_64'; cc = 'x86_64-linux-android24' },
    @{ abi = 'i686';   cc = 'i686-linux-android24' }
)

if (-not $SkipBinaries) {
    Write-Step "编译二进制（NDK: $Ndk）"
    if (-not $Ndk) { throw "未指定 -Ndk，也没有 ANDROID_NDK_HOME 环境变量" }
    $binDir = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
    if (-not (Test-Path $binDir)) { throw "找不到 NDK 的 bin 目录：$binDir" }

    # 关键：NDK 需要在可写目录里建临时文件，默认 %TEMP% 在某些受限环境会被拒
    $tmp = Join-Path $repo 'tmp-build\tmp'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $env:TMP = $tmp; $env:TEMP = $tmp; $env:TMPDIR = $tmp

    New-Item -ItemType Directory -Force -Path 'bin' | Out-Null
    foreach ($t in $targets) {
        $cc = Join-Path $binDir ($t.cc + '-clang.cmd')
        & $cc -O2 -static -s -o "bin\detect-ksu-$($t.abi)" 'tools\detect-ksu.c'
        if ($LASTEXITCODE -ne 0) { throw "detect-ksu $($t.abi) 编译失败" }
        Write-Host "  bin/detect-ksu-$($t.abi)"
    }
    foreach ($t in @($targets[0], $targets[1])) {
        $cc = Join-Path $binDir ($t.cc + '-clang.cmd')
        & $cc -O2 -static -s -o "bin\runas-$($t.abi)" 'tools\runas.c'
        if ($LASTEXITCODE -ne 0) { throw "runas $($t.abi) 编译失败" }
        Write-Host "  bin/runas-$($t.abi)"
    }

    # ELF 校验：确认 ABI 正确且是静态可执行（无 PT_INTERP / 不引用 /system/bin/linker）
    Write-Step "校验 ELF"
    $expect = @{ 'arm64' = 0xB7; 'arm' = 0x28; 'x86_64' = 0x3E; 'i686' = 0x03 }
    Get-ChildItem 'bin' -File | Sort-Object Name | ForEach-Object {
        $b = [System.IO.File]::ReadAllBytes($_.FullName)
        $magic = ($b[0..3] | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($magic -ne '7f454c46') { throw "$($_.Name) 不是 ELF" }
        $machine = $b[18] + ($b[19] * 256)
        $abi = ($_.Name -replace '^(detect-ksu|runas)-', '')
        if ($expect[$abi] -ne $machine) { throw "$($_.Name) 的 e_machine=0x$('{0:x}' -f $machine) 与 $abi 不符" }
        $linked = [System.Text.Encoding]::ASCII.GetString($b).Contains('/system/bin/linker')
        if ($linked) { throw "$($_.Name) 不是静态链接" }
        Write-Host ("  {0,-22} {1,7:N1} KB  {2}" -f $_.Name, ($_.Length / 1KB), $abi)
    }
}
else {
    New-Item -ItemType Directory -Force -Path 'bin' | Out-Null
}

# ---------------------------------------------------------------- 2. 模块包
Write-Step "打模块包 ksu-hide-verify-$Version.zip"
$stageModule = 'tmp-build\module'
Remove-Item -Recurse -Force $stageModule -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$stageModule\tools" | Out-Null

Copy-Item 'module\module.prop'   "$stageModule\"
Copy-Item 'module\customize.sh'  "$stageModule\"
Copy-Item 'module\service.sh'    "$stageModule\"
Copy-Item 'module\action.sh'     "$stageModule\"
Copy-Item 'module\uninstall.sh'  "$stageModule\"
Copy-Item 'PHONE-README.md'      "$stageModule\PHONE-README.md"
Copy-Item 'module\tools\run-check.sh' "$stageModule\tools\run-check.sh"
Copy-Item 'tools\verify-device.sh'    "$stageModule\tools\verify-device.sh"
Copy-Item 'bin\detect-ksu-arm64'      "$stageModule\tools\detect-ksu"
Copy-Item 'bin\runas-arm64'           "$stageModule\tools\runas"
# 模块里的检测脚本名固定，运行时由 run-check.sh 调用
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$moduleZip = Join-Path (Resolve-Path $OutDir) "ksu-hide-verify-$Version.zip"
Remove-Item -Force $moduleZip -ErrorAction SilentlyContinue

# 用 bsdtar 显式列文件，避免 "./" 前缀；条目用正斜杠
$modEntries = @('module.prop', 'customize.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'PHONE-README.md', 'tools')
Push-Location $stageModule
try {
    & tar --format=zip -cf $moduleZip @modEntries
    if ($LASTEXITCODE -ne 0) { throw "打模块包失败" }
}
finally { Pop-Location }
Write-Host "  $moduleZip"

# ---------------------------------------------------------------- 3. 整套源码包
Write-Step "打整包 ksu-audit-$Version.zip"
$stageAll = "tmp-build\ksu-audit-$Version"
Remove-Item -Recurse -Force $stageAll -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stageAll | Out-Null

foreach ($f in @('README.md', 'USAGE.md', 'PHONE-README.md', 'NOTICE.md', 'LICENSE')) {
    if (Test-Path $f) { Copy-Item $f $stageAll }
}
foreach ($d in @('docs', 'patches', 'tools', 'bin')) {
    if (Test-Path $d) { Copy-Item -Recurse $d (Join-Path $stageAll $d) }
}
New-Item -ItemType Directory -Force -Path (Join-Path $stageAll 'module') | Out-Null
Copy-Item $moduleZip (Join-Path $stageAll 'module')

$allZip = Join-Path (Resolve-Path $OutDir) "ksu-audit-$Version.zip"
Remove-Item -Force $allZip -ErrorAction SilentlyContinue
Push-Location 'tmp-build'
try {
    & tar --format=zip -cf $allZip "ksu-audit-$Version"
    if ($LASTEXITCODE -ne 0) { throw "打整包失败" }
}
finally { Pop-Location }
Write-Host "  $allZip"

# ---------------------------------------------------------------- 4. 汇总
Write-Step "产物"
Get-ChildItem $OutDir -File | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    "{0,-34} {1,9:N0} bytes  sha256={2}" -f $_.Name, $_.Length, $h
}
Write-Host ""
Write-Host "校验 zip 条目（应无 ./ 前缀、无反斜杠）："
& tar -tf $moduleZip | Select-Object -First 8 | ForEach-Object { "  $_" }
