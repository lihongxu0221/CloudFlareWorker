# 本地冒烟测试：域名池 + 基础路由（不依赖 QQ 凭据）
# 用法：
#   1) 先启动主 Worker：npx wrangler@4 dev --port 8787
#   2) 再跑本脚本：powershell -File scripts/local-smoke.ps1
# 可选：-BaseUrl http://127.0.0.1:8787  -WithMail  (需 .dev.vars 中有 QQ 凭据)

param(
  [string]$BaseUrl = "http://127.0.0.1:8787",
  [switch]$WithMail
)

$ErrorActionPreference = "Stop"
$failed = 0
$passed = 0

function Ok($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:passed++ }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:failed++ }
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Invoke-Json {
  param(
    [string]$Method = "GET",
    [string]$Path,
    [hashtable]$Headers = @{},
    [object]$Body = $null
  )
  $uri = "$BaseUrl$Path"
  $params = @{
    Uri             = $uri
    Method          = $Method
    UseBasicParsing = $true
  }
  if ($Headers.Count) { $params.Headers = $Headers }
  if ($null -ne $Body) {
    $params.ContentType = "application/json; charset=utf-8"
    $params.Body = ($Body | ConvertTo-Json -Compress -Depth 6)
  }
  try {
    $resp = Invoke-WebRequest @params
    $json = $null
    if ($resp.Content) {
      try { $json = $resp.Content | ConvertFrom-Json } catch { $json = $resp.Content }
    }
    return @{ Status = [int]$resp.StatusCode; Json = $json; Raw = $resp.Content }
  } catch {
    $ex = $_.Exception
    $status = 0
    $raw = ""
    if ($ex.Response) {
      $status = [int]$ex.Response.StatusCode
      try {
        $stream = $ex.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $raw = $reader.ReadToEnd()
        $reader.Close()
      } catch {}
    }
    $json = $null
    if ($raw) {
      try { $json = $raw | ConvertFrom-Json } catch { $json = $raw }
    }
    return @{ Status = $status; Json = $json; Raw = $raw; Error = $ex.Message }
  }
}

Write-Host "本地冒烟测试 BaseUrl=$BaseUrl" -ForegroundColor Yellow

# ---------- 1. 健康检查 ----------
Step "GET /health"
$r = Invoke-Json -Path "/health"
if ($r.Status -eq 200 -and $r.Json.ok -eq $true) { Ok "/health ok" } else { Fail "/health status=$($r.Status) body=$($r.Raw)" }

# ---------- 2. 根路径 ----------
Step "GET /"
$r = Invoke-Json -Path "/"
if ($r.Status -eq 200 -and $r.Json.service) { Ok "service=$($r.Json.service)" } else { Fail "GET / status=$($r.Status)" }

# ---------- 3. 域名池 ----------
Step "GET /api/domains"
$r = Invoke-Json -Path "/api/domains"
if ($r.Status -ne 200) {
  Fail "/api/domains status=$($r.Status) $($r.Raw)"
} else {
  $domains = @($r.Json.results | ForEach-Object { $_.domain })
  if ($domains.Count -ge 1) {
    Ok "域名池数量=$($domains.Count): $($domains -join ', ')"
  } else {
    Fail "域名池为空"
  }
  $script:domainList = $domains
}

