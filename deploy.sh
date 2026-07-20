#!/usr/bin/env bash
# GrokReg Cloudflare Worker 一键部署脚本 (Linux / macOS / Git Bash / WSL)
# 通过 QQ 邮箱 POP3 读信、IMAP 真正删信（默认双通道）
# 若缺少 wrangler.toml，会自动从 wrangler.toml.example 复制
#
# 交互:
#   chmod +x deploy.sh && ./deploy.sh
#
# 非交互:
#   DOMAIN=mail.example.com \
#   QQ_MAIL_USER=123456789@qq.com \
#   QQ_MAIL_AUTH_CODE=授权码 \
#   ./deploy.sh
#
# 参数:
#   --domain DOMAIN
#   --qq-user USER
#   --qq-auth CODE   # POP3/IMAP 共用授权码
#   --name WORKER_NAME
#   --strict
#   --skip-login
#   --skip-secrets
#   --skip-deploy
#   -y / --yes

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DOMAIN="${DOMAIN:-}"
QQ_MAIL_USER="${QQ_MAIL_USER:-${QQ_MAIL_ACCOUNT:-}}"
QQ_MAIL_AUTH_CODE="${QQ_MAIL_AUTH_CODE:-${QQ_MAIL_PASSWORD:-}}"
WORKER_NAME="${WORKER_NAME:-grokreg-mail}"
STRICT_ALIAS=0
SKIP_LOGIN=0
SKIP_SECRETS=0
SKIP_DEPLOY=0
YES=0

if [[ "${QQ_STRICT_ALIAS_MATCH:-}" == "1" ]]; then
  STRICT_ALIAS=1
fi

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK:\033[0m %s\n' "$*"; }
warn() { printf '    \033[33mWARN:\033[0m %s\n' "$*"; }
fail() { printf '    \033[31mFAIL:\033[0m %s\n' "$*"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --qq-user) QQ_MAIL_USER="$2"; shift 2 ;;
    --qq-auth) QQ_MAIL_AUTH_CODE="$2"; shift 2 ;;
    --name) WORKER_NAME="$2"; shift 2 ;;
    --strict) STRICT_ALIAS=1; shift ;;
    --skip-login) SKIP_LOGIN=1; shift ;;
    --skip-secrets) SKIP_SECRETS=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage ;;
    *) fail "未知参数: $1"; usage ;;
  esac
done

prompt() {
  local label="$1"
  local default="${2:-}"
  local secret="${3:-0}"
  local value=""
  if [[ -n "$default" ]]; then
    label="$label [$default]"
  fi
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$label: " value
    echo ""
  else
    read -r -p "$label: " value
  fi
  if [[ -z "${value// }" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
}

run_wrangler() {
  if command -v wrangler >/dev/null 2>&1; then
    wrangler "$@"
  else
    npx --yes wrangler@4 "$@"
  fi
}

# 去掉首尾空白、误加引号、内部换行（避免 secret put 写入脏授权码）
normalize_secret() {
  local v="${1-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ ${#v} -ge 2 ]]; then
    if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then
      v="${v:1:${#v}-2}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
    fi
  fi
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  printf '%s' "$v"
}

update_wrangler_toml() {
  local path="$1"
  local name="$2"
  local domain="$3"
  local strict="$4"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "$path" ]]; then
    fail "未找到 wrangler.toml"
    exit 1
  fi

  # 跨平台 sed 备份后缀处理
  if sed --version >/dev/null 2>&1; then
    SED_INPLACE=(sed -i)
  else
    SED_INPLACE=(sed -i '')
  fi

  cp "$path" "$tmp"

  if grep -qE '^name\s*=' "$tmp"; then
    "${SED_INPLACE[@]}" -E "s|^name[[:space:]]*=[[:space:]]*\".*\"|name = \"${name}\"|" "$tmp"
  else
    printf 'name = "%s"\n%s\n' "$name" "$(cat "$tmp")" >"$tmp.next"
    mv "$tmp.next" "$tmp"
  fi

  if grep -qE '^DOMAIN\s*=' "$tmp"; then
    "${SED_INPLACE[@]}" -E "s|^DOMAIN[[:space:]]*=[[:space:]]*\".*\"|DOMAIN = \"${domain}\"|" "$tmp"
  else
    fail "wrangler.toml 中未找到 DOMAIN"
    exit 1
  fi

  if [[ "$strict" == "1" ]]; then
    if grep -qE '^#[[:space:]]*QQ_STRICT_ALIAS_MATCH[[:space:]]*=' "$tmp"; then
      "${SED_INPLACE[@]}" -E 's|^#[[:space:]]*QQ_STRICT_ALIAS_MATCH[[:space:]]*=[[:space:]]*"1"|QQ_STRICT_ALIAS_MATCH = "1"|' "$tmp"
    elif ! grep -qE '^QQ_STRICT_ALIAS_MATCH[[:space:]]*=' "$tmp"; then
      printf '\nQQ_STRICT_ALIAS_MATCH = "1"\n' >>"$tmp"
    fi
  fi

  mv "$tmp" "$path"
}

