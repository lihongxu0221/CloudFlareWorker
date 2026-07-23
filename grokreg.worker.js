import { fetchMessages, deleteMessages } from "./mailbox.js";

/**
 * @typedef {Object} Env
 * @property {string} [DOMAIN] 收件域名池，支持换行/逗号/分号分隔多个域名；单域名向后兼容。
 * @property {string} [DOMAIN_SELECTION] 选域策略：round_robin(默认) | random | hash。
 * @property {string} [QQ_MAIL_USER] QQ 邮箱地址。
 * @property {string} [QQ_MAIL_AUTH_CODE] QQ 邮箱授权码。
 * @property {string} [QQ_MAIL_HOST] POP3 主机。
 * @property {string} [QQ_MAIL_PORT] POP3 端口。
 * @property {string} [QQ_IMAP_HOST] IMAP 主机。
 * @property {string} [QQ_IMAP_PORT] IMAP 端口。
 * @property {string} [QQ_IMAP_DELETE] 是否启用 IMAP 真删，默认 "1"。
 * @property {string} [QQ_FETCH_LIMIT] 拉取条数上限，默认 "20"。
 * @property {string} [QQ_STRICT_ALIAS_MATCH] 严格别名匹配，默认关闭。
 * @property {string} [PROXY_POOL] 中继代理池：换行/逗号/分号分隔的 HTTPS 端点，可选 `url|secret` 后缀。
 * @property {string} [PROXY_SELECTION] 代理调度：round_robin(默认) | random | least_failures。
 * @property {string} [PROXY_TIMEOUT_MS] 单中继超时，默认 "15000"。
 * @property {string} [PROXY_RETRY] 失败重试中继数，默认 "2"。
 * @property {string} [RELAY_AUTH] 调用中继的共享密钥（也可每条目用 `|secret` 指定）。
 * @property {string} [PROXY_FALLBACK_DIRECT] "1" 时所有中继失败回退本地直连，默认关闭。
 */

const DEFAULT_FETCH_LIMIT = 20;
const DEFAULT_IMAP_HOST = "imap.qq.com";
const DEFAULT_IMAP_PORT = 993;
const DEFAULT_POP3_HOST = "pop.qq.com";
const DEFAULT_POP3_PORT = 995;

function jsonResponse(data, status = 200) {
  const headers = { "content-type": "application/json; charset=utf-8" };
  return new Response(JSON.stringify(data, null, 2), { status, headers });
}

