# 一键启动本地开发环境
# 用法：
#   .\scripts\local-dev.ps1                  # 仅主 Worker :8787
#   .\scripts\local-dev.ps1 -WithRelay       # 主 :8787 + 中继 :8788，并写入本地 PROXY_POOL
#   .\scripts\local-dev.ps1 -Smoke           # 启动后自动跑冒烟测试
#   .\scripts\local-dev.ps1 -WithRelay -Smoke -WithMail

param(
  [switch]$WithRelay,
  [switch]$Smoke,
  [switch]$WithMail,
  [int]$MainPort = 8787,
  [int]$RelayPort = 8788
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

# 确保 .dev.vars 存在
$devVars = Join-Path $Root ".dev.vars"
$example = Join-Path $Root ".dev.vars.example"
if (-not (Test-Path $devVars)) {
  if (Test-Path $example) {
    Copy-Item $example $devVars
    Write-Warn "已从 .dev.vars.example 复制生成 .dev.vars，请按需填写 QQ 凭据"
  } else {
    @"
QQ_MAIL_USER=
QQ_MAIL_AUTH_CODE=
RELAY_AUTH=local-relay-secret
"@ | Set-Content -Path $devVars -Encoding UTF8
    Write-Warn "已创建空的 .dev.vars"
  }
}

# 解析 RELAY_AUTH
$relayAuth = "local-relay-secret"
Get-Content $devVars -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_ -match '^\s*RELAY_AUTH\s*=\s*(.+)\s*$') {
    $relayAuth = $Matches[1].Trim().Trim('"').Trim("'")
  }
}

$wranglerCmd = if (Get-Command wrangler -ErrorAction SilentlyContinue) { "wrangler" } else { "npx --yes wrangler@4" }

# 本地代理池：指向本机中继
$localProxyToml = Join-Path $Root "wrangler.local.toml"
if ($WithRelay) {
  Write-Step "生成本地主 Worker 配置 wrangler.local.toml（PROXY_POOL 指向本机中继）"
  $baseToml = Get-Content (Join-Path $Root "wrangler.toml") -Raw -Encoding UTF8
  # 去掉已有 PROXY_POOL 注释块，追加本地池
  $proxyBlock = @"

# --- local-dev 自动注入 ---
PROXY_POOL = """
http://127.0.0.1:$RelayPort|$relayAuth
"""
PROXY_SELECTION = "round_robin"
PROXY_TIMEOUT_MS = "15000"
PROXY_RETRY = "2"
PROXY_FALLBACK_DIRECT = "1"
RELAY_AUTH = "$relayAuth"
"@
  $content = $baseToml.TrimEnd() + "`n" + $proxyBlock + "`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($localProxyToml, $content, $utf8NoBom)
  Write-Ok "已写入 $localProxyToml"
}

# 中继本地配置（注入 RELAY_AUTH 到 vars，便于 dev 无需 secret）
$localRelayToml = Join-Path $Root "wrangler.relay.local.toml"
if ($WithRelay) {
  Write-Step "生成本地中继配置 wrangler.relay.local.toml"
  $relayContent = @"
name = "grokreg-relay-local"
main = "relay.worker.js"
compatibility_date = "2024-11-01"

[vars]
RELAY_TIMEOUT_MS = "20000"
RELAY_AUTH = "$relayAuth"
"@
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($localRelayToml, $relayContent, $utf8NoBom)
  Write-Ok "已写入 $localRelayToml"
}

$jobs = @()

function Start-WorkerJob {
  param([string]$Name, [string]$Command, [string]$LogFile)
  Write-Step "启动 $Name"
  Write-Host "  $Command" -ForegroundColor DarkGray
  $job = Start-Job -Name $Name -ScriptBlock {
    param($cmd, $cwd, $log)
    Set-Location $cwd
    # 将输出写入日志
    cmd /c "$cmd" > $log 2>&1
  } -ArgumentList $Command, $Root, $LogFile
  return $job
}

