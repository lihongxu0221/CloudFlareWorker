import { fetchMessages, deleteMessages } from "./mailbox.js";

/**
 * 中继 Worker：作为独立部署的出口端点，接收主 Worker 分发的收件/删信任务，
 * 使用本 Worker 自身的出口 IP 建立 IMAP/POP3+TLS 连接并返回结果。
 *
 * 契约：
 *   POST /fetch  body: { env: CredsEnv, alias, limit, offset, detailId }
 *   POST /delete body: { env: CredsEnv, alias, limit, offset, detailId }
 * 鉴权：请求头 x-relay-auth 必须等于环境变量 RELAY_AUTH。
 * 返回：{ messages } 或 DeleteResult（messages/pop3/imap）。
 */

/**
 * @typedef {Object} RelayEnv
 * @property {string} [RELAY_AUTH] 调用方必须携带的共享密钥。
 * @property {string} [RELAY_TIMEOUT_MS] 单任务内部超时，默认 "20000"。
 */

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function errorMessage(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

function readJson(request) {
  return request.json().catch(() => ({}));
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, x-relay-auth",
        },
      });
    }

    if (request.method !== "POST") {
      return jsonResponse({ error: "仅支持 POST /fetch 与 POST /delete" }, 405);
    }

    const expectedAuth = String(env.RELAY_AUTH || "").trim();
    const providedAuth = String(request.headers.get("x-relay-auth") || "").trim();
    if (!expectedAuth || providedAuth !== expectedAuth) {
      return jsonResponse({ error: "未授权" }, 401);
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "");
    if (path !== "/fetch" && path !== "/delete") {
      return jsonResponse({ error: "未知路径，仅支持 /fetch 与 /delete" }, 404);
    }

    const body = await readJson(request);
    const creds = body.env && typeof body.env === "object" ? body.env : {};
    const alias = String(body.alias || "");
    const detailId = String(body.detailId || "");
    const limit = Number(body.limit || 20) || 20;
    const offset = Number(body.offset || 0) || 0;

    if (!alias) {
      return jsonResponse({ error: "缺少 alias" }, 400);
    }

    const timeoutMs = Number(env.RELAY_TIMEOUT_MS || 20000) || 20000;

    try {
      if (path === "/fetch") {
        const messages = await fetchMessages(creds, alias, detailId, limit, offset);
        return jsonResponse({ messages });
      }

      const result = await deleteMessages(creds, alias, detailId);
      return jsonResponse(result);
    } catch (error) {
      const message = errorMessage(error);
      return jsonResponse({ error: message }, 502);
    }
  },
};