function errorMessage(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

function normalizePath(pathname) {
  let path = String(pathname || "/").split("?")[0];
  if (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  if (!path.startsWith("/")) path = `/${path}`;
  return path;
}

function randomLocalPart(length = 10) {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  let result = "";
  for (let i = 0; i < length; i += 1) {
    result += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return result;
}

async function readJson(request) {
  try {
    const text = await request.text();
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

function bearerToken(request) {
  const header = String(request.headers.get("authorization") || "");
  if (header.startsWith("Bearer ")) return header.slice(7).trim();
  return "";
}

function tokenFromRequest(request, body = {}) {
  const auth = bearerToken(request);
  if (auth) return auth;
  if (body && (body.token || body.jwt)) return String(body.token || body.jwt);
  const url = new URL(request.url);
  const fromQuery = url.searchParams.get("token") || url.searchParams.get("jwt");
  if (fromQuery) return String(fromQuery);
  const address = url.searchParams.get("address") || url.searchParams.get("email");
  if (address) return String(address).split("@", 1)[0];
  return "";
}

// ---------------------------------------------------------------------------
// 域名池
// ---------------------------------------------------------------------------

/** 解析 DOMAIN 为域名池（换行/逗号/分号分隔），单域名向后兼容。 */
function domainPool(env) {
  const raw = String(env.DOMAIN || "").trim();
  if (!raw) throw new Error("缺少 DOMAIN 环境变量");
  const list = raw
    .split(/\r?\n|[,;]/)
    .map((item) => item.trim())
    .filter(Boolean);
  if (!list.length) throw new Error("缺少 DOMAIN 环境变量");
  return list;
}

let rrCounter = 0;
function nextRoundRobin(mod) {
  const idx = rrCounter % mod;
  rrCounter = (rrCounter + 1) % mod;
  return idx;
}

/** FNV-1a 哈希，用于 hash 选域策略。 */
function hashIndex(str, len) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0) % len;
}

/**
 * 生成临时邮箱地址，并按策略从域名池选域。
 * @returns {{ domain: string, domainIndex: number, localPart: string, address: string, token: string }}
 */
function makeAddress(request, env, body = {}) {
  const url = new URL(request.url);
  const overrideDomain = String(body.domain || url.searchParams.get("domain") || "").trim();
  const name = String(body.name || body.localPart || url.searchParams.get("name") || "").trim();
  const localPart = name || randomLocalPart(10);

  let domainIndex = -1;
  let domain;

  if (overrideDomain) {
    domain = overrideDomain;
  } else {
    const pool = domainPool(env);
    const strategy = String(env.DOMAIN_SELECTION || "round_robin").toLowerCase();
    if (strategy === "hash") {
      domainIndex = hashIndex(localPart, pool.length);
    } else if (strategy === "random") {
      domainIndex = Math.floor(Math.random() * pool.length);
    } else {
      domainIndex = nextRoundRobin(pool.length);
    }
    domain = pool[domainIndex];
  }

  const address = `${localPart}@${domain}`;
  // token 编码域名索引，便于无状态取信；显式指定域名时不编码以保持兼容。
  const token = domainIndex >= 0 ? `${localPart}.${domainIndex}` : localPart;
  return { domain, domainIndex, localPart, address, token };
}

/**
 * 解码 token 还原 localPart 与域名。
 * - 含 `@`：视为完整地址。
 * - 含 `.N`：N 为域名在池中的下标。
 * - 无索引（旧 token）：单域名直接用 pool[0]；多域名返回 domain=null 交由调用方遍历。
 * @returns {{ localPart: string, domain: string|null }}
 */
function decodeToken(token, env) {
  const raw = String(token || "");
  if (raw.includes("@")) {
    const [localPart, ...rest] = raw.split("@");
    return { localPart, domain: rest.join("@") };
  }
  const idx = raw.lastIndexOf(".");
  if (idx > 0) {
    const localPart = raw.slice(0, idx);
    const di = Number(raw.slice(idx + 1));
    const pool = domainPool(env);
    if (Number.isInteger(di) && di >= 0 && di < pool.length) {
      return { localPart, domain: pool[di] };
    }
  }
  const pool = domainPool(env);
  if (pool.length === 1) return { localPart: raw, domain: pool[0] };
  return { localPart: raw, domain: null };
}

// ---------------------------------------------------------------------------
// 中继代理池
// ---------------------------------------------------------------------------

const proxyFailures = new Map();

function parseProxyEntry(entry) {
  const [url, secret] = entry.split("|");
  return { url: url.trim(), secret: (secret || "").trim() };
}

function proxyPool(env) {
  const raw = String(env.PROXY_POOL || "").trim();
  if (!raw) return [];
  return raw
    .split(/\r?\n|[,;]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .map(parseProxyEntry);
}

function pickProxyIndex(proxies, strategy) {
  if (strategy === "random") return Math.floor(Math.random() * proxies.length);
  if (strategy === "least_failures") {
    let best = 0;
    for (let i = 1; i < proxies.length; i += 1) {
      if ((proxyFailures.get(proxies[i].url) || 0) < (proxyFailures.get(proxies[best].url) || 0)) {
        best = i;
      }
    }
    return best;
  }
  return nextRoundRobin(proxies.length);
}

/** 构造下发给中继的载荷（含凭据 env 与任务参数）。 */
function buildRelayPayload(env, aliasAddress, detailId, limit, offset) {
  const credsEnv = {
    QQ_MAIL_USER: String(env.QQ_MAIL_USER || env.QQ_MAIL_ACCOUNT || "").trim(),
    QQ_MAIL_AUTH_CODE: String(env.QQ_MAIL_AUTH_CODE || env.QQ_MAIL_PASSWORD || "").trim(),
    QQ_MAIL_HOST: String(env.QQ_MAIL_HOST || DEFAULT_POP3_HOST).trim(),
    QQ_MAIL_PORT: String(env.QQ_MAIL_PORT || DEFAULT_POP3_PORT).trim(),
    QQ_IMAP_HOST: String(env.QQ_IMAP_HOST || env.IMAP_HOST || DEFAULT_IMAP_HOST).trim(),
    QQ_IMAP_PORT: String(env.QQ_IMAP_PORT || env.IMAP_PORT || DEFAULT_IMAP_PORT).trim(),
    QQ_STRICT_ALIAS_MATCH: String(env.QQ_STRICT_ALIAS_MATCH || ""),
    QQ_IMAP_DELETE: String(env.QQ_IMAP_DELETE || "1"),
    QQ_FETCH_LIMIT: String(env.QQ_FETCH_LIMIT || DEFAULT_FETCH_LIMIT),
  };
  return { env: credsEnv, alias: aliasAddress, limit, offset, detailId };
}

/**
 * 通过中继代理池分发任务，失败/超时自动轮换重试。
 * @returns {Promise<any>} 中继返回的 JSON 数据。
 */
async function dispatchToProxy(env, action, payload) {
  const proxies = proxyPool(env);
  if (!proxies.length) return null;

  const strategy = String(env.PROXY_SELECTION || "round_robin").toLowerCase();
  const timeout = Number(env.PROXY_TIMEOUT_MS || 15000) || 15000;
  const maxRetry = Math.max(1, Number(env.PROXY_RETRY || 2) || 2);
  const relayAuth = String(env.RELAY_AUTH || "").trim();

  const path = action === "delete" ? "/delete" : "/fetch";
  let start = pickProxyIndex(proxies, strategy);
  let lastError = "";

  for (let attempt = 0; attempt < Math.min(maxRetry, proxies.length); attempt += 1) {
    const proxy = proxies[(start + attempt) % proxies.length];
    const auth = proxy.secret || relayAuth;
    if (!auth) {
      lastError = "中继缺少鉴权(RELAY_AUTH 或条目 |secret)";
      continue;
    }
    try {
      const resp = await fetch(`${proxy.url.replace(/\/+$/, "")}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-relay-auth": auth },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(timeout),
      });
      if (!resp.ok) {
        lastError = `中继返回 ${resp.status}`;
        proxyFailures.set(proxy.url, (proxyFailures.get(proxy.url) || 0) + 1);
        continue;
      }
      proxyFailures.set(proxy.url, 0);
      return await resp.json();
    } catch (error) {
      lastError = errorMessage(error);
      proxyFailures.set(proxy.url, (proxyFailures.get(proxy.url) || 0) + 1);
    }
  }

  throw new Error(`所有中继均失败: ${lastError}`);
}

function useProxy(env) {
  return proxyPool(env).length > 0;
}

async function runFetch(env, aliasAddress, detailId, limit, offset) {
  if (useProxy(env)) {
    try {
      const data = await dispatchToProxy(env, "fetch", buildRelayPayload(env, aliasAddress, detailId, limit, offset));
      return data.messages || [];
    } catch (error) {
      if (String(env.PROXY_FALLBACK_DIRECT || "") !== "1") throw error;
    }
  }
  return fetchMessages(env, aliasAddress, detailId, limit, offset);
}

async function runDelete(env, aliasAddress, detailId) {
  if (useProxy(env)) {
    try {
      const data = await dispatchToProxy(env, "delete", buildRelayPayload(env, aliasAddress, detailId, 0, 0));
      return data;
    } catch (error) {
      if (String(env.PROXY_FALLBACK_DIRECT || "") !== "1") throw error;
    }
  }
  return deleteMessages(env, aliasAddress, detailId);
}

// ---------------------------------------------------------------------------
// 路由处理
// ---------------------------------------------------------------------------

async function handleMails(request, env, path) {
  const url = new URL(request.url);
  const body = request.method === "POST" || request.method === "DELETE" ? await readJson(request) : {};
  const token = tokenFromRequest(request, body);
  if (!token) {
    return jsonResponse({ error: "缺少 token（Authorization: Bearer <token> 或 ?token=）" }, 401);
  }

  const decoded = decodeToken(token, env);
  const limit = Number(url.searchParams.get("limit") || body.limit || env.QQ_FETCH_LIMIT || DEFAULT_FETCH_LIMIT) || DEFAULT_FETCH_LIMIT;
  const offset = Number(url.searchParams.get("offset") || body.offset || 0) || 0;
  const detailId = url.searchParams.get("detailId") || body.detailId || "";

  const aliases = decoded.domain
    ? [{ domain: decoded.domain }]
    : domainPool(env).map((domain) => ({ domain }));

  if (request.method === "DELETE") {
    if (!detailId) {
      return jsonResponse({ error: "缺少 detailId，无法删除指定邮件" }, 400);
    }
    let lastResult = null;
    for (const alias of aliases) {
      const aliasAddress = `${decoded.localPart}@${alias.domain}`;
      const result = await runDelete(env, aliasAddress, detailId);
      lastResult = result;
      if (result && Array.isArray(result.messages) && result.messages.length) {
        return jsonResponse({
          message: `已删除 ${result.messages.length} 封邮件（POP3 ${result.pop3?.deleted || 0} 封，IMAP ${result.imap?.deleted || 0} 封）`,
          data: result,
        });
      }
    }
    return jsonResponse({
      message: "未找到匹配邮件",
      data: lastResult,
    });
  }

  let messages = [];
  for (const alias of aliases) {
    const aliasAddress = `${decoded.localPart}@${alias.domain}`;
    const msgs = await runFetch(env, aliasAddress, detailId, limit, offset);
    if (msgs.length) {
      messages = msgs;
      break;
    }
  }

  if (!messages.length && aliases.length) {
    messages = await runFetch(env, `${decoded.localPart}@${aliases[0].domain}`, detailId, limit, offset);
  }

  const list = detailId ? messages.filter((m) => String(m.id) === detailId) : messages;
  if (detailId && !list.length) {
    return jsonResponse({ error: "未找到该邮件或无权访问" }, 404);
  }
  return jsonResponse({ count: list.length, messages: list });
}

async function handleNewAddress(request, env) {
  const body = request.method === "POST" ? await readJson(request) : {};
  const mailbox = makeAddress(request, env, body);
  return jsonResponse({
    address: mailbox.address,
    token: mailbox.token,
    jwt: mailbox.token,
    domain: mailbox.domain,
    domainIndex: mailbox.domainIndex,
  });
}

async function handleToken(request, env) {
  const body = request.method === "POST" ? await readJson(request) : {};
  const token = tokenFromRequest(request, body);
  if (token) {
    return jsonResponse({ token, jwt: token });
  }
  const mailbox = makeAddress(request, env, body);
  return jsonResponse({ token: mailbox.token, jwt: mailbox.token });
}

function handleDomains(env) {
  const pool = domainPool(env);
  return jsonResponse({
    results: pool.map((domain) => ({ domain, isVerified: true })),
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const origin = request.headers.get("origin") || "";
    const cors = {
      "Access-Control-Allow-Origin": origin || "*",
      "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, x-relay-auth",
      "Access-Control-Max-Age": "86400",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "")) {
      return jsonResponse({
        service: "grokreg temporary email service",
        endpoints: ["/health", "/api/new_address", "/api/token", "/api/mails", "/api/domains"],
      });
    }
    if (url.pathname === "/health") {
      return jsonResponse({ ok: true });
    }

    const path = normalizePath(url.pathname);
    try {
      if (path === "/api/mails" || path === "/mails") {
        return await handleMails(request, env, path);
      }
      if (path === "/api/new_address" || path === "/new_address" || path === "/api/address" || path === "/address") {
        return await handleNewAddress(request, env);
      }
      if (path === "/api/token" || path === "/token") {
        return await handleToken(request, env);
      }
      if (path === "/api/domains" || path === "/domains") {
        return handleDomains(env);
      }
      return jsonResponse({ error: "未找到路由", path }, 404);
    } catch (error) {
      return jsonResponse({ error: errorMessage(error) }, 500);
    }
  },
};
