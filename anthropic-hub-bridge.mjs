#!/usr/bin/env node
/**
 * anthropic-hub-bridge.mjs  —  协议翻译层
 *
 * Anthropic Messages API  <->  OpenAI Chat Completions
 *
 * 为什么要它：
 *   Claude Code (claude.exe) 只会说 Anthropic 协议 (/v1/messages)；
 *   WorkBuddy Hub 只会说 OpenAI 协议 (/v1/chat/completions)。
 *   两边不能直连。本进程坐在中间双向翻译。
 *
 * 副作用（正是我们要的）：
 *   claude 不再连接 api.anthropic.com，地区限制自然失效。
 *
 * 零依赖：只用 node:http + 全局 fetch（Node 18+）。
 */
import { createServer } from "node:http";
import { appendFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

const HERE = dirname(fileURLToPath(import.meta.url));
const LOG_DIR = join(HERE, "logs");
mkdirSync(LOG_DIR, { recursive: true });
const LOG_FILE = join(LOG_DIR, "bridge.log");

const PORT = Number(process.env.BRIDGE_PORT || 8820);
const HOST = process.env.BRIDGE_HOST || "127.0.0.1";
const HUB_BASE_URL = (process.env.HUB_BASE_URL || "http://127.0.0.1:8788").replace(/\/+$/, "");
// Hub 凭据来源，按优先级解析：
//   1. HUB_SETTINGS 环境变量（显式指定）
//   2. 本仓库内的 hub-settings.json（自行放置，已 gitignore）
//   3. HUB_API_KEY 环境变量（直接给 key）
//   4. 本机 WorkBuddy Hub 的默认位置（仅本机有效，换机请用 1~3）
const HUB_SETTINGS = (() => {
  if (process.env.HUB_SETTINGS) return process.env.HUB_SETTINGS;
  const local = join(HERE, "hub-settings.json");
  if (existsSync(local)) return local;
  return join(homedir(), ".qwenworkcn", "workspace", "mu55844kqqe7tm63",
    "workbuddy2api-hub", "accounts", "settings.json");
})();

const DEFAULT_MODEL = process.env.BRIDGE_MODEL || "deepseek-v4.1-flash";
const SMALL_MODEL = process.env.BRIDGE_SMALL_MODEL || DEFAULT_MODEL;
const LOG_BODIES = process.env.BRIDGE_LOG_BODIES === "1";
const QUIET = process.env.BRIDGE_QUIET === "1";

function resolveHubKey() {
  if (process.env.HUB_API_KEY) return process.env.HUB_API_KEY.trim();
  try {
    const cfg = JSON.parse(readFileSync(HUB_SETTINGS, "utf8"));
    const list = Array.isArray(cfg.api_keys) ? cfg.api_keys : [];
    const pick = list.find((x) => x && x.key && x.enabled !== false) || list.find((x) => x && x.key);
    if (pick) return String(pick.key).trim();
  } catch (e) {
    log("WARN", "cannot read hub settings: " + e.message);
  }
  return "";
}
const HUB_KEY = resolveHubKey();

function log(tag, msg) {
  const line = new Date().toISOString() + " [" + tag + "] " + msg + "\n";
  try { appendFileSync(LOG_FILE, line); } catch {}
  if (!QUIET) process.stdout.write(line);
}
const newId = (p) => p + randomBytes(12).toString("hex");

/* ------------------------------------------------------------------ */
/* 请求翻译：Anthropic -> OpenAI                                       */
/* ------------------------------------------------------------------ */

const blocksToText = (blocks) => (Array.isArray(blocks) ? blocks : [])
  .map((b) => (b && b.type === "text" ? (b.text || "") : ""))
  .join("");

function imageToDataUrl(source) {
  if (!source) return null;
  if (source.type === "base64" && source.data) {
    return "data:" + (source.media_type || "image/png") + ";base64," + source.data;
  }
  if (source.type === "url" && source.url) return source.url;
  return null;
}

function toolResultToText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((b) => {
      if (!b) return "";
      if (b.type === "text") return b.text || "";
      if (b.type === "image") return "[image omitted]";
      return "";
    }).join("");
  }
  try { return JSON.stringify(content); } catch { return String(content); }
}

