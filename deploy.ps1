#Requires -Version 5.1
<#
.SYNOPSIS
  GrokReg Cloudflare Worker 一键部署脚本 (Windows PowerShell)

.DESCRIPTION
  检查 Node.js / Wrangler、登录 Cloudflare、写入域名配置、注入 QQ 邮箱密钥并部署。
  Worker 通过 QQ 邮箱 POP3 读信、IMAP 真正删信（默认双通道）。
  若缺少 wrangler.toml，会自动从 wrangler.toml.example 复制。

  交互:
    .\deploy.ps1

  非交互:
    .\deploy.ps1 -Domain mail.example.com -QqUser 123456789@qq.com -QqAuthCode 授权码 -Yes

.PARAMETER Domain
  临时邮箱域名 (DOMAIN)

.PARAMETER QqUser
  QQ 邮箱账号

.PARAMETER QqAuthCode
  QQ 邮箱授权码（POP3/IMAP 共用，非登录密码）

.PARAMETER WorkerName
  Worker 名称，默认 grokreg-mail

.PARAMETER StrictAlias
  开启 QQ_STRICT_ALIAS_MATCH=1

.PARAMETER SkipLogin
  跳过 wrangler login

.PARAMETER SkipSecrets
  跳过密钥注入

.PARAMETER SkipDeploy
  只写配置不部署

.PARAMETER Yes
  减少确认提问
#>

[CmdletBinding()]
param(
  [string]$Domain = $env:DOMAIN,
  [string]$QqUser = $(if ($env:QQ_MAIL_USER) { $env:QQ_MAIL_USER } else { $env:QQ_MAIL_ACCOUNT }),
  [string]$QqAuthCode = $(if ($env:QQ_MAIL_AUTH_CODE) { $env:QQ_MAIL_AUTH_CODE } else { $env:QQ_MAIL_PASSWORD }),
  [string]$WorkerName = $(if ($env:WORKER_NAME) { $env:WORKER_NAME } else { "grokreg-mail" }),
  [switch]$StrictAlias,
  [switch]$SkipLogin,
  [switch]$SkipSecrets,
  [switch]$SkipDeploy,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $Root
$NL = [Environment]::NewLine
$Q = [char]34

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host ("==> " + $Message) -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host ("    OK: " + $Message) -ForegroundColor Green
}

function Write-Warn([string]$Message) {
  Write-Host ("    WARN: " + $Message) -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
  Write-Host ("    FAIL: " + $Message) -ForegroundColor Red
}

