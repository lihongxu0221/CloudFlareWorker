import { connect } from "cloudflare:sockets";

const DEFAULT_POP3_HOST = "pop.qq.com";
const DEFAULT_POP3_PORT = 995;
const DEFAULT_IMAP_HOST = "imap.qq.com";
const DEFAULT_IMAP_PORT = 993;
const DEFAULT_FETCH_LIMIT = 20;

const encoder = new TextEncoder();
const utf8Decoder = new TextDecoder("utf-8");

function jsonResponse(data, status = 200) {
  return Response.json(data, {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, content-type, x-custom-auth, x-admin-auth",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    },
  });
}

function normalizePath(pathname) {
  const path = String(pathname || "/").replace(/\/+$/, "");
  return path || "/";
}

function randomLocalPart(length = 10) {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (byte) => chars[byte % chars.length]).join("");
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

function domainFromEnv(env) {
  const domain = String(env.DOMAIN || "").trim();
  if (!domain) {
    throw new Error("缺少 DOMAIN 环境变量");
  }
  return domain;
}

function makeAddress(request, env, body = {}) {
  const url = new URL(request.url);
  const domain = String(body.domain || url.searchParams.get("domain") || domainFromEnv(env)).trim();
  const name = String(body.name || body.localPart || url.searchParams.get("name") || "").trim();
  const localPart = name || randomLocalPart(10);
  return {
    domain,
    localPart,
    address: `${localPart}@${domain}`,
  };
}

function bearerToken(request) {
  const authorization = request.headers.get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : "";
}

function tokenFromRequest(request, body = {}) {
  const token = bearerToken(request) || String(body.token || body.jwt || "").trim();
  if (token) return token;
  const address = String(body.address || "").trim();
  return address.includes("@") ? address.split("@", 1)[0] : "";
}

function parseContentParam(contentType, key) {
  const match = String(contentType || "").match(new RegExp(`${key}\\s*=\\s*"?([^";]+)"?`, "i"));
  return match ? match[1].trim() : "";
}

function decodeBytes(bytes, charset = "utf-8") {
  try {
    return new TextDecoder(charset || "utf-8").decode(bytes);
  } catch {
    return utf8Decoder.decode(bytes);
  }
}

function decodeBase64(text, charset = "utf-8") {
  const binary = atob(String(text || "").replace(/\s+/g, ""));
  return decodeBytes(Uint8Array.from(binary, (char) => char.charCodeAt(0)), charset);
}

