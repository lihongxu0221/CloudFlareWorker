# 部署说明（Deploy）

本文档说明如何将 `grokreg.worker.js` 部署到 Cloudflare Workers。

更完整的功能说明与 API 文档见 [README.md](./README.md)。

---

## 一、部署前检查清单

| 步骤 | 内容 | 状态 |
|------|------|------|
| 1 | QQ 邮箱已开启 **POP3/SMTP** 与 **IMAP/SMTP**，并取得**授权码** | ☐ |
| 2 | 域名邮件已转发/代收到该 QQ 邮箱 | ☐ |
| 3 | 已有 Cloudflare 账号 | ☐ |
| 4 | 已准备好 `DOMAIN`（临时邮箱域名） | ☐ |
| 5 | 仓库中有可部署的 `wrangler.toml`（无密钥），`DOMAIN` 已改成真实域名 | ☐ |
| 6 | 运行时 Secrets 已配置：`QQ_MAIL_USER`、`QQ_MAIL_AUTH_CODE` | ☐ |

### 配置文件说明

| 文件 | 是否提交 Git | 说明 |
|------|--------------|------|
| `wrangler.toml` | **是** | 生产/Git 部署用，只放非敏感 `[vars]` |
| `wrangler.toml.example` | 是 | 模板，给 fork / 新环境参考 |
| `.dev.vars` | **否** | 本地调试密钥，已在 `.gitignore` |

密钥（`QQ_MAIL_USER` / `QQ_MAIL_AUTH_CODE`）**永远不要**写进 `wrangler.toml`，用 Dashboard Secrets 或 `wrangler secret put`。

若本地没有 `wrangler.toml`，可从模板复制：

```bash
cp wrangler.toml.example wrangler.toml
# Windows: Copy-Item wrangler.toml.example wrangler.toml
```

一键脚本也会在缺失时自动复制。

---

## 二、方式 A：Cloudflare Git 自动部署（推荐）

适合已把仓库接到 Cloudflare Workers Builds 的场景。

### A1. Build 配置（Workers → 你的 Worker → Settings → Build）

| 项 | 建议值 |
|----|--------|
| Git repository | 本仓库 |
| Build command | 留空 / None |
| Deploy command | `npx wrangler deploy` |
| Version command | `npx wrangler versions upload`（可默认） |
| Root directory | `/` |
| Production branch | `main` |

仓库已包含 `wrangler.toml` 时，**不要**再写 `cp wrangler.toml.example ...`。

### A2. 变量命名（极易配错）

Worker 代码只认下列名字（**区分大小写**）：

| 正确 Name | Type | 说明 |
|-----------|------|------|
| `DOMAIN` | Variable | 临时邮箱域名，如 `juc114.cn` |
| `QQ_MAIL_USER` | **Secret** | QQ 邮箱账号 |
| `QQ_MAIL_AUTH_CODE` | **Secret** | QQ 邮箱授权码（不是登录密码） |

**不要**使用本地脚本参数名：

| 错误 Name | 原因 |
|-----------|------|
| `QqUser` | 仅 `deploy.ps1` 参数，Worker 不读 |
| `QqAuthCode` | 仅 `deploy.ps1` 参数，Worker 不读 |
| `WorkerName` | 仅部署脚本参数，运行时无用 |

### A3. 两处都要配清楚

1. **Settings → Variables and Secrets（运行时，必做）**  
   这里的值会注入到 Worker `env`，线上接口依赖这里。
2. **Build → Variables and secrets（可选）**  
   主要给构建过程用；若 Git 部署时用 wrangler 写 secret，可在此配置，但**不能替代**运行时 Secrets。

推荐最小运行时配置：

| Type | Name | Value |
|------|------|--------|
| Variable | `DOMAIN` | `juc114.cn` |
| Secret | `QQ_MAIL_USER` | `你的QQ@qq.com` |
| Secret | `QQ_MAIL_AUTH_CODE` | `授权码` |

可选（`wrangler.toml` 已有默认值时可不在 Dashboard 重复）：

