/**
 * 本地编辑器 / Cloudflare 官方编辑器辅助类型。
 * 运行时由 Cloudflare Workers 提供，不参与打包。
 */

interface Env {
  // 域名池：换行/逗号/分号分隔多个域名；单域名向后兼容
  DOMAIN?: string;
  // 选域策略：round_robin | random | hash
  DOMAIN_SELECTION?: string;
  QQ_MAIL_USER?: string;
  QQ_MAIL_ACCOUNT?: string;
  QQ_MAIL_AUTH_CODE?: string;
  QQ_MAIL_PASSWORD?: string;
  QQ_MAIL_HOST?: string;
  QQ_MAIL_PORT?: string | number;
  QQ_IMAP_HOST?: string;
  IMAP_HOST?: string;
  QQ_IMAP_PORT?: string | number;
  IMAP_PORT?: string | number;
  QQ_IMAP_DELETE?: string;
  QQ_FETCH_LIMIT?: string | number;
  QQ_STRICT_ALIAS_MATCH?: string;
  // 中继代理池（可选）
  PROXY_POOL?: string;
  PROXY_SELECTION?: string;
  PROXY_TIMEOUT_MS?: string;
  PROXY_RETRY?: string;
  RELAY_AUTH?: string;
  PROXY_FALLBACK_DIRECT?: string;
}

interface ExportedHandler<Env = unknown> {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Response | Promise<Response>;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}
