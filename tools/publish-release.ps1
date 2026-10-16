# publish-release.ps1 -- 在 GitHub 上创建 Release 并上传附件
#
# token 来源（按顺序）：环境变量 GITHUB_TOKEN / GH_TOKEN，或本机 git 凭据（git credential fill）。
# token 只用于 api.github.com 请求，不落盘、不回显。
#
# 用法：
#   ./tools/publish-release.ps1 -Tag v1.0.0 -Name "..." -BodyFile docs/release-notes-v1.0.0.md `
#       -Assets dist/ksu-audit-v1.0.0.zip,dist/ksu-hide-verify-v1.0.0.zip
#
#   -DryRun   只打印计划，不发请求

param(
    [string]$Repo = 'luoluonb/ksu-audit',
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Name = '',
    [string]$BodyFile = '',
    [string[]]$Assets = @(),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $Name) { $Name = $Tag }

function Get-Token {
    foreach ($n in @('GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_PAT')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { return $v }
    }
    # 退回本机 git 凭据（git-credential-manager 存在时可用）
    $env:GIT_TERMINAL_PROMPT = '0'
    $out = "protocol=https`nhost=github.com`n`n" | & git credential fill 2>$null
    foreach ($line in $out) {
        if ($line -match '^password=(.+)$') { return $Matches[1] }
    }
    return $null
}

$token = Get-Token
if (-not $token) { throw "没有可用 token：请设置 `$env:GITHUB_TOKEN，或先 git push 一次让凭据管理器记住凭据" }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'ksu-audit-release'
}
$api = "https://api.github.com/repos/$Repo"

Write-Host "仓库     : $Repo"
Write-Host "Tag      : $Tag"
Write-Host "附件     : $(if ($Assets.Count) { $Assets -join ', ' } else { '(无)' })"
if ($BodyFile) { Write-Host "说明文件 : $BodyFile" }

if ($DryRun) {
    Write-Host "DRY RUN：跳过所有网络请求"
    exit 0
}

# --- 1. 已存在则复用，否则创建 ---
$existing = $null
try {
    $existing = Invoke-RestMethod -Uri "$api/releases/tags/$Tag" -Headers $headers -Method Get
    Write-Host "已存在同名 Release，复用：$($existing.html_url)"
}
catch { $existing = $null }

if (-not $existing) {
    $body = @{ tag_name = $Tag; name = $Name; draft = $false; prerelease = $false }
    if ($BodyFile) { $body.body = [System.IO.File]::ReadAllText((Resolve-Path $BodyFile).Path) }
    $json = $body | ConvertTo-Json -Depth 4
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $created = Invoke-RestMethod -Uri "$api/releases" -Headers $headers -Method Post -Body $bytes `
        -ContentType 'application/json; charset=utf-8'
    Write-Host "Release 创建成功：$($created.html_url)"
    $release = $created
}
else { $release = $existing }

# --- 2. 上传附件 ---
$uploadBase = $release.upload_url -replace '\{\?name,label\}$', ''
foreach ($a in $Assets) {
    $path = (Resolve-Path $a).Path
    $fileName = [System.IO.Path]::GetFileName($path)
    $url = "$uploadBase?name=$([uri]::EscapeDataString($fileName))"
    $fbytes = [System.IO.File]::ReadAllBytes($path)
    $upHeaders = $headers.Clone()
    $upHeaders['Content-Type'] = 'application/zip'
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $upHeaders -Method Post -Body $fbytes
        Write-Host ("  已上传 {0}  ({1:N0} bytes)  -> {2}" -f $fileName, $fbytes.Length, $r.browser_download_url)
    }
    catch {
        Write-Host ("  上传 {0} 失败：{1}" -f $fileName, $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host "完成：$($release.html_url)" -ForegroundColor Green