printf '\n\033[35m========================================\033[0m\n'
printf '\033[35m  GrokReg Worker 一键部署 (Bash)\033[0m\n'
printf '\033[35m========================================\033[0m\n'
printf '工作目录: %s\n' "$ROOT"

step "检查项目文件"
[[ -f "grokreg.worker.js" ]] || { fail "缺少 grokreg.worker.js"; exit 1; }
if [[ ! -f "wrangler.toml" ]]; then
  if [[ -f "wrangler.toml.example" ]]; then
    cp "wrangler.toml.example" "wrangler.toml"
    warn "未找到 wrangler.toml，已从 wrangler.toml.example 复制"
  else
    fail "缺少 wrangler.toml 与 wrangler.toml.example"
    exit 1
  fi
fi
ok "grokreg.worker.js / wrangler.toml"

step "检查 Node.js"
if ! command -v node >/dev/null 2>&1; then
  fail "未检测到 Node.js，请安装 18+: https://nodejs.org/"
  exit 1
fi
NODE_VER="$(node -v)"
ok "Node.js $NODE_VER"
MAJOR="${NODE_VER#v}"
MAJOR="${MAJOR%%.*}"
if [[ "$MAJOR" -lt 18 ]]; then
  warn "建议使用 Node.js 18 及以上"
fi

step "检查 Wrangler"
if command -v wrangler >/dev/null 2>&1; then
  ok "已安装 wrangler: $(wrangler --version 2>/dev/null || true)"
else
  warn "未找到全局 wrangler，将使用 npx wrangler@4"
  command -v npx >/dev/null 2>&1 || { fail "未找到 npx"; exit 1; }
  ok "npx 可用"
fi

if [[ "$SKIP_LOGIN" -eq 0 ]]; then
  step "Cloudflare 登录状态"
  set +e
  WHOAMI_OUT="$(run_wrangler whoami 2>&1)"
  WHOAMI_RC=$?
  set -e
  if [[ $WHOAMI_RC -ne 0 ]] || echo "$WHOAMI_OUT" | grep -qiE 'not authenticated|not logged in|error'; then
    warn "未登录或无法确认，即将打开浏览器登录..."
    run_wrangler login
  else
    ok "已登录 Cloudflare"
    if [[ "$YES" -eq 0 ]]; then
      printf '%s\n' "$WHOAMI_OUT"
    fi
  fi
else
  step "跳过登录检查 (--skip-login)"
fi

step "收集部署配置"
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(prompt "临时邮箱域名 DOMAIN (如 mail.example.com)")"
fi
[[ -n "$DOMAIN" ]] || { fail "DOMAIN 不能为空"; exit 1; }

