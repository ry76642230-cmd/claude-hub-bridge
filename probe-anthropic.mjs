// probe-anthropic.mjs — 用 Anthropic 原生协议打本地翻译层，验证双向翻译
const BASE = process.argv[2] || "http://127.0.0.1:8820";
const H = { "Content-Type": "application/json", "x-api-key": "hub-local", "anthropic-version": "2023-06-01" };

async function call(label, body, stream) {
  const t0 = Date.now();
  const r = await fetch(BASE + "/v1/messages", { method: "POST", headers: H, body: JSON.stringify(body) });
  console.log(`\n===== ${label} ===== status=${r.status} (${Date.now() - t0}ms)`);
  if (stream) {
    const txt = await r.text();
    const lines = txt.split("\n").filter((l) => l.startsWith("event:") || l.startsWith("data:"));
    const events = lines.filter((l) => l.startsWith("event:")).map((l) => l.slice(6).trim());
    console.log("events:", events.join(" "));
    let text = "", tool = null, stop = null, usage = null;
    for (const l of lines) {
      if (!l.startsWith("data:")) continue;
      let j; try { j = JSON.parse(l.slice(5).trim()); } catch { continue; }
      if (j.type === "content_block_delta" && j.delta?.type === "text_delta") text += j.delta.text;
      if (j.type === "content_block_delta" && j.delta?.type === "input_json_delta") { tool = tool || { args: "" }; tool.args += j.delta.partial_json; }
      if (j.type === "content_block_start" && j.content_block?.type === "tool_use") tool = { name: j.content_block.name, id: j.content_block.id, args: "" };
      if (j.type === "message_delta") { stop = j.delta?.stop_reason; usage = j.usage; }
    }
    console.log("text:", JSON.stringify(text.slice(0, 200)));
    if (tool) console.log("tool_use:", tool.name, JSON.stringify(String(tool.args).slice(0, 160)));
    console.log("stop_reason:", stop, "usage:", JSON.stringify(usage));
  } else {
    const j = await r.json();
    console.log(JSON.stringify(j).slice(0, 600));
  }
}

const TOOLS = [{
  name: "Bash",
  description: "Run a shell command.",
  input_schema: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
}];

await call("1. plain text (non-stream)", {
  model: "claude-sonnet-4-5", max_tokens: 64,
  messages: [{ role: "user", content: "Reply with exactly: BRIDGE-OK" }],
});

await call("2. plain text (stream)", {
  model: "claude-sonnet-4-5", max_tokens: 64, stream: true,
  messages: [{ role: "user", content: "Reply with exactly: STREAM-OK" }],
}, true);

await call("3. tool call (stream)", {
  model: "claude-sonnet-4-5", max_tokens: 256, stream: true,
  tools: TOOLS,
  messages: [{ role: "user", content: "List files in C:\\Windows\\System32. You must call the Bash tool." }],
}, true);

await call("4. tool round-trip (multi-turn)", {
  model: "claude-sonnet-4-5", max_tokens: 256,
  tools: TOOLS,
  messages: [
    { role: "user", content: "List files in C:\\Windows." },
    { role: "assistant", content: [{ type: "tool_use", id: "toolu_test1", name: "Bash", input: { command: "dir C:\\Windows" } }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_test1", content: "explorer.exe\nnotepad.exe\nsystem32" }] },
  ],
});

const ct = await fetch(BASE + "/v1/messages/count_tokens", {
  method: "POST", headers: H,
  body: JSON.stringify({ model: "claude-sonnet-4-5", messages: [{ role: "user", content: "hello world" }] }),
});
console.log("\n5. count_tokens:", ct.status, (await ct.text()).slice(0, 120));