function anthropicToOpenAIMessages(system, messages) {
  const out = [];
  if (system) {
    const text = typeof system === "string" ? system : blocksToText(system);
    if (text) out.push({ role: "system", content: text });
  }

  for (const m of Array.isArray(messages) ? messages : []) {
    if (!m || !m.role) continue;
    const content = m.content;

    if (typeof content === "string") {
      out.push({ role: m.role, content });
      continue;
    }
    const blocks = Array.isArray(content) ? content : [];

    if (m.role === "assistant") {
      const texts = [];
      const calls = [];
      for (const b of blocks) {
        if (!b) continue;
        if (b.type === "text") texts.push(b.text || "");
        else if (b.type === "tool_use") {
          calls.push({
            id: b.id || newId("call_"),
            type: "function",
            function: { name: b.name || "tool", arguments: JSON.stringify(b.input || {}) },
          });
        }
      }
      const joined = texts.join("");
      const msg = { role: "assistant" };
      if (joined) msg.content = joined;
      if (calls.length) msg.tool_calls = calls;
      else if (!joined) msg.content = "";
      out.push(msg);
      continue;
    }

    const parts = [];
    for (const b of blocks) {
      if (!b) continue;
      if (b.type === "tool_result") {
        out.push({
          role: "tool",
          tool_call_id: b.tool_use_id || newId("call_"),
          content: toolResultToText(b.content),
        });
      } else if (b.type === "text") {
        parts.push({ type: "text", text: b.text || "" });
      } else if (b.type === "image") {
        const url = imageToDataUrl(b.source);
        if (url) parts.push({ type: "image_url", image_url: { url } });
      }
    }
    if (parts.length) {
      const textOnly = parts.every((p) => p.type === "text");
      out.push({
        role: "user",
        content: textOnly ? parts.map((p) => p.text).join("") : parts,
      });
    }
  }
  return out;
}

function anthropicToolsToOpenAI(tools) {
  if (!Array.isArray(tools) || !tools.length) return undefined;
  const out = tools
    .filter((t) => t && t.name)
    .map((t) => ({
      type: "function",
      function: {
        name: t.name,
        description: t.description || "",
        parameters: t.input_schema || { type: "object", properties: {} },
      },
    }));
  return out.length ? out : undefined;
}

function anthropicToolChoiceToOpenAI(tc) {
  if (!tc || !tc.type) return undefined;
  if (tc.type === "auto") return "auto";
  if (tc.type === "any") return "required";
  if (tc.type === "none") return "none";
  if (tc.type === "tool" && tc.name) return { type: "function", function: { name: tc.name } };
  return undefined;
}

function pickModel(reqModel) {
  const name = String(reqModel || "");
  if (process.env.BRIDGE_MODEL_MAP) {
    try {
      const map = JSON.parse(process.env.BRIDGE_MODEL_MAP);
      if (map[name]) return map[name];
    } catch {}
  }
  // claude 的 haiku 档通常跑标题/小任务，单独映射可省钱
  if (/haiku/i.test(name)) return SMALL_MODEL;
  return DEFAULT_MODEL;
}

function buildOpenAIRequest(body) {
  const oai = {
    model: pickModel(body.model),
    messages: anthropicToOpenAIMessages(body.system, body.messages),
    stream: true,
    stream_options: { include_usage: true },
  };
  if (body.max_tokens != null) oai.max_tokens = body.max_tokens;
  const tools = anthropicToolsToOpenAI(body.tools);
  if (tools) oai.tools = tools;
  const choice = anthropicToolChoiceToOpenAI(body.tool_choice);
  if (choice) oai.tool_choice = choice;
  if (body.temperature != null) oai.temperature = body.temperature;
  if (body.top_p != null) oai.top_p = body.top_p;
  if (Array.isArray(body.stop_sequences) && body.stop_sequences.length) {
    oai.stop = body.stop_sequences;
  }
  return oai;
}