if [[ "$SKIP_SECRETS" -eq 0 ]]; then
  if [[ -z "$QQ_MAIL_USER" ]]; then
    QQ_MAIL_USER="$(prompt "QQ 邮箱账号 QQ_MAIL_USER")"
  fi
  if [[ -z "$QQ_MAIL_AUTH_CODE" ]]; then
    QQ_MAIL_AUTH_CODE="$(prompt "QQ 邮箱授权码 QQ_MAIL_AUTH_CODE" "" 1)"
  fi
  QQ_MAIL_USER="$(normalize_secret "$QQ_MAIL_USER")"
  QQ_MAIL_AUTH_CODE="$(normalize_secret "$QQ_MAIL_AUTH_CODE")"
  [[ -n "$QQ_MAIL_USER" ]] || { fail "QQ_MAIL_USER 不能为空"; exit 1; }
  [[ -n "$QQ_MAIL_AUTH_CODE" ]] || { fail "QQ_MAIL_AUTH_CODE 不能为空"; exit 1; }
  if [[ ${#QQ_MAIL_AUTH_CODE} -lt 6 ]]; then
    fail "QQ_MAIL_AUTH_CODE 长度过短（${#QQ_MAIL_AUTH_CODE}），请确认是授权码而非登录密码"
    exit 1
  fi
fi

if [[ "$STRICT_ALIAS" -eq 0 && "$YES" -eq 0 ]]; then
  ans="$(prompt "是否开启严格别名匹配 QQ_STRICT_ALIAS_MATCH=1? (y/N)" "N")"
  if [[ "$ans" =~ ^[yY] ]]; then
    STRICT_ALIAS=1
  fi
fi

echo ""
echo "    Worker 名称 : $WORKER_NAME"
echo "    DOMAIN      : $DOMAIN"
echo "    严格别名    : $STRICT_ALIAS"
if [[ "$SKIP_SECRETS" -eq 0 ]]; then
  echo "    QQ 账号     : $QQ_MAIL_USER"
  echo "    授权码      : ********"
fi

if [[ "$YES" -eq 0 ]]; then
  confirm="$(prompt "确认以上配置并继续? (Y/n)" "Y")"
  if [[ "$confirm" =~ ^[nN] ]]; then
    warn "已取消"
    exit 0
  fi
fi

step "更新 wrangler.toml"
update_wrangler_toml "wrangler.toml" "$WORKER_NAME" "$DOMAIN" "$STRICT_ALIAS"
ok "已写入 name / DOMAIN$([ "$STRICT_ALIAS" -eq 1 ] && echo ' / QQ_STRICT_ALIAS_MATCH')"

if [[ "$SKIP_SECRETS" -eq 0 ]]; then
  step "注入 Secrets"
  # printf '%s' 不写尾部换行，避免授权码变成 "xxxx\n"
  echo "    写入 QQ_MAIL_USER"
  printf '%s' "$QQ_MAIL_USER" | run_wrangler secret put QQ_MAIL_USER
  ok "QQ_MAIL_USER"
  echo "    写入 QQ_MAIL_AUTH_CODE（长度 ${#QQ_MAIL_AUTH_CODE}，不回显）"
  printf '%s' "$QQ_MAIL_AUTH_CODE" | run_wrangler secret put QQ_MAIL_AUTH_CODE
  ok "QQ_MAIL_AUTH_CODE"
else
  step "跳过密钥注入 (--skip-secrets)"
fi

if [[ "$SKIP_DEPLOY" -eq 1 ]]; then
  step "跳过部署 (--skip-deploy)"
  ok "配置已完成"
  exit 0
fi

step "执行 wrangler deploy"
echo "    若线上 Worker 曾在控制台编辑，将自动确认覆盖"
DEPLOY_LOG="$(mktemp)"
set +e
# 自动回答 y：覆盖此前通过 Dashboard/script API 上传的 Worker
printf 'y\n' | run_wrangler deploy 2>&1 | tee "$DEPLOY_LOG"
DEPLOY_RC=${PIPESTATUS[1]:-${PIPESTATUS[0]}}
set -e
if [[ $DEPLOY_RC -ne 0 ]]; then
  fail "deploy 失败 (exit $DEPLOY_RC)"
  echo "    日志: $DEPLOY_LOG"
  echo "    也可手动执行: npx wrangler@4 deploy  （提示时输入 y）"
  exit 1
fi
ok "部署命令已执行"

step "冒烟测试 /api/domains"
BASE_URL="$(grep -Eo 'https://[a-zA-Z0-9._-]+\.workers\.dev' "$DEPLOY_LOG" | head -n1 || true)"
if [[ -z "$BASE_URL" ]]; then
  warn "未能从输出解析 workers.dev URL，请手动访问 /api/domains 验证"
else
  ok "Worker URL: $BASE_URL"
  if command -v curl >/dev/null 2>&1; then
    if RESP="$(curl -fsS --max-time 30 "$BASE_URL/api/domains" 2>/dev/null)"; then
      ok "GET /api/domains => $RESP"
    else
      warn "冒烟测试失败，可稍后重试: $BASE_URL/api/domains"
    fi
  else
    warn "未安装 curl，跳过 HTTP 测试"
  fi
fi

printf '\n\033[32m========================================\033[0m\n'
printf '\033[32m  部署完成\033[0m\n'
printf '\033[32m========================================\033[0m\n'
if [[ -n "${BASE_URL:-}" ]]; then
  echo "API 示例:"
  echo "  $BASE_URL/api/domains"
  echo "  $BASE_URL/api/new_address"
fi
echo "更多说明: README.md / Deploy.md"
echo ""
