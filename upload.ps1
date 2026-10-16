# upload.ps1 -- 把本地仓库推送到远端（token 只从环境变量读取，不落盘、不回显）
#
# 用法：
#   $env:GITHUB_TOKEN = 'ghp_xxx'                  # 只在本会话内
#   ./upload.ps1 -RepoUrl https://github.com/<you>/<repo>.git -Branch main
#
#   仓库还不存在时（先建仓库再推）：
#   ./upload.ps1 -RepoUrl <you>/<repo> -CreateIfMissing -Branch main
#
# 参数：
#   -RepoUrl        远端地址，支持 https URL / git@ URL / "owner/repo" 简写
#   -Branch         要推送的本地分支；省略则用当前 HEAD 分支
#   -RemoteName     远端名，默认 origin
#   -User           token 的 URL 占位用户名，默认 x-access-token（GitHub 推荐）
#   -CreateIfMissing 仓库不存在时用 REST API 创建（需要 token 有 repo 权限）
#   -DryRun         只打印将要执行的命令

param(
    [Parameter(Mandatory = $true)][string]$RepoUrl,
    [string]$Branch = '',
    [string]$RemoteName = 'origin',
    [string]$User = 'x-access-token',
    [switch]$CreateIfMissing,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$mask = '<token>'

function Get-Token {
    foreach ($n in @('GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_PAT')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { return $v }
    }
    return $null
}

function Normalize-Url([string]$u) {
    if ($u -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return "https://github.com/$u.git" }
    return $u
}

$url = Normalize-Url $RepoUrl
if (-not $Branch) {
    $Branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Branch) { throw "无法确定当前分支：请在 git 仓库内运行，或用 -Branch 指定" }
}

# owner/repo（同时支持任何 https git 主机）
if ($url -notmatch '^[a-z]+://' -and $url -notmatch '^git@') { throw "无法识别的远端地址：$RepoUrl" }
$isGithub = $url -match 'github\.com'
$slug = $null
if ($url -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') { $slug = "$($Matches[1])/$($Matches[2])" }

Write-Host "远端      : $url"
Write-Host "分支      : $Branch"
Write-Host "远端名    : $RemoteName"
Write-Host "GitHub    : $isGithub $(if ($slug) { "($slug)" })"

$token = Get-Token
if (-not $token) {
    Write-Host ""
    Write-Host "没有找到 token。请先设置其一（只在当前会话生效）：" -ForegroundColor Yellow
    Write-Host "  `$env:GITHUB_TOKEN = 'ghp_xxxxxxxxxxxx'"
    Write-Host "然后重跑本脚本。token 需要 repo 权限（fine-grained: Contents=Read/Write，新建仓库另需 Administration 或改用已存在的仓库）。"
    exit 2
}

# --- 可选：仓库不存在就创建 ---
if ($CreateIfMissing -and $isGithub -and $slug) {
    $owner, $name = $slug.Split('/')
    $probe = & curl.exe -s -o NUL -w "%{http_code}" -H "Authorization: Bearer $token" "https://api.github.com/repos/$slug"
    if ($probe -eq '200') {
        Write-Host "仓库已存在，跳过创建。"
    }
    elseif ($probe -eq '404') {
        Write-Host "仓库不存在，创建中：$slug" -ForegroundColor Yellow
        $body = @{ name = $name; private = $true; has_issues = $true } | ConvertTo-Json -Compress
        $tmp = New-TemporaryFile
        [System.IO.File]::WriteAllText($tmp.FullName, $body)
        $code = & curl.exe -s -o NUL -w "%{http_code}" -X POST `
            -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" `
            --data-binary "@$($tmp.FullName)" "https://api.github.com/user/repos"
        Remove-Item $tmp -Force
        if ($code -notin @('201', '200')) { throw "创建仓库失败（HTTP $code）——若是组织仓库，请手工创建后再推。" }
        Write-Host "创建成功（private=true，按需改成 public）。"
    }
    else {
        Write-Host "探测仓库返回 HTTP $probe，继续尝试推送。"
    }
}

# --- 组装带 token 的推送地址 ---
$pushUrl = $url
if ($url -match '^https://') {
    $pushUrl = $url -replace '^https://', "https://$User`:$token@"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN:"
    Write-Host "  git remote add|set-url $RemoteName $($pushUrl.Replace($token, $mask))"
    Write-Host "  git push -u $RemoteName $Branch"
    exit 0
}

# --- 配置 remote 并推送 ---
$existing = & git remote 2>$null
if ($existing -contains $RemoteName) {
    & git remote set-url $RemoteName $pushUrl
}
else {
    & git remote add $RemoteName $pushUrl
}
if ($LASTEXITCODE -ne 0) { throw "配置 remote 失败" }

Write-Host "推送中：git push -u $RemoteName $Branch"
& git push -u $RemoteName $Branch
$code = $LASTEXITCODE

# 推完把 URL 里的 token 抹掉，避免留在 .git/config
& git remote set-url $RemoteName $url
if ($code -ne 0) {
    Write-Host "推送失败（exit=$code）。常见原因：token 无 repo 权限、分支受保护、远端已有历史需要 --force-with-lease。" -ForegroundColor Yellow
    exit $code
}
Write-Host "完成：$slug $Branch" -ForegroundColor Green