function estimateTokens(body) {
  let chars = 0;
  chars += typeof body.system === "string" ? body.system.length : blocksToText(body.system).length;
  for (const m of Array.isArray(body.messages) ? body.messages : []) {
    if (typeof (m && m.content) === "string") { chars += m.content.length; continue; }
    for (const b of Array.isArray(m && m.content) ? m.content : []) {
      if (!b) continue;
      if (b.type === "text") chars += (b.text || "").length;
      else if (b.type === "tool_use") chars += JSON.stringify(b.input || {}).length;
      else if (b.type === "tool_result") chars += toolResultToText(b.content).length;
      else if (b.type === "image") chars += 1600;
    }
  }
  for (const t of Array.isArray(body.tools) ? body.tools : []) chars += JSON.stringify(t).length;
  return Math.max(1, Math.round(chars / 3.5));
}

const STOP_REASON = {
  stop: "end_turn",
  length: "max_tokens",
  tool_calls: "tool_use",
  function_call: "tool_use",
  content_filter: "end_turn",
};

/* ------------------------------------------------------------------ */
/* 响应翻译：OpenAI SSE -> Anthropic SSE                                */
/* ------------------------------------------------------------------ */

const sse = (res, event, data) =>
  res.write("event: " + event + "\ndata: " + JSON.stringify(data) + "\n\n");

function applyChunk(acc, chunk) {
  if (chunk && chunk.usage) acc.usage = chunk.usage;
  const choice = chunk && Array.isArray(chunk.choices) ? chunk.choices[0] : null;
  if (!choice) return [];
  const delta = choice.delta || {};
  const events = [];

  if (typeof delta.content === "string" && delta.content) {
    acc.text += delta.content;
    events.push({ kind: "text", text: delta.content });
  }
  if (typeof delta.reasoning_content === "string" && delta.reasoning_content) {
    events.push({ kind: "thinking", text: delta.reasoning_content });
  }
  for (const tc of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
    const idx = tc.index == null ? 0 : tc.index;
    if (!acc.tools.has(idx)) acc.tools.set(idx, { id: tc.id || newId("toolu_"), name: "", args: "" });
    const slot = acc.tools.get(idx);
    if (tc.id) slot.id = tc.id;
    if (tc.function && tc.function.name) slot.name = tc.function.name;
    const frag = tc.function && typeof tc.function.arguments === "string" ? tc.function.arguments : "";
    if (frag) slot.args += frag;
    events.push({ kind: "tool", index: idx, id: slot.id, name: slot.name, args: frag });
  }
  if (choice.finish_reason) acc.stop = choice.finish_reason;
  return events;
}

async function* sseLines(response) {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const piece of response.body) {
    buf += decoder.decode(piece, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, nl).replace(/\r$/, "");
      buf = buf.slice(nl + 1);
      if (line.startsWith("data:")) yield line.slice(5).trim();
    }
  }
  const tail = buf.trim();
  if (tail.startsWith("data:")) yield tail.slice(5).trim();
}

function anthropicError(res, status, message, type) {
  if (res.headersSent) { try { res.end(); } catch {} return; }
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ type: "error", error: { type: type || "api_error", message: String(message) } }));
}

