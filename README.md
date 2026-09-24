# claude-hub-bridge

让 **Claude Code** 走本机 **WorkBuddy Hub** 的协议翻译层。

## 为什么需要它

| 组件 | 说的协议 |
|---|---|
| Claude Code (`claude.exe`) | Anthropic Messages API —— `POST /v1/messages` |
| WorkBuddy Hub (`127.0.0.1:8788`) | OpenAI —— `POST /v1/chat/completions`、`POST /v1/responses` |

两边**不能直连**（实测 Hub 的 `/v1/messages` 返回 404；`claude.exe` 里 `chat/completions`、`OPENAI_BASE_URL` 出现次数为 0）。
所以你截图里那段 `OPENAI_BASE_URL` 配置对 Claude Code 无效 —— 那是给 Codex CLI 用的。

本层坐在中间做双向翻译，于是：

- Claude Code 的模型输出改由 Hub 的模型（deepseek / kimi / glm …）提供；
- **claude 不再连接 `api.anthropic.com`，地区限制自然失效**（不需要日本区/TUN）。

## 架构

```
claude.exe  --(Anthropic /v1/messages)-->  anthropic-hub-bridge :8820
                                                      |
                                                      |  (OpenAI /v1/chat/completions)
                                                      v
                                          WorkBuddy Hub  127.0.0.1:8788
                                                      |
                                                      v
                                              上游账号池（国内/国际）
```

## 文件

| 文件 | 说明 |
|---|---|
| `anthropic-hub-bridge.mjs` | 翻译层本体（531 行，零依赖，只用 `node:http` + 全局 `fetch`） |
| `probe-anthropic.mjs` | 自测脚本：用 Anthropic 原生协议打本层，验证 5 项能力 |
| `test-tools.mjs` | 探测 Hub 上游模型是否真的支持 function calling |
| `start-bridge.ps1` / `stop-bridge.ps1` / `restart-bridge.ps1` | 启动 / 停止 / 重启（带健康检查） |
| `logs/bridge.log` | 运行日志（每次请求的模型映射、token、工具数） |

## 用法

### 启动

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File restart-bridge.ps1
```

或双击 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\claude-hub-bridge.vbs`（已配置开机自启）。

健康检查：<http://127.0.0.1:8820/health>

### Claude Code 配置

已写入 `~/.claude/settings.json`（进程环境变量会被它覆盖，所以这是唯一权威配置）：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8820",
    "ANTHROPIC_AUTH_TOKEN": "hub-local",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_AUTOUPDATER": "1"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` 填什么都行（本层不校验），Hub 的真实 key 由翻译层自己从
`accounts/settings.json` 读。

### 换模型

默认上游模型是 `deepseek-v4.1-flash`。改法（优先级从高到低）：

1. `BRIDGE_MODEL=kimi-k2.7` 环境变量；
2. `BRIDGE_MODEL_MAP='{"claude-opus-4-8":"glm-5.3"}'` 按 claude 模型名精细映射；
3. `BRIDGE_SMALL_MODEL` 单独指定 haiku 档（claude 用它跑标题等小任务）。

已确认可用的 Hub 模型（13 个，全部支持工具调用与视觉）：

```
hy3  deepseek-v4.1-flash  deepseek-v4-pro  glm-5.1  glm-5.2  glm-5.3  glm-5.3-flash
glm-5v-turbo  kimi-k2.6  kimi-k2.7  kimi-k2.8-preview  kimi-k3-1  minimax-m3
```

## 已验证

`probe-anthropic.mjs` 五项全过：

| 用例 | 结果 |
|---|---|
| 纯文本（非流式） | 200，`BRIDGE-OK` |
| 纯文本（流式） | 200，事件序 `message_start → content_block_* → message_delta → message_stop` |
| 工具调用（流式） | `stop_reason: tool_use`，`input_json_delta` 拼出 `{"command": "ls ..."}` |
| 多轮工具回环 | 200，正确消费 `tool_result` |
| `count_tokens` | 200 |

`claude -p` 真实跑通：

- `claude -p "Reply with exactly: CLAUDE-HUB-OK"` → `CLAUDE-HUB-OK`
- `claude -p "Read probe-dir/hello.txt"` → `bridge works`（Read 工具生效）
- 多步 agent：写 `probe-dir/calc.py` + 执行 → 输出 `5050`，产物核验一致

## 排查

- **claude 报错/挂起** → 先看 <http://127.0.0.1:8820/health>；起不来执行 `restart-bridge.ps1`。
- **看请求日志** → `logs/bridge.log`，每行一条 `REQ`/`RES`，含模型映射与工具数。
- **`hubKey: MISSING`** → 翻译层读不到 Hub key，检查 `HUB_SETTINGS` 路径或用 `HUB_API_KEY` 指定。
- **想停用** → 删 `~/.claude/settings.json` 里的 `env` 块即可恢复 claude 默认行为。

## 边界

