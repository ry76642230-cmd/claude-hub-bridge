// test-tools.mjs — 验证 Hub 上游模型是否真的支持 function calling（Claude Code 的命门）
import fs from "node:fs";

// Hub 凭据解析顺序：HUB_KEY 环境变量 → hub-settings.json（本目录）→ 本机默认位置
function resolveKey() {
  if (process.env.HUB_KEY) return process.env.HUB_KEY.trim();
  const local = new URL("./hub-settings.json", import.meta.url);
  try {
    const cfg = JSON.parse(fs.readFileSync(local, "utf8"));
    const pick = (cfg.api_keys || []).find((x) => x && x.key);
    if (pick) return String(pick.key).trim();
  } catch {}
  try {
    const def = process.env.HUB_SETTINGS
      || [process.env.USERPROFILE, ".qwenworkcn", "workspace", "mu55844kqqe7tm63",
          "workbuddy2api-hub", "accounts", "settings.json"].join("\\");
    const cfg = JSON.parse(fs.readFileSync(def, "utf8"));
    const pick = (cfg.api_keys || []).find((x) => x && x.key);
    if (pick) return String(pick.key).trim();
  } catch {}
  return "";
}
const KEY = resolveKey();
const HUB = (process.env.HUB_BASE_URL || "http://127.0.0.1:8788").replace(/\/+$/, "");

const models = process.argv.slice(2);
if (models.length === 0) { console.error("usage: node test-tools.mjs <model> [...]"); process.exit(1); }

const TOOLS = [{
  type: "function",
  function: {
    name: "Bash",
    description: "Run a shell command on the local machine.",
    parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
  },
}];

async function probe(model) {
  const body = {
    model, max_tokens: 256,
    messages: [{ role: "user", content: "List the files in C:\\Windows\\System32. You must call the Bash tool." }],
    tools: TOOLS, tool_choice: "auto",
  };
  const t0 = Date.now();
  let r;
  try {
    r = await fetch(`${HUB}/v1/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${KEY}` },
      body: JSON.stringify(body),
    });
  } catch (e) { console.log(`${model.padEnd(22)} FETCH-ERR ${e.message}`); return; }
  const text = await r.text();
  const ms = Date.now() - t0;
  if (!r.ok) { console.log(`${model.padEnd(22)} HTTP ${r.status} ${text.slice(0, 150)}`); return; }
  let j; try { j = JSON.parse(text); } catch { console.log(`${model.padEnd(22)} BAD-JSON ${text.slice(0, 150)}`); return; }
  const msg = j.choices?.[0]?.message ?? {};
  const calls = msg.tool_calls ?? [];
  console.log(`${model.padEnd(22)} ${ms}ms tool_calls=${calls.length} finish=${j.choices?.[0]?.finish_reason}`);
  if (calls.length) for (const c of calls) console.log(`   -> ${c.function?.name} ${String(c.function?.arguments ?? "").slice(0, 90)}`);
  else console.log(`   text: ${String(msg.content ?? "").slice(0, 130)}`);
}

for (const m of models) await probe(m);