$mainLog = Join-Path $Root ".wrangler/local-main.log"
$relayLog = Join-Path $Root ".wrangler/local-relay.log"
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".wrangler") | Out-Null

if ($WithRelay) {
  $relayCmd = "$wranglerCmd dev -c wrangler.relay.local.toml --port $RelayPort --ip 127.0.0.1 --local"
  $jobs += Start-WorkerJob -Name "relay-dev" -Command $relayCmd -LogFile $relayLog
  Start-Sleep -Seconds 2
  $mainCmd = "$wranglerCmd dev -c wrangler.local.toml --port $MainPort --ip 127.0.0.1 --local"
} else {
  $mainCmd = "$wranglerCmd dev --port $MainPort --ip 127.0.0.1 --local"
}
$jobs += Start-WorkerJob -Name "main-dev" -Command $mainCmd -LogFile $mainLog

Write-Step "等待服务就绪 (最多 60s)"
$ready = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$MainPort/health" -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $ready = $true; break }
  } catch {
    Start-Sleep -Seconds 2
  }
}

if (-not $ready) {
  Write-Warn "主 Worker 未在 60s 内就绪，请查看日志:"
  Write-Host "  $mainLog"
  if ($WithRelay) { Write-Host "  $relayLog" }
  Write-Host "也可手动前台启动："
  Write-Host "  npx wrangler@4 dev --port $MainPort --local"
  if ($WithRelay) {
    Write-Host "  npx wrangler@4 dev -c wrangler.relay.local.toml --port $RelayPort --local"
  }
  # 不立刻退出，保留 job 方便用户排查
} else {
  Write-Ok "主 Worker 就绪 http://127.0.0.1:$MainPort"
  if ($WithRelay) {
    try {
      # 中继无 /health，用未授权探测是否在听
      $null = Invoke-WebRequest -Uri "http://127.0.0.1:$RelayPort/fetch" -Method POST -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
    } catch {}
    Write-Ok "中继端口 $RelayPort 已启动（鉴权后可用 /fetch /delete）"
  }
}

if ($Smoke -and $ready) {
  Write-Step "运行冒烟测试"
  $smokeArgs = @{ BaseUrl = "http://127.0.0.1:$MainPort" }
  if ($WithMail) { $smokeArgs.WithMail = $true }
  & (Join-Path $Root "scripts/local-smoke.ps1") @smokeArgs
  $smokeExit = $LASTEXITCODE
} else {
  $smokeExit = 0
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "本地环境已启动" -ForegroundColor Green
Write-Host "  主 Worker:  http://127.0.0.1:$MainPort"
if ($WithRelay) {
  Write-Host "  中继 Worker: http://127.0.0.1:$RelayPort"
  Write-Host "  PROXY_POOL → 本机中继（PROXY_FALLBACK_DIRECT=1）"
}
Write-Host "  日志: $mainLog"
if ($WithRelay) { Write-Host "        $relayLog" }
Write-Host ""
Write-Host "手动冒烟:  powershell -File scripts/local-smoke.ps1"
Write-Host "收信测试:  powershell -File scripts/local-smoke.ps1 -WithMail"
Write-Host "停止:      关闭本窗口，或 Get-Job | Stop-Job; Get-Job | Remove-Job"
Write-Host "========================================" -ForegroundColor Cyan

if (-not $Smoke) {
  Write-Host "按 Ctrl+C 停止所有本地 Worker..." -ForegroundColor Yellow
  try {
    while ($true) {
      $alive = $jobs | Where-Object { $_.State -eq "Running" }
      if (-not $alive) { break }
      Start-Sleep -Seconds 3
    }
  } finally {
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
  }
} else {
  # Smoke 模式：测完后保留服务几秒再退出，或保持运行
  Write-Host "冒烟完成 (exit=$smokeExit)。后台 job 仍在运行；Stop-Job 可停止。" -ForegroundColor Yellow
  Write-Host "  Get-Job | Stop-Job; Get-Job | Remove-Job"
  exit $smokeExit
}
