# CloudFlareWorker · GrokReg 临时邮箱

基于 **Cloudflare Workers** 的临时邮箱 API 服务。通过 QQ 邮箱 **POP3 读信**、**IMAP 真正删信**，对外提供兼容常见注册机的邮箱接口（生成地址、拉取邮件、删除邮件）。

适用场景：自动化注册、验证码收取、临时邮箱对接等。

---

## 功能特性

- 随机或指定本地部分生成临时邮箱地址（`xxx@你的域名`）
- 通过 POP3 SSL（`pop.qq.com:995`）读取 QQ 邮箱邮件
- 删除时 **POP3 + IMAP 双通道**（`imap.qq.com:993`），QQ 网页端可同步消失
- 按别名地址过滤邮件（支持严格/非严格匹配）
- 解析 MIME：Base64、Quoted-Printable、multipart、HTML 转纯文本
- CORS 已开启，可直接被前端或脚本调用
- 兼容多组路径别名，便于对接不同注册机

---

## 工作原理

1. 你的域名（或子域名）邮件 **转发 / 代收到一个 QQ 邮箱**
2. Worker 使用 QQ 邮箱 **授权码** 登录 POP3（`pop.qq.com:995`）读信
3. 客户端调用 API 生成临时地址、按 token 拉取该别名相关邮件
4. 注册机从邮件正文中提取验证码
5. 删除时：POP3 `DELE` 清理 POP 视图，再 IMAP `STORE+EXPUNGE` 从服务器真正删除（网页端同步）

> 注意：本 Worker **不接收 SMTP**，只通过 POP3/IMAP 访问已进入 QQ 邮箱的邮件。仅 POP3 删除时 QQ 网页端常仍可见，故默认开启 IMAP 删信。

---

## 前置准备

### 1. QQ 邮箱开启 POP3 与 IMAP