function Test-CommandExists([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-InputValue {
  param(
    [string]$Prompt,
    [string]$Default = "",
    [switch]$Secret
  )
  if ($Default) {
    $label = $Prompt + " [" + $Default + "]"
  } else {
    $label = $Prompt
  }
  if ($Secret) {
    $secure = Read-Host $label -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  } else {
    $value = Read-Host $label
  }
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value.Trim()
}

function Update-WranglerToml {
  param(
    [string]$Path,
    [string]$Name,
    [string]$DomainValue,
    [bool]$EnableStrict
  )
  if (-not (Test-Path $Path)) {
    throw ("未找到 wrangler.toml: " + $Path)
  }
  $content = Get-Content -Path $Path -Raw -Encoding UTF8

  $namePattern = "(?m)^name\s*=\s*" + $Q + ".*" + $Q
  $domainPattern = "(?m)^DOMAIN\s*=\s*" + $Q + ".*" + $Q
  $strictCommented = "(?m)^#\s*QQ_STRICT_ALIAS_MATCH\s*=\s*" + $Q + "1" + $Q + "\s*$"
  $strictActive = "(?m)^QQ_STRICT_ALIAS_MATCH\s*="
  $strictLine = "QQ_STRICT_ALIAS_MATCH = " + $Q + "1" + $Q

  if ($content -match $namePattern) {
    $content = [regex]::Replace($content, $namePattern, ("name = {0}{1}{0}" -f $Q, $Name))
  } else {
    $content = ("name = {0}{1}{0}" -f $Q, $Name) + $NL + $content
  }

  if ($content -match $domainPattern) {
    $content = [regex]::Replace($content, $domainPattern, ("DOMAIN = {0}{1}{0}" -f $Q, $DomainValue))
  } else {
    throw "wrangler.toml 中未找到 DOMAIN 配置行"
  }

  if ($EnableStrict) {
    $content = [regex]::Replace($content, $strictCommented, $strictLine)
    if ($content -notmatch $strictActive) {
      $content = $content.TrimEnd() + $NL + $strictLine + $NL
    }
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
}

function Invoke-Wrangler {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$WranglerArgs)
  if (Test-CommandExists "wrangler") {
    & wrangler @WranglerArgs
    if ($LASTEXITCODE -ne 0) {
      throw ("wrangler 失败: " + ($WranglerArgs -join " ") + " exit " + $LASTEXITCODE)
    }
    return
  }
  & npx --yes wrangler@4 @WranglerArgs
  if ($LASTEXITCODE -ne 0) {
    throw ("npx wrangler 失败: " + ($WranglerArgs -join " ") + " exit " + $LASTEXITCODE)
  }
}

function Set-WranglerSecret {
  param(
    [string]$Name,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw ("密钥不能为空: " + $Name)
  }
  if (Test-CommandExists "wrangler") {
    $Value | & wrangler secret put $Name
  } else {
    $Value | & npx --yes wrangler@4 secret put $Name
  }
  if ($LASTEXITCODE -ne 0) {
    throw ("secret put 失败: " + $Name + " exit " + $LASTEXITCODE)
  }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  GrokReg Worker 一键部署 (PowerShell)" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ("工作目录: " + $Root)

Write-Step "检查项目文件"
$workerJs = Join-Path $Root "grokreg.worker.js"
$wranglerToml = Join-Path $Root "wrangler.toml"
$wranglerExample = Join-Path $Root "wrangler.toml.example"
if (-not (Test-Path $workerJs)) { throw "缺少 grokreg.worker.js" }
if (-not (Test-Path $wranglerToml)) {
  if (Test-Path $wranglerExample) {
    Copy-Item -Path $wranglerExample -Destination $wranglerToml
    Write-Warn "未找到 wrangler.toml，已从 wrangler.toml.example 复制"
  } else {
    throw "缺少 wrangler.toml 与 wrangler.toml.example"
  }
}
Write-Ok "grokreg.worker.js / wrangler.toml"

Write-Step "检查 Node.js"
if (-not (Test-CommandExists "node")) {
  Write-Fail "未检测到 Node.js"
  Write-Host "    请安装 Node.js 18+: https://nodejs.org/" -ForegroundColor Yellow
  exit 1
}
$nodeVer = (& node -v).Trim()
Write-Ok ("Node.js " + $nodeVer)
if ($nodeVer -match "^v(\d+)") {
  $major = [int]$Matches[1]
  if ($major -lt 18) {
    Write-Warn ("建议使用 Node.js 18 及以上，当前 " + $nodeVer)
  }
}

Write-Step "检查 Wrangler"
if (Test-CommandExists "wrangler") {
  $wVer = (& wrangler --version 2>$null)
  Write-Ok ("已安装 wrangler: " + $wVer)
} else {
  Write-Warn "未找到全局 wrangler，将使用 npx wrangler@4"
  if (-not (Test-CommandExists "npx")) {
    Write-Fail "未找到 npx，请先安装 Node.js / npm"
    exit 1
  }
  Write-Ok "npx 可用"
}

if (-not $SkipLogin) {
  Write-Step "Cloudflare 登录状态"
  $whoamiOut = $null
  try {
    if (Test-CommandExists "wrangler") {
      $whoamiOut = & wrangler whoami 2>&1 | Out-String
    } else {
      $whoamiOut = & npx --yes wrangler@4 whoami 2>&1 | Out-String
    }
  } catch {
    $whoamiOut = ""
  }
  if ($whoamiOut -match "You are not authenticated|not logged in|Not logged in|Error" -or [string]::IsNullOrWhiteSpace($whoamiOut)) {
    Write-Warn "未登录或无法确认，即将打开浏览器登录..."
    Invoke-Wrangler login
  } else {
    Write-Ok "已登录 Cloudflare"
    if (-not $Yes) {
      Write-Host $whoamiOut.Trim()
    }
  }
} else {
  Write-Step "跳过登录检查 (-SkipLogin)"
}

Write-Step "收集部署配置"
if ([string]::IsNullOrWhiteSpace($Domain)) {
  $Domain = Get-InputValue -Prompt "临时邮箱域名 DOMAIN (如 mail.example.com)"
}
if ([string]::IsNullOrWhiteSpace($Domain)) {
  throw "DOMAIN 不能为空"
}
if ($Domain -notmatch "^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$") {
  Write-Warn ("DOMAIN 格式可能不正确: " + $Domain)
}

if (-not $SkipSecrets) {
  if ([string]::IsNullOrWhiteSpace($QqUser)) {
    $QqUser = Get-InputValue -Prompt "QQ 邮箱账号 QQ_MAIL_USER"
  }
  if ([string]::IsNullOrWhiteSpace($QqAuthCode)) {
    $QqAuthCode = Get-InputValue -Prompt "QQ 邮箱授权码 QQ_MAIL_AUTH_CODE" -Secret
  }
  if ([string]::IsNullOrWhiteSpace($QqUser)) { throw "QQ_MAIL_USER 不能为空" }
  if ([string]::IsNullOrWhiteSpace($QqAuthCode)) { throw "QQ_MAIL_AUTH_CODE 不能为空" }
}

if (-not $StrictAlias -and $env:QQ_STRICT_ALIAS_MATCH -eq "1") {
  $StrictAlias = $true
}
if (-not $StrictAlias -and -not $Yes) {
  $ans = Get-InputValue -Prompt "是否开启严格别名匹配 QQ_STRICT_ALIAS_MATCH=1? (y/N)" -Default "N"
  if ($ans -match "^[yY]") { $StrictAlias = $true }
}

Write-Host ""
Write-Host ("    Worker 名称 : " + $WorkerName)
Write-Host ("    DOMAIN      : " + $Domain)
Write-Host ("    严格别名    : " + $StrictAlias)
if (-not $SkipSecrets) {
  Write-Host ("    QQ 账号     : " + $QqUser)
  Write-Host "    授权码      : ********"
}

if (-not $Yes) {
  $confirm = Get-InputValue -Prompt "确认以上配置并继续? (Y/n)" -Default "Y"
  if ($confirm -match "^[nN]") {
    Write-Warn "已取消"
    exit 0
  }
}

Write-Step "更新 wrangler.toml"
Update-WranglerToml -Path $wranglerToml -Name $WorkerName -DomainValue $Domain -EnableStrict:([bool]$StrictAlias)
if ($StrictAlias) {
  Write-Ok "已写入 name / DOMAIN / QQ_STRICT_ALIAS_MATCH"
} else {
  Write-Ok "已写入 name / DOMAIN"
}

if (-not $SkipSecrets) {
  Write-Step "注入 Secrets"
  Set-WranglerSecret -Name "QQ_MAIL_USER" -Value $QqUser
  Write-Ok "QQ_MAIL_USER"
  Set-WranglerSecret -Name "QQ_MAIL_AUTH_CODE" -Value $QqAuthCode
  Write-Ok "QQ_MAIL_AUTH_CODE"
} else {
  Write-Step "跳过密钥注入 (-SkipSecrets)"
}

if ($SkipDeploy) {
  Write-Step "跳过部署 (-SkipDeploy)"
  Write-Ok "配置已完成"
  exit 0
}

Write-Step "执行 wrangler deploy"
$deployLog = Join-Path $env:TEMP ("grokreg-deploy-" + (Get-Date -Format "yyyyMMddHHmmss") + ".log")
try {
  if (Test-CommandExists "wrangler") {
    & wrangler deploy 2>&1 | Tee-Object -FilePath $deployLog
  } else {
    & npx --yes wrangler@4 deploy 2>&1 | Tee-Object -FilePath $deployLog
  }
  if ($LASTEXITCODE -ne 0) { throw ("deploy 失败 exit " + $LASTEXITCODE) }
} catch {
  Write-Fail $_.Exception.Message
  if (Test-Path $deployLog) {
    Write-Host ("    日志: " + $deployLog) -ForegroundColor Yellow
  }
  exit 1
}
Write-Ok "部署命令已执行"

Write-Step "冒烟测试 /api/domains"
$logText = if (Test-Path $deployLog) { Get-Content $deployLog -Raw -Encoding UTF8 } else { "" }
$baseUrl = $null
if ($logText -match "https://[a-zA-Z0-9._-]+\.workers\.dev") {
  $baseUrl = $Matches[0].TrimEnd("/")
}
if (-not $baseUrl) {
  Write-Warn "未能从输出解析 workers.dev URL，请手动访问 /api/domains 验证"
} else {
  Write-Ok ("Worker URL: " + $baseUrl)
  try {
    $resp = Invoke-RestMethod -Uri ($baseUrl + "/api/domains") -Method Get -TimeoutSec 30
    $json = $resp | ConvertTo-Json -Compress
    Write-Ok ("GET /api/domains => " + $json)
  } catch {
    Write-Warn ("冒烟测试失败: " + $_.Exception.Message)
    Write-Warn ("若刚部署完成，可稍后再试: " + $baseUrl + "/api/domains")
  }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  部署完成" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
if ($baseUrl) {
  Write-Host "API 示例:"
  Write-Host ("  " + $baseUrl + "/api/domains")
  Write-Host ("  " + $baseUrl + "/api/new_address")
}
Write-Host "更多说明: README.md / Deploy.md"
Write-Host ""