- `QQ_MAIL_HOST` / `QQ_MAIL_PORT`
- `QQ_IMAP_HOST` / `QQ_IMAP_PORT`
- `QQ_FETCH_LIMIT`
- `QQ_STRICT_ALIAS_MATCH=1`（多账号并发时）

### A4. 首次启用步骤

1. 确认仓库 `main` 上有 `wrangler.toml` 与 `grokreg.worker.js`
2. 在 **Settings → Variables and Secrets** 配好上表三项
3. 删除 Build 里错误的 `QqUser` / `QqAuthCode` / `WorkerName`（若仍存在）
4. 推送任意 commit，或点 **Retry deployment**
5. Build 成功后做冒烟测试（见文末）

### A5. 常见失败

| 现象 | 原因 | 处理 |
|------|------|------|
| Build 失败：找不到 config | 仓库无 `wrangler.toml` | 提交本仓库的 `wrangler.toml` |
| `/api/mails` 500 / 缺少 QQ_MAIL_* | Secret 名错误或未配运行时 | 改为 `QQ_MAIL_USER` / `QQ_MAIL_AUTH_CODE` |
| 域名不对 | `DOMAIN` 未更新 | 改 `wrangler.toml` 的 `[vars].DOMAIN` 或 Dashboard Variable |
| 鉴权失败 | 授权码含换行/错误 | 重新在 Dashboard 写入 Secret |

---

## 三、方式 B：控制台粘贴代码部署（无需本地工具）

适合快速上线，不装 Node / Wrangler。

### 1. 创建 Worker