# ---------- 4. 生成地址（域名池选域 + token 编码） ----------
Step "POST /api/new_address x3（验证域名轮换与 token 下标）"
$tokens = @()
$addrs = @()
$indices = @()
for ($i = 0; $i -lt 3; $i++) {
  $r = Invoke-Json -Method POST -Path "/api/new_address" -Body @{ name = "smoketest$i" }
  if ($r.Status -ne 200) {
    Fail "new_address#$i status=$($r.Status) $($r.Raw)"
    continue
  }
  $addr = [string]$r.Json.address
  $tok = [string]$r.Json.token
  $idx = $r.Json.domainIndex
  $dom = [string]$r.Json.domain
  $addrs += $addr
  $tokens += $tok
  $indices += $idx
  Write-Host "    address=$addr token=$tok domain=$dom index=$idx" -ForegroundColor DarkGray

  if (-not $addr -or -not $tok) {
    Fail "new_address#$i 缺少 address/token"
    continue
  }
  if ($addr -notmatch "@") {
    Fail "new_address#$i address 格式异常: $addr"
    continue
  }
  $local = $addr.Split("@")[0]
  $domain = $addr.Split("@")[1]
  if ($script:domainList -and ($script:domainList -notcontains $domain)) {
    Fail "new_address#$i 域名 $domain 不在池中"
  } else {
    Ok "new_address#$i 域名在池中: $domain"
  }

  # token 编码：多域名时为 localPart.N；单域名可为纯 localPart
  if ($script:domainList.Count -gt 1) {
    if ($tok -match "\.(\d+)$") {
      $encIdx = [int]$Matches[1]
      if ($null -ne $idx -and $encIdx -ne [int]$idx) {
        Fail "token 下标 $encIdx 与 domainIndex $idx 不一致"
      } else {
        Ok "token 编码下标=$encIdx 与 domainIndex 一致"
      }
      if ($script:domainList[$encIdx] -ne $domain) {
        Fail "token 下标 $encIdx 对应域名应为 $($script:domainList[$encIdx])，实际 $domain"
      } else {
        Ok "token 下标映射域名正确"
      }
    } else {
      Fail "多域名时 token 应含下标，实际: $tok"
    }
  } else {
    Ok "单域名 token=$tok（兼容旧格式）"
  }

  if ($local -and $tok.StartsWith($local) -eq $false -and $tok -ne $local) {
    # token 可能是 name.N 或 random.N
    if ($tok -notmatch "^[a-z0-9]+(\.\d+)?$") {
      Fail "token 格式异常: $tok"
    }
  }
}

if ($script:domainList.Count -gt 1 -and $indices.Count -ge 2) {
  $uniq = $indices | Select-Object -Unique
  if ($uniq.Count -ge 2) {
    Ok "round_robin 选域生效（下标有变化: $($indices -join ',')）"
  } else {
    # 不强制失败：hash 策略或并发下可能相同
    Write-Host "  [WARN] 三次选域下标相同: $($indices -join ',')（若 DOMAIN_SELECTION=hash 属正常）" -ForegroundColor Yellow
  }
}

# ---------- 5. token 透传 ----------
Step "POST /api/token"
if ($tokens.Count -gt 0) {
  $t = $tokens[0]
  $r = Invoke-Json -Method POST -Path "/api/token" -Headers @{ Authorization = "Bearer $t" }
  if ($r.Status -eq 200 -and [string]$r.Json.token -eq $t) {
    Ok "token 透传一致: $t"
  } else {
    Fail "token 透传失败 status=$($r.Status) body=$($r.Raw)"
  }
} else {
  Fail "无可用 token，跳过 /api/token"
}

# ---------- 6. 可选：真实收信 ----------
if ($WithMail) {
  Step "GET /api/mails（需要 .dev.vars 中 QQ 凭据）"
  if ($tokens.Count -eq 0) {
    Fail "无 token，无法测收信"
  } else {
    $t = $tokens[0]
    $r = Invoke-Json -Method GET -Path "/api/mails?limit=5" -Headers @{ Authorization = "Bearer $t" }
    if ($r.Status -eq 200 -and $null -ne $r.Json.messages) {
      Ok "收信成功 count=$($r.Json.count)"
    } elseif ($r.Status -eq 500 -and $r.Json.error -match "缺少|授权|认证|login|auth|USER|PASS") {
      Fail "收信失败（凭据/鉴权）: $($r.Json.error)"
    } else {
      Fail "收信异常 status=$($r.Status) body=$($r.Raw)"
    }
  }
} else {
  Write-Host "`n(跳过收信测试；加 -WithMail 且配置 .dev.vars 可测真实 QQ 收信)" -ForegroundColor DarkGray
}

# ---------- 汇总 ----------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "通过 $passed  失败 $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "========================================" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 } else { exit 0 }