- 不绕过任何付费墙。Hub 的账号额度与计费走 Hub 自己的账本（`accounts/*.json`）。
- 本层只做协议翻译，不改 Hub、不改 Claude Code 二进制。
- `thinking` 块（上游 `reasoning_content`）会被翻译成 Anthropic 的 `thinking_delta` 透传给 claude。

---

## 存活保障（2026-09-24 追加）

翻译层**会**被外部杀掉（Codex 会话回收后台进程、手动清理 node 等），症状是
千问办公/Claude Code 报 `API Error: Unable to connect to API (ConnectionRefused)`。
`bridge.log` 会显示最后一次成功请求后就再无记录。

### 三层存活保障

| 机制 | 作用 |
|---|---|
| `watchdog.ps1` | 检查 8820 是否在监听；不在就拉起来。日志 `logs/watchdog.log` |
| 计划任务 `ClaudeHubBridgeWatchdog` | 每 1 分钟调用 watchdog（**Duration=P1D，每日重置，非 10 分钟**）|
| `Startup\claude-hub-bridge.vbs` | 登录时无窗口启动 |

计划任务要点（`schtasks /Create /SC MINUTE` 的坑）：
- 默认会写 `<Duration>PT10M</Duration>`，**10 分钟后就不再自动运行**；
- 正确做法是 `/SC DAILY /RI 1 /DU 24:00`，得到 `<Interval>PT1M</Interval>` + `<Duration>P1D</Duration>`；
- 另需关掉 `DisallowStartIfOnBatteries` / `StopIfGoingOnBatteries`（默认 true，电池模式下不跑）。

### 进程级容错

`anthropic-hub-bridge.mjs` 已注册：
- `uncaughtException` / `unhandledRejection` → 记 `FATAL` 日志，**进程继续服务**（单个请求出错不会拖垮整层）；
- `server.on('error')` 遇 `EADDRINUSE` → 记 `SKIP` 并 `exit(0)`，避免开机自启与看门狗同时拉起时留下不监听端口的僵尸进程。

### 手动操作

```powershell
# 看门狗立即跑一次
schtasks /Run /TN "ClaudeHubBridgeWatchdog"

# 查看自愈记录
Get-Content .\logs\watchdog.log -Tail 20

# 重启
powershell -NoProfile -ExecutionPolicy Bypass -File .\restart-bridge.ps1
```
---

## 换台机器怎么用（可移植性）

翻译层本身零依赖，但需要知道**去哪里找 Hub 的 API key**。按优先级解析：

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `HUB_SETTINGS` 环境变量 | 显式指定 settings.json 路径 |
| 2 | 本目录 `hub-settings.json` | 自己放一份，已被 `.gitignore` 排除 |
| 3 | `HUB_API_KEY` 环境变量 | 直接给 key，最省事 |
| 4 | 本机 WorkBuddy Hub 默认路径 | 仅本机有效 |

推荐在新机器上设置环境变量：

```powershell
# 方式 A：直接给 key
setx HUB_API_KEY "你的-key"

# 方式 B：指向 Hub 的 settings.json
setx HUB_SETTINGS "D:\path\to\workbuddy2api-hub\accounts\settings.json"

# 若 Hub 不在默认端口/地址
setx HUB_BASE_URL "http://127.0.0.1:8788"
```

脚本（`restart-bridge.ps1` / `watchdog.ps1` / `stop-bridge.ps1`）全部基于
`$PSScriptRoot` 定位自身，`node` 走 `Get-Command node` 探测，**不含任何机器专属路径**。

### 可选环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `BRIDGE_PORT` | `8820` | 本层监听端口 |
| `BRIDGE_HOST` | `127.0.0.1` | 监听地址 |
| `BRIDGE_MODEL` | `deepseek-v4.1-flash` | 上游模型 |
| `BRIDGE_SMALL_MODEL` | 同 `BRIDGE_MODEL` | haiku 档映射 |
| `BRIDGE_MODEL_MAP` | — | JSON，按 claude 模型名精细映射 |
| `BRIDGE_LOG_BODIES` | — | 设为 `1` 记录完整请求体（含对话内容，排查用） |
| `HUB_API_KEY` / `HUB_SETTINGS` / `HUB_BASE_URL` | — | 见上 |
| `QODER_BRIDGE_CLAUDE` | 自动探测 | 指定 claude.exe 路径（配合 clauded-qwenwork 用） |

## 配合 clauded-qwenwork 使用

本层也是[千问办公换芯 Claude Code](https://github.com/ry76642230-cmd/clauded-qwenwork) 的下游依赖：

```
千问办公 → bridge-shim.mjs → claude.exe → 本层(8820) → Hub(8788)
```

依赖链上任一环挂掉，千问办公都会报 `API Error: Unable to connect to API (ConnectionRefused)` 或类似错误。
排查顺序：先看 8820，再看 8788（Docker `wb-proxy`），最后看 `clauded-qwenwork\src\logs`。