1. 打开 [Cloudflare Dashboard](https://dash.cloudflare.com)
2. 进入 **Workers & Pages** → **Create** → **Create Worker**
3. 名称建议：`grokreg-mail`
4. 点击 **Deploy**

### 2. 粘贴代码

1. 进入该 Worker → **Edit code**
2. 删除编辑器中的默认代码
3. 将本仓库 [`grokreg.worker.js`](./grokreg.worker.js) **全部内容**粘贴进去
4. 点击 **Deploy**

### 3. 配置环境变量

进入 **Settings → Variables and Secrets**，添加：

| 类型 | 变量名 | 示例值 | 说明 |
|------|--------|--------|------|
| Text / Secret | `DOMAIN` | `mail.example.com` | 临时邮箱域名 |
| Secret（推荐） | `QQ_MAIL_USER` | `123456789@qq.com` | QQ 邮箱账号 |
| Secret（推荐） | `QQ_MAIL_AUTH_CODE` | `xxxxxxxx` | 授权码（POP3/IMAP 共用），**非登录密码** |

可选：

| 变量名 | 默认 | 说明 |
|--------|------|------|
| `DOMAIN` | — | **域名池**：换行/逗号/分号分隔多个域名；单域名向后兼容 |
| `DOMAIN_SELECTION` | `round_robin` | 选域策略：`round_robin` / `random` / `hash` |
| `QQ_MAIL_HOST` | `pop.qq.com` | POP3 主机 |
| `QQ_MAIL_PORT` | `995` | POP3 SSL 端口 |
| `QQ_IMAP_HOST` | `imap.qq.com` | IMAP 主机（删信用） |
| `QQ_IMAP_PORT` | `993` | IMAP SSL 端口 |
| `QQ_IMAP_DELETE` | `1` | 设为 `0` 仅 POP3 删除，不走 IMAP |
| `QQ_FETCH_LIMIT` | `20` | 默认拉信条数（最大 50） |
| `QQ_STRICT_ALIAS_MATCH` | 空 | 设为 `1` 开启严格别名匹配 |
| `PROXY_POOL` | 空 | **中继代理池**：换行/逗号分隔的中继 URL，可 `url\|secret` 指定条目密钥 |
| `PROXY_SELECTION` | `round_robin` | 代理调度：`round_robin` / `random` / `least_failures` |
| `PROXY_TIMEOUT_MS` | `15000` | 单中继超时（毫秒） |
| `PROXY_RETRY` | `2` | 失败后重试的中继数 |
| `RELAY_AUTH` | 空 | 调用中继的共享密钥（`PROXY_POOL` 非空时必填） |
| `PROXY_FALLBACK_DIRECT` | `0` | 全部中继失败回退本地直连：`1` 开启 |

修改变量后如未自动生效，可再 **Deploy** 一次或稍等片刻。

### 4. （可选）绑定自定义域名

**Settings → Domains & Routes → Add**，绑定如 `api.mail.example.com`。

### 5. 验证

浏览器或命令行访问：

```text
https://<你的worker名>.<subdomain>.workers.dev/api/domains
```

期望返回类似：

```json
{
  "results": [
    { "domain": "mail.example.com", "isVerified": true }
  ]
}
```

---

## 四、方式 C：一键部署脚本

项目根目录提供脚本，自动完成：检查 Node → 登录 Cloudflare → 写入 `DOMAIN` → 注入密钥 → `wrangler deploy` → 冒烟测试。

仓库已包含 `wrangler.toml` 时可直接部署；若本地缺失，脚本会从 `wrangler.toml.example` 复制。

> 注意：脚本参数 `-QqUser` / `-QqAuthCode` / `-WorkerName` 只是本地入参，注入到 Cloudflare 时会写成 `QQ_MAIL_USER` / `QQ_MAIL_AUTH_CODE` 与 `wrangler.toml` 的 `name`。

### Windows（PowerShell）

```powershell
cd d:\AILocal\Tools\CloudFlareWorker

# 交互式（按提示输入域名、QQ 账号、授权码）
.\deploy.ps1

# 非交互
.\deploy.ps1 -Domain "mail.example.com" -QqUser "123456789@qq.com" -QqAuthCode "授权码" -Yes

# 或环境变量
$env:DOMAIN = "mail.example.com"
$env:QQ_MAIL_USER = "123456789@qq.com"
$env:QQ_MAIL_AUTH_CODE = "授权码"
.\deploy.ps1 -Yes
```

若提示无法运行脚本：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy.ps1
```

常用参数：

| 参数 | 说明 |
|------|------|
| `-Domain` | 临时邮箱域名 |
| `-QqUser` / `-QqAuthCode` | QQ 账号与授权码 |
| `-WorkerName` | Worker 名称，默认 `grokreg-mail` |
| `-StrictAlias` | 开启严格别名匹配 |
| `-WithRelay` | 一并部署中继 Worker（relay） |
| `-SkipLogin` | 已登录时跳过 |
| `-SkipSecrets` | 密钥已配置时跳过 |
| `-SkipDeploy` | 只写配置不部署 |
| `-Yes` | 减少确认提问 |
| `-WithRelay` | 一并部署中继 Worker（relay）并写入 `PROXY_POOL` / `RELAY_AUTH` |
| `-RelayAuth` | 中继共享密钥 `RELAY_AUTH`（亦可用环境变量 `RELAY_AUTH`） |

### Linux / macOS / Git Bash / WSL

```bash
chmod +x deploy.sh
./deploy.sh

# 非交互
DOMAIN=mail.example.com \
QQ_MAIL_USER=123456789@qq.com \
QQ_MAIL_AUTH_CODE='授权码' \
./deploy.sh --yes

# 或参数
./deploy.sh --domain mail.example.com --qq-user 123456789@qq.com --qq-auth '授权码' -y
```

脚本会优先使用全局 `wrangler`；若未安装则自动 `npx wrangler@4`。缺少 `wrangler.toml` 时自动从 `wrangler.toml.example` 复制。

---

## 五、方式 D：手动 Wrangler CLI

适合需要逐步控制的场景。生产配置见 [`wrangler.toml`](./wrangler.toml)，模板见 [`wrangler.toml.example`](./wrangler.toml.example)。

### 1. 环境要求

- Node.js 18+（建议 LTS）
- npm / pnpm / yarn 任一

### 2. 安装并登录

```bash
npm install -g wrangler
wrangler login
```

浏览器完成 Cloudflare 授权。

### 3. 修改配置

确认 `wrangler.toml` 中的 `name` 与 `DOMAIN`；若本地没有该文件，从模板复制：

```bash
# Linux / macOS / Git Bash
cp wrangler.toml.example wrangler.toml
```

```powershell
# Windows PowerShell
Copy-Item wrangler.toml.example wrangler.toml
```

编辑 `wrangler.toml`：

```toml
name = "grokreg-mail"
main = "grokreg.worker.js"
compatibility_date = "2024-11-01"

[vars]
DOMAIN = "mail.example.com"   # 改成你的域名
QQ_MAIL_HOST = "pop.qq.com"
QQ_MAIL_PORT = "995"
QQ_IMAP_HOST = "imap.qq.com"
QQ_IMAP_PORT = "993"
# QQ_IMAP_DELETE = "0"        # 关闭 IMAP 删信时取消注释
QQ_FETCH_LIMIT = "20"
# QQ_STRICT_ALIAS_MATCH = "1"
```

**不要**把 QQ 授权码写进 `wrangler.toml` 或提交到 Git。读信用 POP3，删信默认再走 IMAP（需 QQ 开启 IMAP）。

### 4. 注入密钥

```bash
# 在项目根目录执行，按提示输入值
wrangler secret put QQ_MAIL_USER
wrangler secret put QQ_MAIL_AUTH_CODE
```

兼容名称（与代码一致，二选一即可）：

```bash
# wrangler secret put QQ_MAIL_ACCOUNT
# wrangler secret put QQ_MAIL_PASSWORD
```

### 5. 本地调试（可选）

见下文「本地开发与测试」。简要：

```bash
# 复制密钥模板后填写（勿提交 .dev.vars）
cp .dev.vars.example .dev.vars

wrangler dev --port 8787 --ip 127.0.0.1 --local
# 或 Windows：.\scripts\local-dev.ps1
```

```bash
curl http://127.0.0.1:8787/api/domains
curl -X POST http://127.0.0.1:8787/api/new_address
# Windows 冒烟：powershell -File scripts/local-smoke.ps1
```

### 6. 正式部署

```bash
wrangler deploy
```

成功后终端会打印 `*.workers.dev` 地址。

### 7. 更新与回滚

```bash
# 改代码或 vars 后重新部署
wrangler deploy

# 查看最近部署
wrangler deployments list

# 查看实时日志
wrangler tail
```

---

## 五（补充）：中继代理池（relay）部署

当你希望改变收件出口 IP（抗 QQ 封禁/限流）时，可部署一组**中继 Worker**。主 Worker 把收件/删信任务 `fetch` 给中继，中继用自己的出口 IP 完成 IMAP/POP3+TLS。

> 为什么必须走中继而非直连代理：`cloudflare:sockets` 的 `connect()` 无原生 `proxy` 参数，且 `startTls()` 只能对最初连接的目标做 TLS，无法在外部代理隧道上叠加端到端 TLS。故采用中继模型（见 README「域名池与中继代理池」）。

### 1. 部署中继

```bash
# 用独立配置部署 relay.worker.js（独立出口 IP）
npx wrangler deploy -c wrangler.relay.toml

# 为 relay worker 设置共享密钥（须与主 Worker 的 RELAY_AUTH 一致）
wrangler secret put RELAY_AUTH -c wrangler.relay.toml
```

可部署多个 relay worker（不同 Cloudflare 账号/区域）以获得更多出口 IP。

### 2. 配置主 Worker 指向中继

```toml
# wrangler.toml [vars]
PROXY_POOL = """
https://relay1.example.com|secret1
https://relay2.example.com|secret2
"""
PROXY_SELECTION = "round_robin"
PROXY_TIMEOUT_MS = "15000"
PROXY_RETRY = "2"
RELAY_AUTH = "共享密钥"   # 也可每条目用 url|secret
# PROXY_FALLBACK_DIRECT = "1"  # 全部中继失败回退本地直连
```

```bash
wrangler secret put RELAY_AUTH
wrangler deploy
```

### 3. 一键脚本同时部署主 + 中继

```powershell
# Windows
.\deploy.ps1 -WithRelay -Yes
```

```bash
# Linux/macOS
./deploy.sh --with-relay -y
```

脚本会提示输入 `RELAY_AUTH` 与中继 URL，自动写入主 Worker 的 `PROXY_POOL`、为两个 Worker 注入 `RELAY_AUTH`、部署中继并重部署主 Worker。

---

## 六、本地开发与测试

在部署到 Cloudflare 之前，可先在本机用 `wrangler dev` 验证域名池与 API。

### 1. 准备

| 项 | 说明 |
|----|------|
| Node.js 18+ | 用于 `npx wrangler@4` |
| `wrangler.toml` | 已有 `DOMAIN` 等非敏感 `[vars]` |
| `.dev.vars` | 从 `.dev.vars.example` 复制；**勿提交** |

```powershell
cd d:\AILocal\Tools\CloudFlareWorker
Copy-Item .dev.vars.example .dev.vars
# 仅测域名池时 QQ 凭据可留空；测 /api/mails 时填写真实 QQ_MAIL_USER / QQ_MAIL_AUTH_CODE
```

```ini
# .dev.vars 示例
QQ_MAIL_USER=123456789@qq.com
QQ_MAIL_AUTH_CODE=你的授权码
RELAY_AUTH=local-relay-secret
```

### 2. 启动

```powershell
# 前台启动主 Worker（http://127.0.0.1:8787）
npx wrangler@4 dev --port 8787 --ip 127.0.0.1 --local

# 或一键脚本（后台 job + 就绪检测）
.\scripts\local-dev.ps1
.\scripts\local-dev.ps1 -WithRelay              # 主 :8787 + 中继 :8788
.\scripts\local-dev.ps1 -Smoke                  # 启动后自动冒烟
.\scripts\local-dev.ps1 -WithRelay -Smoke -WithMail
```

`-WithRelay` 会生成（已 gitignore）：

- `wrangler.local.toml`：主 Worker，`PROXY_POOL` 指向本机中继
- `wrangler.relay.local.toml`：中继本地配置

### 3. 冒烟测试

**不依赖 QQ 凭据**（域名池 / 生成地址 / token）：

```powershell
# 另开终端，服务已在 8787 监听时
powershell -File scripts/local-smoke.ps1
# 或指定地址
powershell -File scripts/local-smoke.ps1 -BaseUrl http://127.0.0.1:8787
```

覆盖项：

1. `GET /health`
2. `GET /` 服务信息
3. `GET /api/domains` 域名池
4. `POST /api/new_address` ×3（域名在池中、多域名时 token 下标编码）
5. `POST /api/token` 透传

**可选真实收信**（需 `.dev.vars` 中 QQ 凭据，本机可访问 QQ POP3）：

```powershell
powershell -File scripts/local-smoke.ps1 -WithMail
```

手动 curl：

```powershell
curl.exe -sS http://127.0.0.1:8787/api/domains
curl.exe -sS -X POST http://127.0.0.1:8787/api/new_address -H "Content-Type: application/json" -d "{}"
# curl.exe -sS "http://127.0.0.1:8787/api/mails?token=<token>"
```

### 4. 停止

- 前台 `wrangler dev`：`Ctrl+C`
- `local-dev.ps1` 后台 job：`Get-Job | Stop-Job; Get-Job | Remove-Job`
- 或结束占用 8787 的进程后确认端口已释放

### 5. 说明与限制

| 能力 | 本地是否可测 | 备注 |
|------|--------------|------|
| 域名池 / `new_address` / token | 是 | 仅需 `DOMAIN`，已验证通过 |
| `/api/mails` 收信 | 需凭据 | 本机出站 POP3 `pop.qq.com:995` |
| 删信 IMAP | 需凭据 | `imap.qq.com:993` |
| 中继代理池 | 可选 | `local-dev.ps1 -WithRelay` |

---

## 七、部署后冒烟测试

将 `BASE` 换成你的 Worker URL：

```bash
# Windows PowerShell
$BASE = "https://grokreg-mail.<subdomain>.workers.dev"

# 1. 域名
curl "$BASE/api/domains"

# 2. 创建临时邮箱
curl -X POST "$BASE/api/new_address" -H "Content-Type: application/json" -d "{}"

# 3. 用返回的 token 拉信（先向该地址发一封测试邮件）
# curl "$BASE/api/mails?token=<token>"
```

Bash：

```bash
BASE="https://grokreg-mail.<subdomain>.workers.dev"

curl -s "$BASE/api/domains" | jq .
curl -s -X POST "$BASE/api/new_address" | jq .
# curl -s "$BASE/api/mails?token=xxx" | jq .
```

本地也可用同一脚本（改 BaseUrl）：

```powershell
powershell -File scripts/local-smoke.ps1 -BaseUrl $BASE
```

---

## 八、邮件链路配置要点

Worker **不接收 SMTP**。读信走 **POP3**，删信默认 **POP3 + IMAP 双通道**。因此必须保证：

1. 发到 `任意别名@DOMAIN` 的邮件能进入配置的 QQ 邮箱  
2. QQ 邮箱已开启 **POP3**（读）与 **IMAP**（删，网页端同步）  
3. 常见转发方案：
   - Cloudflare Email Routing → 转发到 QQ
   - 域名邮箱 / 企业邮转发
   - QQ「其他邮箱」代收（视 MX 与支持情况）

转发后若收件人字段被改写，可先**不要**设置 `QQ_STRICT_ALIAS_MATCH`，确认能读到信后再按需开启严格模式。

删除行为简述：

- POP3 `DELE` + 强制 `QUIT`：API/POP 视图清理  
- IMAP 按 MIME `Message-ID`（或主题）搜索 → `UID STORE \Deleted` + `EXPUNGE`：服务器与 QQ 网页端真正删除  
- `QQ_IMAP_DELETE=0` 时跳过 IMAP（网页端可能仍可见）

---

## 九、常见部署失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| Git Build 找不到 config | 仓库无 `wrangler.toml` | 提交仓库中的 `wrangler.toml` |
| Git 部署后缺密钥 | 配了 `QqUser`/`QqAuthCode` 等错误名 | 改为 `QQ_MAIL_USER` / `QQ_MAIL_AUTH_CODE`，并写在 **Settings → Variables and Secrets** |
| `缺少 DOMAIN` | 未配环境变量 | 控制台 Variables 或 `wrangler.toml` `[vars]` |
| `缺少 QQ_MAIL_USER` / `AUTH_CODE` | 未配密钥 | `wrangler secret put` 或控制台 Secret |
| POP3 握手 / 登录失败 | 未开 POP3、授权码错误或 **secret 注入脏值** | 见下方「授权码 secret 注入」；重新 `secret put` |
| IMAP 登录 / SEARCH 失败 | 未开 IMAP、网络/授权码 | 开启 IMAP/SMTP；与 POP3 同一授权码 |
| API 已删、QQ 网页仍可见 | 仅 POP3 生效或 IMAP 未匹配 | 查删除响应 `imap.ok`/`imap.error`；确认未设 `QQ_IMAP_DELETE=0` |
| 列表始终为空 | 未转发到该 QQ、别名不匹配 | 检查转发；先用非严格模式 |
| `connect` / sockets 错误 | 账户不支持出站 TCP | 确认 Workers 支持 `cloudflare:sockets`（POP3+IMAP） |
| `/api/mails` HTTP 500 / 错误码 1101 | 运行时异常或邮箱鉴权失败导致未捕获错误 | `wrangler tail` 看日志；优先重注 `QQ_MAIL_AUTH_CODE` |
| 404 Path Not Found | 路径写错 | 见 README API 列表 |

### 授权码 secret 注入（Windows 常见坑）

PowerShell 下 `$auth | wrangler secret put QQ_MAIL_AUTH_CODE` 可能：

1. 管道到 `wrangler.cmd` 时 **stdin 丢失**，secret 变成空/残缺  
2. 自动附带 **`\r\n`**，登录 POP3/IMAP 时鉴权失败  

`deploy.ps1` 已改为经 `cmd.exe` 重定向 stdin，并去掉首尾空白/引号/换行。若仍鉴权失败，请**手动交互**重写 secret（最稳妥）：

```powershell
npx wrangler@4 secret put QQ_MAIL_USER
npx wrangler@4 secret put QQ_MAIL_AUTH_CODE
# 提示 Enter a secret value: 时粘贴纯授权码后回车（勿多空格/换行）
```

注入后：

```powershell
npx wrangler@4 secret list --name grokreg   # 只能看到名称，无法回显值
curl.exe -sS "https://<你的worker>.workers.dev/api/mails?token=test"
# 期望 JSON（可为空列表），而不是 HTTP 500 / 错误码 1101
```

---

## 十、安全与生产建议

1. `QQ_MAIL_AUTH_CODE` 仅用 **Secret**，不要进仓库  
2. 生产建议在 Worker 前加访问控制（自定义 Header / Cloudflare Access / 反代鉴权）；当前 API 默认公开  
3. 多账号并发注册时设置 `QQ_STRICT_ALIAS_MATCH=1`  
4. 定期清理 QQ 邮箱，避免 POP3 列表过大变慢；删信默认走 IMAP 以便网页端同步  
5. `wrangler.toml` 可提交，但只放非敏感 `[vars]`；密钥用 Dashboard / `wrangler secret put`  
6. Cloudflare Git 部署时，运行时变量以 **Settings → Variables and Secrets** 为准  

---

## 十一、文件与命令速查

| 文件 | 用途 |
|------|------|
| `grokreg.worker.js` | 主 Worker 入口：域名池选域 + 代理池调度分发 |
| `mailbox.js` | 共享邮箱模块：IMAP/POP3 与 MIME 解析（主/中继共用） |
| `relay.worker.js` | 中继端点：独立出口 IP，执行收件/删信 |
| `wrangler.toml` | 主 Worker 部署配置（可提交，无密钥） |
| `wrangler.relay.toml` | 中继 Worker 部署配置 |
| `wrangler.toml.example` | 主 Worker 配置模板 |
| `.dev.vars.example` | 本地密钥模板（复制为 `.dev.vars`） |
| `scripts/local-dev.ps1` | 一键启动本地 `wrangler dev` |
| `scripts/local-smoke.ps1` | 本地/远程冒烟（域名池；可选收信） |
| `deploy.ps1` | Windows 一键部署（支持 -WithRelay） |
| `deploy.sh` | Linux/macOS/Git Bash 一键部署（支持 --with-relay） |
| `.dev.vars` | 本地密钥（可选，勿提交） |
| `README.md` | 功能与 API 文档 |
| `Deploy.md` | 本文：部署步骤 |

| 命令 | 说明 |
|------|------|
| `npx wrangler deploy` | Cloudflare Git / 本地部署 |
| `cp wrangler.toml.example wrangler.toml` | 从模板生成本地配置（Bash） |
| `Copy-Item wrangler.toml.example wrangler.toml` | 从模板生成本地配置（PowerShell） |
| `.\deploy.ps1` / `./deploy.sh` | 一键部署 |
| `.\scripts\local-dev.ps1` | 本地开发服务 |
| `powershell -File scripts/local-smoke.ps1` | 本地冒烟测试 |
| `wrangler login` | 登录 Cloudflare |
| `wrangler secret put <NAME>` | 设置密钥 |
| `wrangler dev` | 本地开发 |
| `wrangler deploy` | 部署到线上 |
| `wrangler tail` | 实时日志 |

---

部署完成后，API 用法与注册机对接示例请参阅 [README.md](./README.md)。