async function handleMessages(res, body, raw) {
  const oai = buildOpenAIRequest(body);
  const wantStream = body.stream === true;

  log("REQ", JSON.stringify({
    model: body.model, to: oai.model, stream: wantStream,
    msgs: oai.messages.length, tools: oai.tools ? oai.tools.length : 0,
    max_tokens: oai.max_tokens == null ? null : oai.max_tokens,
  }));
  if (LOG_BODIES) log("BODY", raw.slice(0, 4000));

  const headers = { "Content-Type": "application/json" };
  if (HUB_KEY) headers.Authorization = "Bearer " + HUB_KEY;

  let hub;
  try {
    hub = await fetch(HUB_BASE_URL + "/v1/chat/completions", {
      method: "POST", headers, body: JSON.stringify(oai),
    });
  } catch (e) {
    log("ERR", "hub unreachable: " + e.message);
    return anthropicError(res, 502, "Hub unreachable: " + e.message, "api_error");
  }

  if (!hub.ok) {
    const detail = await hub.text().catch(() => "");
    log("ERR", "hub " + hub.status + ": " + detail.slice(0, 300));
    const type = hub.status === 401 ? "authentication_error"
      : hub.status === 429 ? "rate_limit_error" : "api_error";
    return anthropicError(res, hub.status, detail.slice(0, 600) || "hub error", type);
  }

  const acc = { text: "", tools: new Map(), stop: null, usage: {} };
  const msgId = newId("msg_");
  const modelName = body.model || "claude";
  let blockIndex = -1;
  let openType = null;
  const toolBlocks = new Map();

  const stopOpen = () => {
    if (!openType) return;
    if (wantStream) sse(res, "content_block_stop", { type: "content_block_stop", index: blockIndex });
    openType = null;
  };
  const startText = () => {
    if (openType === "text") return;
    stopOpen();
    blockIndex += 1; openType = "text";
    if (wantStream) {
      sse(res, "content_block_start", {
        type: "content_block_start", index: blockIndex,
        content_block: { type: "text", text: "" },
      });
    }
  };
  const startTool = (idx, id, name) => {
    stopOpen();
    blockIndex += 1; openType = "tool_use";
    toolBlocks.set(idx, blockIndex);
    if (wantStream) {
      sse(res, "content_block_start", {
        type: "content_block_start", index: blockIndex,
        content_block: { type: "tool_use", id, name: name || "tool", input: {} },
      });
    }
  };

  if (wantStream) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    sse(res, "message_start", {
      type: "message_start",
      message: {
        id: msgId, type: "message", role: "assistant", model: modelName,
        content: [], stop_reason: null, stop_sequence: null,
        usage: { input_tokens: 0, output_tokens: 0 },
      },
    });
  }

  const opened = new Set();
  let sawDone = false;
  let thinkingOpen = false;

  try {
    for await (const data of sseLines(hub)) {
      if (!data || data === "[DONE]") { sawDone = true; continue; }
      let chunk;
      try { chunk = JSON.parse(data); } catch { continue; }

      for (const ev of applyChunk(acc, chunk)) {
        if (!wantStream) continue;
        if (ev.kind === "thinking") {
          if (!thinkingOpen) {
            if (openType === "text") stopOpen();
            blockIndex += 1; openType = "thinking"; thinkingOpen = true;
            sse(res, "content_block_start", {
              type: "content_block_start", index: blockIndex,
              content_block: { type: "thinking", thinking: "" },
            });
          }
          sse(res, "content_block_delta", {
            type: "content_block_delta", index: blockIndex,
            delta: { type: "thinking_delta", thinking: ev.text },
          });
        } else if (ev.kind === "text") {
          if (thinkingOpen) { stopOpen(); thinkingOpen = false; openType = null; }
          startText();
          sse(res, "content_block_delta", {
            type: "content_block_delta", index: blockIndex,
            delta: { type: "text_delta", text: ev.text },
          });
        } else if (ev.kind === "tool") {
          if (thinkingOpen) { stopOpen(); thinkingOpen = false; openType = null; }
          if (!opened.has(ev.index)) {
            opened.add(ev.index);
            startTool(ev.index, ev.id, ev.name);
          }
          if (ev.args) {
            sse(res, "content_block_delta", {
              type: "content_block_delta", index: toolBlocks.get(ev.index),
              delta: { type: "input_json_delta", partial_json: ev.args },
            });
          }
        }
      }
    }
  } catch (e) {
    log("ERR", "stream broke: " + e.message);
    if (!wantStream) return anthropicError(res, 502, "stream broke: " + e.message, "api_error");
  }

  const stopReason = STOP_REASON[acc.stop] || (acc.tools.size ? "tool_use" : "end_turn");
  const usage = {
    input_tokens: (acc.usage && acc.usage.prompt_tokens) || 0,
    output_tokens: (acc.usage && acc.usage.completion_tokens) || 0,
  };
  const cached = acc.usage && acc.usage.prompt_tokens_details && acc.usage.prompt_tokens_details.cached_tokens;
  if (cached) usage.cache_read_input_tokens = cached;

  if (wantStream) {
    stopOpen();
    sse(res, "message_delta", {
      type: "message_delta",
      delta: { stop_reason: stopReason, stop_sequence: null },
      usage,
    });
    sse(res, "message_stop", { type: "message_stop" });
    res.end();
    log("RES", JSON.stringify({
      stop: stopReason, out: usage.output_tokens, tools: acc.tools.size, done: sawDone,
    }));
    return;
  }

  const content = [];
  if (acc.text) content.push({ type: "text", text: acc.text });
  for (const entry of [...acc.tools.entries()].sort((a, b) => a[0] - b[0])) {
    const slot = entry[1];
    let input = {};
    if (slot.args) { try { input = JSON.parse(slot.args); } catch { input = { _raw: slot.args }; } }
    content.push({ type: "tool_use", id: slot.id, name: slot.name || "tool", input });
  }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({
    id: msgId, type: "message", role: "assistant", model: modelName,
    content, stop_reason: stopReason, stop_sequence: null, usage,
  }));
  log("RES", JSON.stringify({ stop: stopReason, out: usage.output_tokens, tools: acc.tools.size, stream: false }));
}

