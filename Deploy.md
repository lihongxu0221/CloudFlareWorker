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
| 5 | 本地 CLI/脚本部署前已从 `wrangler.toml.example` 生成 `wrangler.toml` | ☐ |

### 本地配置文件（CLI / 一键脚本必做）

仓库只提交模板 `wrangler.toml.example`；真实配置 `wrangler.toml` 已加入 `.gitignore`，**勿提交**。

```bash
# Linux / macOS / Git Bash
cp wrangler.toml.example wrangler.toml
```

```powershell
# Windows PowerShell
Copy-Item wrangler.toml.example wrangler.toml
```

然后编辑 `wrangler.toml` 中的 `DOMAIN`。一键脚本若发现本地没有 `wrangler.toml`，会自动从 `wrangler.toml.example` 复制。

---

## 二、方式 A：控制台部署（无需本地工具）

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
| `QQ_MAIL_HOST` | `pop.qq.com` | POP3 主机 |
| `QQ_MAIL_PORT` | `995` | POP3 SSL 端口 |
| `QQ_IMAP_HOST` | `imap.qq.com` | IMAP 主机（删信用） |
| `QQ_IMAP_PORT` | `993` | IMAP SSL 端口 |
| `QQ_IMAP_DELETE` | `1` | 设为 `0` 仅 POP3 删除，不走 IMAP |
| `QQ_FETCH_LIMIT` | `20` | 默认拉信条数（最大 50） |
| `QQ_STRICT_ALIAS_MATCH` | 空 | 设为 `1` 开启严格别名匹配 |

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

## 三、方式 B：一键部署脚本（推荐）

项目根目录提供脚本，自动完成：检查 Node → 登录 Cloudflare → 写入 `DOMAIN` → 注入密钥 → `wrangler deploy` → 冒烟测试。

若本地没有 `wrangler.toml`，脚本会先从 `wrangler.toml.example` 复制再继续；也可提前手动生成：

```powershell
# Windows
Copy-Item wrangler.toml.example wrangler.toml
```

```bash
# Linux / macOS / Git Bash
cp wrangler.toml.example wrangler.toml
```

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
| `-SkipLogin` | 已登录时跳过 |
| `-SkipSecrets` | 密钥已配置时跳过 |
| `-SkipDeploy` | 只写配置不部署 |
| `-Yes` | 减少确认提问 |

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

## 四、方式 C：手动 Wrangler CLI

适合需要逐步控制的场景。配置模板见 [`wrangler.toml.example`](./wrangler.toml.example)。

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

从模板生成本地配置（`wrangler.toml` 已加入 `.gitignore`，勿提交）：

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

```bash
wrangler dev
```

本地默认 `http://127.0.0.1:8787`。Secrets 在本地可用 `.dev.vars`（**勿提交**）：

```ini
# .dev.vars 示例（仅本地）
QQ_MAIL_USER=123456789@qq.com
QQ_MAIL_AUTH_CODE=你的授权码
```

测试：

```bash
curl http://127.0.0.1:8787/api/domains
curl -X POST http://127.0.0.1:8787/api/new_address
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

## 五、部署后冒烟测试

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

---

## 六、邮件链路配置要点

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

## 七、常见部署失败

| 现象 | 可能原因 | 处理 |
|------|----------|------|
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

## 八、安全与生产建议

1. `QQ_MAIL_AUTH_CODE` 仅用 **Secret**，不要进仓库  
2. 生产建议在 Worker 前加访问控制（自定义 Header / Cloudflare Access / 反代鉴权）；当前 API 默认公开  
3. 多账号并发注册时设置 `QQ_STRICT_ALIAS_MATCH=1`  
4. 定期清理 QQ 邮箱，避免 POP3 列表过大变慢；删信默认走 IMAP 以便网页端同步  
5. 从 `wrangler.toml.example` 复制出 `wrangler.toml`，将示例域名改成真实值后再部署（见第一节拷贝命令）  


---

## 九、文件与命令速查

| 文件 | 用途 |
|------|------|
| `grokreg.worker.js` | Worker 入口代码 |
| `wrangler.toml.example` | Wrangler 配置模板（提交到仓库） |
| `wrangler.toml` | 本地部署配置（gitignore，由 example 复制） |
| `deploy.ps1` | Windows 一键部署 |
| `deploy.sh` | Linux/macOS/Git Bash 一键部署 |
| `.dev.vars` | 本地密钥（可选，勿提交） |
| `README.md` | 功能与 API 文档 |
| `Deploy.md` | 本文：部署步骤 |

| 命令 | 说明 |
|------|------|
| `cp wrangler.toml.example wrangler.toml` | 从模板生成本地配置（Bash） |
| `Copy-Item wrangler.toml.example wrangler.toml` | 从模板生成本地配置（PowerShell） |
| `.\deploy.ps1` / `./deploy.sh` | 一键部署 |
| `wrangler login` | 登录 Cloudflare |
| `wrangler secret put <NAME>` | 设置密钥 |
| `wrangler dev` | 本地开发 |
| `wrangler deploy` | 部署到线上 |
| `wrangler tail` | 实时日志 |

---

部署完成后，API 用法与注册机对接示例请参阅 [README.md](./README.md)。