1. 登录 [QQ 邮箱](https://mail.qq.com) → **设置** → **账户**
2. 开启 **POP3/SMTP 服务** 与 **IMAP/SMTP 服务**
3. 生成 **授权码**（不是 QQ 登录密码；POP3 与 IMAP 共用）
4. 记下邮箱账号（如 `123456789@qq.com`）和授权码

### 2. 域名邮件转发到 QQ 邮箱

任选一种方式，确保发到 `任意别名@你的域名` 的邮件能进入上述 QQ 邮箱，例如：

- 域名邮箱转发（Cloudflare Email Routing、企业邮、阿里云邮等）
- QQ 邮箱「其他邮箱」代收（若支持你的域名 MX）
- 第三方转发服务

### 3. Cloudflare 账号

- 已有 Cloudflare 账号
- 建议域名也托管在 Cloudflare（非必须，Worker 可单独部署）

---

## 环境变量

在 Worker 的 **Settings → Variables and Secrets** 中配置：

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `DOMAIN` | **是** | — | 临时邮箱域名，如 `mail.example.com` |
| `QQ_MAIL_USER` | **是** | — | QQ 邮箱账号，如 `123456789@qq.com` |
| `QQ_MAIL_AUTH_CODE` | **是** | — | QQ 邮箱授权码（POP3/IMAP 共用，非登录密码） |
| `QQ_MAIL_HOST` | 否 | `pop.qq.com` | POP3 服务器 |
| `QQ_MAIL_PORT` | 否 | `995` | POP3 SSL 端口 |
| `QQ_IMAP_HOST` | 否 | `imap.qq.com` | IMAP 服务器（删信用） |
| `QQ_IMAP_PORT` | 否 | `993` | IMAP SSL 端口 |
| `QQ_IMAP_DELETE` | 否 | `1` | 设为 `0` 关闭 IMAP 删信，仅走 POP3 DELE |
| `QQ_FETCH_LIMIT` | 否 | `20` | 默认拉取邮件条数（最大 50） |
| `QQ_STRICT_ALIAS_MATCH` | 否 | 空 | 设为 `1` 时严格按收件人别名过滤；并发注册建议开启 |

兼容别名（任选其一即可）：

- `QQ_MAIL_USER` ≡ `QQ_MAIL_ACCOUNT`
- `QQ_MAIL_AUTH_CODE` ≡ `QQ_MAIL_PASSWORD`
- `QQ_IMAP_HOST` ≡ `IMAP_HOST`，`QQ_IMAP_PORT` ≡ `IMAP_PORT`

---

## 部署方式

仓库已包含可提交的 `wrangler.toml`（仅非敏感 `[vars]`）。密钥用 Dashboard Secrets 或 `wrangler secret put`，**不要**写进配置文件。

若本地没有 `wrangler.toml`，可从模板复制：

```bash
cp wrangler.toml.example wrangler.toml
# Windows: Copy-Item wrangler.toml.example wrangler.toml
```

### 方式一：Cloudflare Git 自动部署（推荐）

1. Workers → 你的 Worker → **Settings → Build**，连接本 Git 仓库
2. Build 配置建议：
   - Build command: 空 / None
   - Deploy command: `npx wrangler deploy`
   - Root directory: `/`
   - Production branch: `main`
3. **Settings → Variables and Secrets**（运行时，必做）添加：
   - Variable: `DOMAIN` = 你的域名
   - Secret: `QQ_MAIL_USER` = QQ 邮箱
   - Secret: `QQ_MAIL_AUTH_CODE` = 授权码
4. **不要**使用 `QqUser` / `QqAuthCode` / `WorkerName` 这类脚本参数名
5. 推送 `main` 或点 Retry deployment，构建成功后访问 `/api/domains` 验证

完整说明见 [Deploy.md](./Deploy.md)「方式 A：Cloudflare Git」。

### 方式二：Cloudflare 控制台粘贴代码

1. 打开 [Cloudflare Dashboard](https://dash.cloudflare.com) → **Workers & Pages** → **Create** → **Create Worker**
2. 给 Worker 起名（如 `grokreg`），点击 **Deploy**
3. 进入 Worker → **Edit code**，删除默认代码，将本仓库 [`grokreg.worker.js`](./grokreg.worker.js) 全部内容粘贴进去
4. 点击 **Deploy** 保存
5. 进入 **Settings → Variables and Secrets**，添加上述环境变量（`DOMAIN`、`QQ_MAIL_USER`、`QQ_MAIL_AUTH_CODE` 等）
6. （可选）**Settings → Domains & Routes** 绑定自定义域名
7. 访问 `https://你的worker.subdomain.workers.dev/api/domains` 验证是否正常

### 方式三：一键部署脚本

**Windows PowerShell：**

```powershell
.\deploy.ps1
# 或非交互
.\deploy.ps1 -Domain "mail.example.com" -QqUser "123456789@qq.com" -QqAuthCode "授权码" -Yes
```

**Linux / macOS / Git Bash：**

```bash
chmod +x deploy.sh && ./deploy.sh
# 或非交互
DOMAIN=mail.example.com QQ_MAIL_USER=123456789@qq.com QQ_MAIL_AUTH_CODE='授权码' ./deploy.sh -y
```

脚本会自动检查 Node、登录 Cloudflare；若缺少 `wrangler.toml` 则从 `wrangler.toml.example` 复制并更新 `DOMAIN`、注入 Secrets、执行 `wrangler deploy` 并做冒烟测试。详见 [Deploy.md](./Deploy.md)。

### 方式四：手动 Wrangler CLI

```bash
# 1. 安装 Wrangler 并登录
npm install -g wrangler
wrangler login

# 2. 确认 wrangler.toml 中 DOMAIN（缺失时从 example 复制）
# cp wrangler.toml.example wrangler.toml

# 3. 注入密钥并部署
wrangler secret put QQ_MAIL_USER
wrangler secret put QQ_MAIL_AUTH_CODE
wrangler deploy
```

本地调试：

```bash
wrangler dev
```

---

## API 说明

Base URL 示例：`https://grokreg-mail.xxx.workers.dev`

所有 JSON 接口均带 CORS 头，支持 `GET` / `POST` / `DELETE` / `OPTIONS`。

### 1. 获取域名列表

```http
GET /api/domains
```

**响应示例：**

```json
{
  "results": [
    { "domain": "mail.example.com", "isVerified": true }
  ]
}
```

### 2. 创建临时邮箱

以下路径等价：

- `POST|GET /api/new_address`
- `POST|GET /admin/new_address`
- `POST|GET /accounts`

**Query / Body 参数（可选）：**

| 参数 | 说明 |
|------|------|
| `name` / `localPart` | 指定本地部分；不传则随机 10 位 |
| `domain` | 覆盖环境变量中的域名 |

**请求示例：**

```bash
curl -X POST "https://你的worker.workers.dev/api/new_address" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"testuser\"}"
```

**响应示例：**

```json
{
  "address": "testuser@mail.example.com",
  "token": "testuser",
  "jwt": "testuser"
}
```

> `token` / `jwt` 实际为邮箱本地部分，后续读信时作为身份标识使用。

### 3. 获取 Token

```http
GET|POST /api/token
GET|POST /token
```

可从 `Authorization: Bearer <token>`、Body 的 `token`/`jwt`/`address`，或自动生成。

**响应示例：**

```json
{
  "token": "testuser",
  "jwt": "testuser"
}
```

### 4. 拉取邮件列表

```http
GET /api/mails
GET /api/mail
```

**鉴权（任选其一）：**

- Header：`Authorization: Bearer <token>`
- Query：`?token=<token>`
- Body：`{ "token": "..." }` 或 `{ "address": "xxx@domain" }`

**Query 参数：**

| 参数 | 说明 |
|------|------|
| `limit` | 条数，默认 `QQ_FETCH_LIMIT` 或 20，最大 50 |
| `offset` | 偏移，默认 0 |

**请求示例：**

```bash
curl "https://你的worker.workers.dev/api/mails?token=testuser&limit=10"
```

**响应示例：**

```json
{
  "messages": [
    {
      "id": "UID...",
      "msgid": "UID...",
      "address": "testuser@mail.example.com",
      "from": "noreply@example.com",
      "to": [{ "address": "testuser@mail.example.com" }],
      "subject": "Your verification code",
      "date": "Mon, 20 Jul 2026 12:00:00 +0000",
      "text": "Your code is 123456",
      "content": "Your code is 123456",
      "body": "Your code is 123456",
      "intro": "Your code is 123456",
      "snippet": "Your code is 123456",
      "html": [],
      "raw": "..."
    }
  ]
}
```

### 5. 获取单封邮件

```http
GET /api/mails/{id}
GET /api/mail/{id}
```

`id` 为 POP3 UID 或序号。鉴权方式同列表接口。

### 6. 删除邮件

```http
DELETE /api/mails/{id}
DELETE /api/mail/{id}
```

删除为 **双通道**（默认）：

1. **POP3** `DELE` + 强制 `QUIT`：清理 POP 视图 / API 复查  
2. **IMAP** `UID STORE +FLAGS (\Deleted)` + `EXPUNGE`：从 QQ 服务器真正删除，网页端同步消失  

匹配顺序：优先用 MIME `Message-ID` 在 IMAP 搜索；若无则用主题精确匹配。`QQ_IMAP_DELETE=0` 时跳过 IMAP。

**请求示例：**

```bash
curl -X DELETE "https://你的worker.workers.dev/api/mails/1" \
  -H "Authorization: Bearer testuser"
```

**响应示例：**

```json
{
  "ok": true,
  "deleted": 1,
  "requestedId": "1",
  "messages": [
    {
      "id": "1",
      "number": 1,
      "subject": "Your verification code",
      "messageId": "<xxx@example.com>",
      "protocol": "pop3"
    }
  ],
  "pop3": { "ok": true, "deleted": 1 },
  "imap": {
    "ok": true,
    "deleted": 1,
    "error": "",
    "messages": [{ "uid": "12345", "protocol": "imap" }]
  }
}
```

说明：

- `ok` / HTTP 200 以 **POP3 是否命中**为准；IMAP 失败时仍返回 200 并在 `imap.error` 中给出原因，便于排查网页端残留。
- 需在 QQ 邮箱设置中开启 **IMAP/SMTP**（与 POP3 同一授权码）。

---

## 注册机对接示例

```bash
# 1. 申请临时邮箱
ADDR=$(curl -s -X POST "https://你的worker.workers.dev/api/new_address")
TOKEN=$(echo "$ADDR" | jq -r .token)
EMAIL=$(echo "$ADDR" | jq -r .address)
echo "使用邮箱: $EMAIL"

# 2. 在目标网站用 $EMAIL 发起注册（需你自己完成）

# 3. 轮询收信
curl -s "https://你的worker.workers.dev/api/mails?token=$TOKEN" | jq .
```

JavaScript 示例：

```js
const base = "https://你的worker.workers.dev";

// 创建地址
const created = await fetch(`${base}/api/new_address`, { method: "POST" })
  .then((r) => r.json());

// 拉取邮件
const mails = await fetch(`${base}/api/mails?token=${created.token}`)
  .then((r) => r.json());

console.log(created.address, mails.messages);
```

---

## 别名匹配说明

| 模式 | 条件 | 行为 |
|------|------|------|
| **非严格（默认）** | `QQ_STRICT_ALIAS_MATCH` 未设为 `1` | 优先按收件人/正文匹配别名；若无匹配，退回最近最多 5 封邮件，便于转发链路剥掉头字段时仍能取验证码 |
| **严格** | `QQ_STRICT_ALIAS_MATCH=1` | 仅返回/删除明确匹配别名的邮件；**并发多账号注册时建议开启** |

删除逻辑：

- 指定了邮件 `id`：非严格模式下直接按 id 删除；严格模式仍要求别名匹配
- 未指定 `id`：始终要求别名匹配，避免误删
- 默认再走 IMAP，使 QQ 网页端与服务器侧同步删除；可用 `QQ_IMAP_DELETE=0` 关闭

---

## 常见问题

### 1. 返回 `缺少 DOMAIN 环境变量`

未配置 `DOMAIN`，请在 Worker 变量中添加。

### 2. 返回 `缺少 QQ_MAIL_USER` / `缺少 QQ_MAIL_AUTH_CODE`

未配置 QQ 邮箱账号或授权码。授权码在 QQ 邮箱设置中生成，不是登录密码。

### 3. POP3 握手失败 / USER/PASS 失败

- 确认已开启 POP3 服务
- 确认使用的是授权码（非登录密码）
- 检查 `QQ_MAIL_HOST` / `QQ_MAIL_PORT` 是否为 `pop.qq.com` / `995`
- **Windows**：PowerShell 管道 `$code | wrangler secret put` 可能把授权码写坏（丢 stdin / 多 `\r\n`）。请用 `.\deploy.ps1`（已修复）或交互式：
  ```powershell
  npx wrangler@4 secret put QQ_MAIL_AUTH_CODE
  ```

### 4. 有邮件但列表为空

- 确认域名转发/代收到的是配置的同一个 QQ 邮箱
- 转发后收件人字段可能被改写，可先保持非严格模式测试
- 并发场景再开启 `QQ_STRICT_ALIAS_MATCH=1`

### 5. API 已删信，但 QQ 网页端仍能看到

- 确认 QQ 邮箱已开启 **IMAP/SMTP**（设置 → 账户 → 开启服务）
- 确认未设置 `QQ_IMAP_DELETE=0`
- 查看删除接口返回的 `imap.ok` / `imap.error`：IMAP 未找到匹配时可能因无 MIME `Message-ID` 或主题不一致
- 仅 POP3 删除往往只影响 POP 视图，网页端仍可能保留副本

### 6. IMAP 登录 / SEARCH 失败

- 与 POP3 使用同一授权码
- 主机/端口默认为 `imap.qq.com:993`，可用 `QQ_IMAP_HOST` / `QQ_IMAP_PORT` 覆盖
- 若暂时不需要网页端同步删除，可设 `QQ_IMAP_DELETE=0`

### 7. Worker 报 TCP / connect 相关错误

本项目使用 `cloudflare:sockets` 出站连接 POP3/IMAP。请确认当前 Cloudflare 套餐与账户支持 Workers 出站 TCP（Sockets API）。

---

## 项目结构

```
CloudFlareWorker/
├── grokreg.worker.js         # Worker 主代码
├── wrangler.toml             # 生产/Git 部署配置（可提交，无密钥）
├── wrangler.toml.example     # Wrangler 配置模板
├── deploy.ps1                # Windows 一键部署
├── deploy.sh                 # Linux/macOS 一键部署
├── Deploy.md                 # 详细部署说明
├── README.md                 # 说明文档
└── LICENSE                   # MIT
```

详细部署步骤见 [Deploy.md](./Deploy.md)。

---

## 安全建议

- 将 `QQ_MAIL_AUTH_CODE` 配置为 **Secret**，不要提交到 Git
- 生产环境建议为 Worker 增加访问鉴权（如自定义 Header 校验），当前接口默认公开可调用
- 开启 `QQ_STRICT_ALIAS_MATCH=1` 降低误读/误删风险
- 定期清理 QQ 邮箱中的已读/无用邮件

---

## License

[MIT](./LICENSE) © 2026 lihongxu0221
