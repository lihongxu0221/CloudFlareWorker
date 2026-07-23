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
  [string]$RelayAuth = $env:RELAY_AUTH,
  [switch]$WithRelay,
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

function Update-ProxyPool {
  param(
    [string]$Path,
    [string]$Value
  )
  $content = Get-Content -Path $Path -Raw -Encoding UTF8
  $lines = $Value -split '[,;\r\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if (-not $lines) { return }
  $block = "PROXY_POOL = """ + $NL + ($lines -join $NL) + $NL + """"
  if ($content -match '(?s)PROXY_POOL\s*=\s*""".*?"""') {
    $content = [regex]::Replace($content, '(?s)PROXY_POOL\s*=\s*""".*?"""', $block)
  } elseif ($content -match '(?m)^#\s*PROXY_POOL') {
    $content = [regex]::Replace($content, '(?m)^#\s*PROXY_POOL.*', $block, 1)
  } else {
    $content = $content.TrimEnd() + $NL + $block + $NL
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

function Normalize-SecretValue {
  param([string]$Value)
  if ($null -eq $Value) { return "" }
  $v = $Value.Trim()
  # 去掉用户误加的引号 / 管道残留换行
  if (($v.Length -ge 2) -and (
      ($v.StartsWith('"') -and $v.EndsWith('"')) -or
      ($v.StartsWith("'") -and $v.EndsWith("'"))
    )) {
    $v = $v.Substring(1, $v.Length - 2).Trim()
  }
  $v = $v -replace "[\r\n]+$", ""
  return $v
}

function Invoke-WranglerSecretPut {
  param(
    [string]$Name,
    [string]$Value,
    [string]$Config = ""
  )
  # PowerShell 的 `$Value | wrangler secret put` 在 Windows 上不可靠：
  # 1) 管道到 .cmd 时 stdin 常丢失；2) 可能附带 \r\n，导致 QQ 授权码鉴权失败。
  # 经 cmd.exe 重定向 stdin，且只写原始值、不追加换行。
  $useNpx = -not (Test-CommandExists "wrangler")
  $inner = if ($useNpx) {
    "npx --yes wrangler@4 secret put $Name"
  } else {
    "wrangler secret put $Name"
  }
  if ($Config) { $inner = "$inner -c $Config" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = "/d /c $inner"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError = $false
  $psi.CreateNoWindow = $false
  $psi.WorkingDirectory = $Root

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  # 写入值 + 单个 \n（兼容 wrangler readline）；Worker 端会对 secret 做 trim
  # 切勿用 PowerShell 管道（常丢 stdin 或附带 \r\n 脏数据）
  $proc.StandardInput.Write($Value + "`n")
  $proc.StandardInput.Close()
  $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) {
    throw ("secret put 失败: " + $Name + " exit " + $proc.ExitCode)
  }
}

function Set-WranglerSecret {
  param(
    [string]$Name,
    [string]$Value,
    [string]$Config = ""
  )
  $clean = Normalize-SecretValue $Value
  if ([string]::IsNullOrWhiteSpace($clean)) {
    throw ("密钥不能为空: " + $Name)
  }
  if ($clean -ne $Value) {
    Write-Warn ("$Name 已去除首尾空白/引号/换行（原长度 $($Value.Length) → $($clean.Length)）")
  }
  # 授权码只提示长度，不回显内容
  if ($Name -match "AUTH|PASSWORD|CODE") {
    Write-Host ("    写入 $Name （长度 $($clean.Length)）") -ForegroundColor DarkGray
  } else {
    Write-Host ("    写入 $Name") -ForegroundColor DarkGray
  }
  Invoke-WranglerSecretPut -Name $Name -Value $clean -Config $Config
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
  $QqUser = Normalize-SecretValue $QqUser
  $QqAuthCode = Normalize-SecretValue $QqAuthCode
  if ([string]::IsNullOrWhiteSpace($QqUser)) { throw "QQ_MAIL_USER 不能为空" }
  if ([string]::IsNullOrWhiteSpace($QqAuthCode)) { throw "QQ_MAIL_AUTH_CODE 不能为空" }
  if ($QqAuthCode -match "[\r\n]") {
    throw "QQ_MAIL_AUTH_CODE 含有换行，请重新输入（勿粘贴多行）"
  }
  if ($QqAuthCode.Length -lt 6) {
    throw "QQ_MAIL_AUTH_CODE 长度过短（$($QqAuthCode.Length)），请确认是授权码而非登录密码"
  }
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
Write-Host "    若线上 Worker 曾在控制台编辑，将自动确认覆盖" -ForegroundColor DarkGray
$deployLog = Join-Path $env:TEMP ("grokreg-deploy-" + (Get-Date -Format "yyyyMMddHHmmss") + ".log")
try {
  # 用 cmd 管道喂 y：覆盖此前通过 Dashboard/script API 上传的 Worker
  # （PowerShell 管道在部分环境下不会把 y 传给原生交互提示）
  if (Test-CommandExists "wrangler") {
    cmd /c "echo y| wrangler deploy" 2>&1 | Tee-Object -FilePath $deployLog
  } else {
    cmd /c "echo y| npx --yes wrangler@4 deploy" 2>&1 | Tee-Object -FilePath $deployLog
  }
  if ($LASTEXITCODE -ne 0) { throw ("deploy 失败 exit " + $LASTEXITCODE) }
} catch {
  Write-Fail $_.Exception.Message
  if (Test-Path $deployLog) {
    Write-Host ("    日志: " + $deployLog) -ForegroundColor Yellow
  }
  Write-Host "    也可手动执行: npx wrangler@4 deploy  （提示时输入 y）" -ForegroundColor Yellow
  exit 1
}
Write-Ok "部署命令已执行"

if ($WithRelay) {
  Write-Step "部署中继 Worker (relay)"
  if ([string]::IsNullOrWhiteSpace($RelayAuth)) {
    $RelayAuth = Get-InputValue -Prompt "中继共享密钥 RELAY_AUTH"
  }
  $RelayAuth = Normalize-SecretValue $RelayAuth
  if ([string]::IsNullOrWhiteSpace($RelayAuth)) {
    throw "RELAY_AUTH 不能为空（启用代理池必需）"
  }

  $proxyInput = Get-InputValue -Prompt "中继端点 URL（多个用逗号/换行分隔，可留空稍后手动配置 PROXY_POOL）" -Default ""
  $proxyWritten = $false
  if ($proxyInput) {
    Update-ProxyPool -Path $wranglerToml -Value $proxyInput
    Write-Ok "已写入主 Worker 的 PROXY_POOL"
    $proxyWritten = $true
  }

  Set-WranglerSecret -Name "RELAY_AUTH" -Value $RelayAuth
  Write-Ok "主 Worker RELAY_AUTH"
  Set-WranglerSecret -Name "RELAY_AUTH" -Value $RelayAuth -Config "wrangler.relay.toml"
  Write-Ok "中继 Worker RELAY_AUTH"

  if (-not (Test-Path (Join-Path $Root "relay.worker.js"))) {
    Write-Warn "未找到 relay.worker.js，跳过中继部署"
  } else {
    if (Test-CommandExists "wrangler") {
      cmd /c "echo y| wrangler deploy -c wrangler.relay.toml" 2>&1 | Tee-Object -FilePath $deployLog
    } else {
      cmd /c "echo y| npx --yes wrangler@4 deploy -c wrangler.relay.toml" 2>&1 | Tee-Object -FilePath $deployLog
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Warn "中继 Worker 部署失败，请手动: npx wrangler deploy -c wrangler.relay.toml"
    } else {
      Write-Ok "中继 Worker 部署完成"
    }

    if ($proxyWritten) {
      Write-Step "重新部署主 Worker 以生效 PROXY_POOL"
      if (Test-CommandExists "wrangler") {
        cmd /c "echo y| wrangler deploy" 2>&1 | Tee-Object -FilePath $deployLog
      } else {
        cmd /c "echo y| npx --yes wrangler@4 deploy" 2>&1 | Tee-Object -FilePath $deployLog
      }
      Write-Ok "主 Worker 重新部署完成"
    }
  }
}

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
