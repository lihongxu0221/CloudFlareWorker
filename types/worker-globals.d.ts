/**
 * 本地编辑器 / Cloudflare 官方编辑器辅助类型。
 * 运行时由 Cloudflare Workers 提供，不参与打包。
 */

interface Env {
  DOMAIN?: string;
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
}

interface ExportedHandler<Env = unknown> {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Response | Promise<Response>;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}