function decodeQuotedPrintable(text, charset = "utf-8") {
  const input = String(text || "").replace(/=\r?\n/g, "");
  const bytes = [];
  for (let i = 0; i < input.length; i += 1) {
    if (input[i] === "=" && /^[0-9A-Fa-f]{2}$/.test(input.slice(i + 1, i + 3))) {
      bytes.push(parseInt(input.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      bytes.push(input.charCodeAt(i) & 0xff);
    }
  }
  return decodeBytes(new Uint8Array(bytes), charset);
}

function decodeMimeWords(text) {
  return String(text || "").replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/g, (_, charset, type, value) => {
    try {
      if (String(type).toLowerCase() === "b") {
        return decodeBase64(value, charset);
      }
      return decodeQuotedPrintable(String(value).replace(/_/g, " "), charset);
    } catch {
      return value;
    }
  });
}

function stripHtml(html) {
  return String(html || "")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<\/p>|<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;/gi, "'")
    .replace(/\s+\n/g, "\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function splitHeaderAndBody(raw) {
  const normalized = String(raw || "");
  const crlf = normalized.indexOf("\r\n\r\n");
  if (crlf >= 0) return [normalized.slice(0, crlf), normalized.slice(crlf + 4)];
  const lf = normalized.indexOf("\n\n");
  if (lf >= 0) return [normalized.slice(0, lf), normalized.slice(lf + 2)];
  return [normalized, ""];
}

function parseHeaders(headerText) {
  const lines = String(headerText || "").replace(/\r\n/g, "\n").split("\n");
  const unfolded = [];
  for (const line of lines) {
    if (/^[ \t]/.test(line) && unfolded.length) {
      unfolded[unfolded.length - 1] += ` ${line.trim()}`;
    } else if (line.includes(":")) {
      unfolded.push(line);
    }
  }

  const headers = new Map();
  for (const line of unfolded) {
    const idx = line.indexOf(":");
    const key = line.slice(0, idx).trim().toLowerCase();
    const value = decodeMimeWords(line.slice(idx + 1).trim());
    if (!headers.has(key)) headers.set(key, []);
    headers.get(key).push(value);
  }
  return headers;
}

function header(headers, name) {
  return (headers.get(String(name).toLowerCase()) || []).join(", ");
}

function splitMultipart(body, boundary) {
  const marker = `--${boundary}`;
  const endMarker = `--${boundary}--`;
  const lines = String(body || "").replace(/\r\n/g, "\n").split("\n");
  const parts = [];
  let current = [];
  let active = false;

  for (const line of lines) {
    if (line === marker) {
      if (active && current.length) parts.push(current.join("\r\n"));
      current = [];
      active = true;
      continue;
    }
    if (line === endMarker) {
      if (active && current.length) parts.push(current.join("\r\n"));
      break;
    }
    if (active) current.push(line);
  }

  return parts;
}

function decodeBody(body, contentType, transferEncoding) {
  const charset = parseContentParam(contentType, "charset") || "utf-8";
  const encoding = String(transferEncoding || "").trim().toLowerCase();
  if (encoding === "base64") return decodeBase64(body, charset);
  if (encoding === "quoted-printable") return decodeQuotedPrintable(body, charset);
  return String(body || "");
}

function extractBodyParts(headers, body) {
  const contentType = header(headers, "content-type") || "text/plain";
  const transferEncoding = header(headers, "content-transfer-encoding");
  const mimeType = contentType.split(";")[0].trim().toLowerCase();

  if (mimeType.startsWith("multipart/")) {
    const boundary = parseContentParam(contentType, "boundary");
    if (!boundary) return { text: String(body || ""), html: "" };

    const textParts = [];
    const htmlParts = [];
    for (const part of splitMultipart(body, boundary)) {
      const [partHeader, partBody] = splitHeaderAndBody(part);
      const nested = extractBodyParts(parseHeaders(partHeader), partBody);
      if (nested.text) textParts.push(nested.text);
      if (nested.html) htmlParts.push(nested.html);
    }
    return {
      text: textParts.join("\n").trim(),
      html: htmlParts.join("\n").trim(),
    };
  }

  const decoded = decodeBody(body, contentType, transferEncoding);
  if (mimeType.includes("html")) {
    return { text: stripHtml(decoded), html: decoded };
  }
  return { text: decoded, html: "" };
}

function parseAddresses(value) {
  const found = [];
  const seen = new Set();
  const regex = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;
  let match;
  while ((match = regex.exec(String(value || "")))) {
    const address = match[0].toLowerCase();
    if (!seen.has(address)) {
      found.push({ address });
      seen.add(address);
    }
  }
  return found;
}

function parseEmail(raw, id, aliasAddress) {
  const [headerText, body] = splitHeaderAndBody(raw);
  const headers = parseHeaders(headerText);
  const parts = extractBodyParts(headers, body);
  const subject = header(headers, "subject");
  const toHeader = [
    header(headers, "to"),
    header(headers, "cc"),
    header(headers, "delivered-to"),
    header(headers, "x-original-to"),
    header(headers, "x-forwarded-to"),
    header(headers, "envelope-to"),
  ].filter(Boolean).join(", ");
  const text = parts.text || stripHtml(parts.html) || raw;

  return {
    id: String(id),
    msgid: String(id),
    address: aliasAddress,
    from: header(headers, "from"),
    to: parseAddresses(toHeader || aliasAddress),
    subject,
    date: header(headers, "date"),
    text,
    content: text,
    body: text,
    raw,
    intro: text.slice(0, 200),
    snippet: text.slice(0, 200),
    html: parts.html ? [parts.html] : [],
  };
}

class Pop3Reader {
  constructor(readable) {
    this.reader = readable.getReader();
    this.buffer = "";
  }

  async line() {
    for (;;) {
      const idx = this.buffer.indexOf("\r\n");
      if (idx >= 0) {
        const line = this.buffer.slice(0, idx);
        this.buffer = this.buffer.slice(idx + 2);
        return line;
      }
      const { value, done } = await this.reader.read();
      if (done) {
        const rest = this.buffer;
        this.buffer = "";
        return rest || null;
      }
      this.buffer += utf8Decoder.decode(value, { stream: true });
    }
  }

  async multiline() {
    const lines = [];
    for (;;) {
      const line = await this.line();
      if (line === null || line === ".") break;
      lines.push(line.startsWith("..") ? line.slice(1) : line);
    }
    return lines;
  }
}

async function writeLine(writer, text) {
  await writer.write(encoder.encode(`${text}\r\n`));
}

async function pop3Command(reader, writer, command, multiline = false) {
  await writeLine(writer, command);
  const first = await reader.line();
  if (!first || !/^\+OK\b/i.test(first)) {
    throw new Error(`${command} 失败: ${first || "空响应"}`);
  }
  return multiline ? reader.multiline() : [];
}

async function quitPop3(reader, writer) {
  await writeLine(writer, "QUIT");
  const response = await reader.line();
  if (!response || !/^\+OK\b/i.test(response)) {
    throw new Error(`QUIT failed: ${response || "empty response"}`);
  }
  return response;
}

async function withPop3(env, callback, { commitRequired = false } = {}) {
  const host = String(env.QQ_MAIL_HOST || DEFAULT_POP3_HOST).trim();
  const port = Number(env.QQ_MAIL_PORT || DEFAULT_POP3_PORT) || DEFAULT_POP3_PORT;
  const user = String(env.QQ_MAIL_USER || env.QQ_MAIL_ACCOUNT || "").trim();
  const password = String(env.QQ_MAIL_AUTH_CODE || env.QQ_MAIL_PASSWORD || "").trim();

  if (!user) throw new Error("缺少 QQ_MAIL_USER");
  if (!password) throw new Error("缺少 QQ_MAIL_AUTH_CODE");

  const socket = connect(
    { hostname: host, port },
    { secureTransport: "on", allowHalfOpen: false }
  );
  const reader = new Pop3Reader(socket.readable);
  const writer = socket.writable.getWriter();
  let result;
  let callbackError;

  try {
    const greeting = await reader.line();
    if (!greeting || !/^\+OK\b/i.test(greeting)) {
      throw new Error(`POP3 握手失败: ${greeting || "空响应"}`);
    }

    await pop3Command(reader, writer, `USER ${user}`);
    await pop3Command(reader, writer, `PASS ${password}`);
    result = await callback(reader, writer);
  } catch (error) {
    callbackError = error;
  }

  // POP3 的 DELE 仅在 QUIT 成功时真正提交；删信场景必须保证 QUIT 成功。
  let quitError;
  try {
    await quitPop3(reader, writer);
  } catch (error) {
    quitError = error;
  }

  try {
    writer.releaseLock();
  } catch {
    // ignore
  }
  try {
    socket.close();
  } catch {
    // ignore
  }

  if (callbackError) throw callbackError;
  if (commitRequired && quitError) {
    throw new Error(`POP3 删除未提交(QUIT 失败): ${quitError.message || quitError}`);
  }
  return result;
}

class ImapReader {
  constructor(readable) {
    this.reader = readable.getReader();
    this.buffer = "";
  }

  async line() {
    for (;;) {
      const idx = this.buffer.indexOf("\r\n");
      if (idx >= 0) {
        const line = this.buffer.slice(0, idx);
        this.buffer = this.buffer.slice(idx + 2);
        return line;
      }
      const { value, done } = await this.reader.read();
      if (done) {
        const rest = this.buffer;
        this.buffer = "";
        return rest || null;
      }
      this.buffer += utf8Decoder.decode(value, { stream: true });
    }
  }

  async readUntilTag(tag) {
    const lines = [];
    const doneRe = new RegExp(`^${tag}\\s+(OK|NO|BAD)\\b`, "i");
    for (;;) {
      const line = await this.line();
      if (line === null) {
        throw new Error(`IMAP 连接在等待 ${tag} 时断开`);
      }
      lines.push(line);
      if (doneRe.test(line)) return lines;
    }
  }
}

function quoteImapString(value) {
  return `"${String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

async function withImap(env, callback) {
  const host = String(env.QQ_IMAP_HOST || env.IMAP_HOST || DEFAULT_IMAP_HOST).trim();
  const port = Number(env.QQ_IMAP_PORT || env.IMAP_PORT || DEFAULT_IMAP_PORT) || DEFAULT_IMAP_PORT;
  const user = String(env.QQ_MAIL_USER || env.QQ_MAIL_ACCOUNT || "").trim();
  const password = String(env.QQ_MAIL_AUTH_CODE || env.QQ_MAIL_PASSWORD || "").trim();

  if (!user) throw new Error("缺少 QQ_MAIL_USER");
  if (!password) throw new Error("缺少 QQ_MAIL_AUTH_CODE");

  const socket = connect(
    { hostname: host, port },
    { secureTransport: "on", allowHalfOpen: false }
  );
  const reader = new ImapReader(socket.readable);
  const writer = socket.writable.getWriter();
  let tagSeq = 0;

  const nextTag = () => {
    tagSeq += 1;
    return `A${String(tagSeq).padStart(4, "0")}`;
  };

  const command = async (raw) => {
    const tag = nextTag();
    await writeLine(writer, `${tag} ${raw}`);
    const lines = await reader.readUntilTag(tag);
    const last = lines[lines.length - 1] || "";
    if (!new RegExp(`^${tag}\\s+OK\\b`, "i").test(last)) {
      throw new Error(`IMAP ${raw.split(" ")[0]} 失败: ${last || "空响应"}`);
    }
    return lines;
  };

  try {
    const greeting = await reader.line();
    if (!greeting || !/^\*\s+OK\b/i.test(greeting)) {
      throw new Error(`IMAP 握手失败: ${greeting || "空响应"}`);
    }
    await command(`LOGIN ${quoteImapString(user)} ${quoteImapString(password)}`);
    return await callback({ command, reader, writer, nextTag });
  } finally {
    try {
      await command("LOGOUT");
    } catch {
      // ignore logout errors
    }
    try {
      writer.releaseLock();
    } catch {
      // ignore
    }
    try {
      socket.close();
    } catch {
      // ignore
    }
  }
}

/**
 * 通过 IMAP 在服务器上真正删除邮件，使 QQ 网页端同步消失。
 * 优先用 Message-ID 匹配；若无则用主题精确匹配。
 * QQ 网页端走 IMAP 存储，仅 POP3 DELE 往往只影响 POP 视图，网页仍可见。
 */
async function deleteMessagesViaImap(env, { messageIds = [], subjects = [] } = {}) {
  const wantMsgIds = [...new Set(messageIds.map((item) => String(item || "").trim()).filter(Boolean))];
  const wantSubjects = [...new Set(subjects.map((item) => String(item || "").trim()).filter(Boolean))];
  if (!wantMsgIds.length && !wantSubjects.length) {
    return { ok: false, deleted: 0, messages: [], error: "缺少 IMAP 匹配条件" };
  }

  return withImap(env, async ({ command }) => {
    await command('SELECT "INBOX"');
    const uids = new Set();

    for (const mid of wantMsgIds) {
      const bare = mid.replace(/^<|>$/g, "");
      const variants = [`<${bare}>`, bare];
      for (const variant of variants) {
        try {
          const lines = await command(`UID SEARCH HEADER Message-ID ${quoteImapString(variant)}`);
          for (const line of lines) {
            const match = line.match(/^\*\s+SEARCH\s+(.*)$/i);
            if (!match) continue;
            for (const token of match[1].trim().split(/\s+/).filter(Boolean)) {
              if (/^\d+$/.test(token)) uids.add(token);
            }
          }
          if (uids.size) break;
        } catch {
          // 继续尝试下一变体
        }
      }
    }

    if (!uids.size) {
      for (const subject of wantSubjects) {
        // SUBJECT 比 HEADER Subject 兼容性更好；失败再试 HEADER
        const queries = [
          `UID SEARCH SUBJECT ${quoteImapString(subject)}`,
          `UID SEARCH HEADER Subject ${quoteImapString(subject)}`,
        ];
        for (const query of queries) {
          try {
            const lines = await command(query);
            for (const line of lines) {
              const match = line.match(/^\*\s+SEARCH\s+(.*)$/i);
              if (!match) continue;
              for (const token of match[1].trim().split(/\s+/).filter(Boolean)) {
                if (/^\d+$/.test(token)) uids.add(token);
              }
            }
            if (uids.size) break;
          } catch {
            // ignore subject search errors
          }
        }
      }
    }

    if (!uids.size) {
      return { ok: false, deleted: 0, messages: [], error: "IMAP 未找到匹配邮件" };
    }

    const uidList = [...uids].join(",");
    await command(`UID STORE ${uidList} +FLAGS.SILENT (\\Deleted)`);
    await command("EXPUNGE");

    return {
      ok: true,
      deleted: uids.size,
      messages: [...uids].map((uid) => ({ uid, protocol: "imap" })),
      error: "",
    };
  });
}

function extractMimeMessageId(raw) {
  const text = String(raw || "");
  const match = text.match(/^message-id:\s*(.+)$/im);
  if (!match) return "";
  return String(match[1] || "").trim().replace(/\s+/g, "");
}

async function listPop3Entries(reader, writer) {
  try {
    const uidLines = await pop3Command(reader, writer, "UIDL", true);
    return uidLines
      .map((line) => line.match(/^(\d+)\s+(\S+)/))
      .filter(Boolean)
      .map((match) => ({ number: Number(match[1]), id: match[2] }));
  } catch {
    const listLines = await pop3Command(reader, writer, "LIST", true);
    return listLines
      .map((line) => line.match(/^(\d+)\s+/))
      .filter(Boolean)
      .map((match) => ({ number: Number(match[1]), id: match[1] }));
  }
}

function messageMatchesAlias(message, aliasAddress) {
  const alias = String(aliasAddress || "").toLowerCase();
  if (!alias) return true;
  const recipients = Array.isArray(message.to) ? message.to : [];
  if (recipients.some((item) => String(item.address || "").toLowerCase() === alias)) {
    return true;
  }
  return String(message.raw || "").toLowerCase().includes(alias);
}

async function fetchMessages(env, aliasAddress, detailId, limit, offset) {
  return withPop3(env, async (reader, writer) => {
    const entries = (await listPop3Entries(reader, writer)).reverse();
    const selected = detailId
      ? entries.filter((item) => String(item.id) === detailId || String(item.number) === detailId)
      : entries.slice(offset, offset + limit);
    const messages = [];

    for (const entry of selected) {
      const rawLines = await pop3Command(reader, writer, `RETR ${entry.number}`, true);
      const message = parseEmail(rawLines.join("\r\n"), entry.id, aliasAddress);
      if (detailId || messageMatchesAlias(message, aliasAddress)) {
        messages.push(message);
      }
    }

    // 有些转发/代收链路会剥掉原始收件人头；非严格模式下退回最近邮件，
    // 让注册机仍能从正文中提取验证码。并发注册时建议开启 QQ_STRICT_ALIAS_MATCH=1。
    if (!detailId && messages.length === 0 && String(env.QQ_STRICT_ALIAS_MATCH || "") !== "1") {
      for (const entry of selected.slice(0, Math.min(selected.length, 5))) {
        const rawLines = await pop3Command(reader, writer, `RETR ${entry.number}`, true);
        messages.push(parseEmail(rawLines.join("\r\n"), entry.id, aliasAddress));
      }
    }

    return messages;
  });
}

async function deleteMessagesViaPop3(env, aliasAddress, detailId) {
  const strict = String(env.QQ_STRICT_ALIAS_MATCH || "") === "1";
  return withPop3(
    env,
    async (reader, writer) => {
      const entries = (await listPop3Entries(reader, writer)).reverse();
      const selected = detailId
        ? entries.filter((item) => String(item.id) === detailId || String(item.number) === detailId)
        : entries;
      const deleted = [];

      for (const entry of selected) {
        const rawLines = await pop3Command(reader, writer, `RETR ${entry.number}`, true);
        const raw = rawLines.join("\r\n");
        const message = parseEmail(raw, entry.id, aliasAddress);
        // 严格模式：必须匹配别名收件人才删除；
        // 非严格模式（默认，适配 QQ 邮箱 POP3 代收/转发链路剥掉收件人头的场景）：
        //   - 指定了 detailId 时直接按 id/序号删除；
        //   - 未指定 detailId 时仍要求别名匹配，避免误删无关邮件。
        const allowDelete = strict
          ? messageMatchesAlias(message, aliasAddress)
          : detailId
            ? true
            : messageMatchesAlias(message, aliasAddress);
        if (allowDelete) {
          await pop3Command(reader, writer, `DELE ${entry.number}`);
          deleted.push({
            id: String(entry.id),
            number: entry.number,
            subject: message.subject,
            // 仅使用真实 MIME Message-ID；勿回退到 POP3 UIDL（IMAP 搜不到）
            messageId: extractMimeMessageId(raw),
            protocol: "pop3",
          });
        }
      }

      return deleted;
    },
    { commitRequired: true }
  );
}

/**
 * 双通道删除：
 * 1) POP3 DELE + 强制 QUIT 提交（清理 POP 视图 / API 复查）
 * 2) IMAP STORE+EXPUNGE（真正从 QQ 服务器删除，网页端同步消失）
 *
 * 仅 POP3 时 QQ 网页端常仍可见（服务器保留副本 / POP 与网页不同步）。
 */
async function deleteMessages(env, aliasAddress, detailId) {
  const popDeleted = await deleteMessagesViaPop3(env, aliasAddress, detailId);
  const imapEnabled = String(env.QQ_IMAP_DELETE || "1") !== "0";
  let imapResult = { ok: false, deleted: 0, messages: [], error: "skipped" };

  if (imapEnabled && popDeleted.length) {
    try {
      imapResult = await deleteMessagesViaImap(env, {
        messageIds: popDeleted.map((item) => item.messageId).filter(Boolean),
        subjects: popDeleted.map((item) => item.subject).filter(Boolean),
      });
    } catch (error) {
      imapResult = {
        ok: false,
        deleted: 0,
        messages: [],
        error: error && error.message ? error.message : String(error),
      };
    }
  } else if (imapEnabled && !popDeleted.length) {
    imapResult = { ok: false, deleted: 0, messages: [], error: "POP3 未命中待删邮件" };
  }

  return {
    messages: popDeleted,
    pop3: { ok: popDeleted.length > 0, deleted: popDeleted.length },
    imap: imapResult,
  };
}

async function handleDomains(env) {
  const domain = domainFromEnv(env);
  return jsonResponse({
    results: [{ domain, isVerified: true }],
  });
}

async function handleNewAddress(request, env) {
  const body = request.method === "POST" ? await readJson(request) : {};
  const mailbox = makeAddress(request, env, body);
  return jsonResponse({
    address: mailbox.address,
    token: mailbox.localPart,
    jwt: mailbox.localPart,
  });
}

async function handleToken(request, env) {
  const body = request.method === "POST" ? await readJson(request) : {};
  const token = tokenFromRequest(request, body) || makeAddress(request, env, body).localPart;
  return jsonResponse({ token, jwt: token });
}

async function handleMails(request, env, path) {
  const url = new URL(request.url);
  const body = request.method === "POST" || request.method === "DELETE" ? await readJson(request) : {};
  const token = tokenFromRequest(request, body) || String(url.searchParams.get("token") || "").trim();
  if (!token) return jsonResponse({ error: "missing token" }, 401);

  const aliasAddress = `${token}@${domainFromEnv(env)}`.toLowerCase();
  const limit = Math.max(1, Math.min(Number(url.searchParams.get("limit") || env.QQ_FETCH_LIMIT || DEFAULT_FETCH_LIMIT) || DEFAULT_FETCH_LIMIT, 50));
  const offset = Math.max(0, Number(url.searchParams.get("offset") || 0) || 0);
  const match = path.match(/^\/api\/mails?\/(.+)$/);
  const detailId = match ? decodeURIComponent(match[1]) : "";

  if (request.method === "DELETE") {
    if (!detailId) return jsonResponse({ error: "missing mail id" }, 400);
    const result = await deleteMessages(env, aliasAddress, detailId);
    const messages = Array.isArray(result?.messages) ? result.messages : [];
    const imap = result?.imap || {};
    // pop3 命中即视为接口成功；imap 失败时仍返回详情，便于排查网页端残留
    return jsonResponse(
      {
        ok: messages.length > 0,
        deleted: messages.length,
        requestedId: detailId,
        messages,
        pop3: result?.pop3 || { ok: messages.length > 0, deleted: messages.length },
        imap: {
          ok: Boolean(imap.ok),
          deleted: Number(imap.deleted || 0) || 0,
          error: String(imap.error || ""),
          messages: Array.isArray(imap.messages) ? imap.messages : [],
        },
      },
      messages.length > 0 ? 200 : 404
    );
  }

  const messages = await fetchMessages(env, aliasAddress, detailId, limit, offset);

  if (detailId) {
    return jsonResponse(messages[0] || {});
  }
  return jsonResponse({ messages });
}

export default {
  async fetch(request, env) {
    const path = normalizePath(new URL(request.url).pathname);

    try {
      if (request.method === "OPTIONS") return jsonResponse({ ok: true });
      if (path === "/api/domains") return handleDomains(env);
      if (path === "/api/new_address" || path === "/admin/new_address" || path === "/accounts") {
        return handleNewAddress(request, env);
      }
      if (path === "/api/token" || path === "/token") return handleToken(request, env);
      if (path === "/api/mails" || path === "/api/mail" || path.startsWith("/api/mails/") || path.startsWith("/api/mail/")) {
        return handleMails(request, env, path);
      }
      return new Response("Path Not Found", { status: 404 });
    } catch (error) {
      return jsonResponse({ error: String(error?.message || error) }, 500);
    }
  },
};