/* ------------------------------------------------------------------ */
/* HTTP 入口                                                          */
/* ------------------------------------------------------------------ */

const server = createServer((req, res) => {
  const url = new URL(req.url || "/", "http://" + (req.headers.host || "localhost"));
  const path = (url.pathname.replace(/\/+$/, "") || "/");

  if (req.method === "GET" && (path === "/health" || path === "/")) {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({
      ok: true, upstream: HUB_BASE_URL, model: DEFAULT_MODEL,
      hubKey: HUB_KEY ? "set" : "MISSING",
    }));
  }

  if (req.method !== "POST") {
    log("MISS", req.method + " " + path);
    res.writeHead(404, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: "no route " + path } }));
  }

  let raw = "";
  req.on("data", (c) => { raw += c; });
  req.on("error", (e) => log("ERR", "request stream: " + e.message));
  req.on("end", () => {
    if (path.endsWith("/count_tokens")) {
      let body = {};
      try { body = JSON.parse(raw || "{}"); } catch {}
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ input_tokens: estimateTokens(body) }));
    }
    if (path.endsWith("/v1/messages") || path === "/messages") {
      let body;
      try { body = JSON.parse(raw || "{}"); }
      catch (e) { return anthropicError(res, 400, "invalid JSON: " + e.message, "invalid_request_error"); }
      return void handleMessages(res, body, raw).catch((e) => {
        log("ERR", "unhandled: " + (e && e.stack ? e.stack : e));
        anthropicError(res, 500, (e && e.message) || String(e));
      });
    }
    log("MISS", req.method + " " + path + " body=" + raw.slice(0, 200));
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: "no route " + path } }));
  });
});

// ---- 进程级容错 ----
// 单个请求出错不该让整个翻译层死掉：claude 会立刻 ConnectionRefused，
// 而千问办公侧只会看到 API Error。这里兜住异常并记录，进程继续服务。
process.on('uncaughtException', (e) => {
  log('FATAL', 'uncaughtException: ' + (e && e.stack ? e.stack : e));
});
process.on('unhandledRejection', (e) => {
  log('FATAL', 'unhandledRejection: ' + (e && e.stack ? e.stack : e));
});
server.on('error', (e) => {
  if (e && e.code === 'EADDRINUSE') {
    // 已有实例在服务（开机自启与看门狗可能同时拉起）：直接退出，
    // 不要留一个不监听却还活着的僵尸进程。
    log('SKIP', 'port ' + PORT + ' already in use - another instance is serving, exiting');
    process.exit(0);
  }
  log('FATAL', 'server error: ' + (e && e.stack ? e.stack : e));
});

server.listen(PORT, HOST, () => {
  log("BOOT", "anthropic-hub-bridge http://" + HOST + ":" + PORT + " -> " + HUB_BASE_URL
    + " hubKey=" + (HUB_KEY ? "set" : "MISSING") + " model=" + DEFAULT_MODEL);
  console.log("");
  console.log("  Anthropic endpoint : http://" + HOST + ":" + PORT);
  console.log("  Upstream hub       : " + HUB_BASE_URL);
  console.log("  Hub key            : " + (HUB_KEY ? "loaded" : "MISSING - set HUB_API_KEY"));
  console.log("  Model              : " + DEFAULT_MODEL);
  console.log("");
  console.log("  Claude Code:");
  console.log("    ANTHROPIC_BASE_URL=http://" + HOST + ":" + PORT);
  console.log("    ANTHROPIC_AUTH_TOKEN=hub-local");
  console.log("");
});
