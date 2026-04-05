# 小螃蟹 (OpenCrab) 项目作战手册

> **给后续 Claude 会话**：先读完本文件，再动手。不要跳过任何一节。

---

## 0. 当前里程碑状态（v0.1 · 2026-04-05）

**Milestone 1 已完成**：最小可运行闭环已跑通。

| 项目 | 状态 |
|------|------|
| Flutter Workbench 主链路（chat 视图、自动连接、Settings） | ✅ 可用 |
| app-server WebSocket 协议（initialize / thread / turn / approval） | ✅ 已打通 |
| config/batchWrite provider 注入（apiKey + baseURL → runtime 即时生效） | ✅ 已验证 |
| 三个 smoke 脚本（baseline / auth / config） | ✅ 已建立 |
| 真实联调（千问，支持 OpenAI Responses API） | ✅ 联调通过 |
| 前端结构化日志（debugPrint，标签化，终端可见） | ✅ 已上线 |
| Dart/Flutter 测试骨架 | ✅ 最小骨架已建 |

**当前可用 provider**：阿里云千问（`qwen` 系列）——支持 OpenAI Responses API 路径（`/v1/responses`），经真实联调验证可用。

**已知不兼容**：SiliconFlow 及仅支持 Chat Completions（`/v1/chat/completions`）的 provider 目前无法使用。原因是 codex-rs `WireApi` 枚举当前只有 `responses` 一个合法值，`chat_completions` 会被 config 写入阶段拒绝。

---

## 1. 项目愿景

**小螃蟹**（OpenCrab）不是一个 Codex 的简单壳子，而是一个**可控、可审查、可扩展的本地 Agent Workbench**。

- **名称来源**：相对于 OpenClaw（大龙虾/爪子）的隐喻，小螃蟹做的是自己的本地 Agent 工作台方向，更轻、更灵活、更可控。
- **当前阶段**：借用 Codex app-server 作为 runtime 接入基座，Flutter Workbench 作为 UI 外壳，快速建立最小可运行闭环。
- **长期方向**（runtime + UI 只是基座，不是终局）：
  - **任务执行可视化**：让用户看清 Agent 每一步在做什么
  - **审批与安全**：命令执行、文件变更的可审查审批流
  - **Diff 审查**：每次 turn 产生的代码变更清晰可见、可接受/拒绝
  - **Skills / Workflows**：可组合的任务流程
  - **Provider 解耦**：不绑定 OpenAI，支持 DeepSeek、本地模型、拼车 API 等
  - **MCP 扩展**：原生支持 Model Context Protocol 工具链

---

## 2. 当前产品定位

| 组件 | 定位 | 优先级 |
|------|------|--------|
| `apps/workbench/` | **主线产品**，Flutter UI，用于真实使用 | ★★★ 最高 |
| `codex-rs/app-server` | **当前 runtime 接入基座**，WebSocket 后端 | ★★★ 依赖 |
| `little-crab-ui/` | **调试/开发工具**，不是当前主产品主线 | ★☆☆ 辅助 |

**关键判断**：`little-crab-ui` 是开发调试辅助，不要把它当主产品推进。所有主线功能都在 `apps/workbench`。

---

## 3. 当前架构

```
Flutter Workbench (apps/workbench)
        │
        │  WebSocket (JSON-RPC 2.0)
        │  ws://127.0.0.1:60000
        ▼
Codex app-server (codex-rs/app-server)
        │
        │  内部调用
        ▼
codex_core (LLM 调用 / 本地执行 / MCP)
```

**协议要点**（来自 app-server README）：
- WebSocket 传输目前标注为 **experimental / unsupported**，但可用于本地开发
- 连接后必须先发 `initialize` 请求 + `initialized` 通知，才能发其他请求
- 核心原语：**Thread**（会话）→ **Turn**（一轮对话）→ **Item**（执行步骤）
- 生成类型定义：`codex app-server generate-ts --out DIR`

---

## 4. 当前已实现状态

### Workbench 已接线的能力

| 能力 | 实现状态 | 关键位置 |
|------|----------|----------|
| Setup 页面 | ✅ 完整 | `lib/ui/setup_page.dart` |
| 自动连接（启动后自动 connect，Settings 保存后重连） | ✅ | `lib/main.dart` |
| WebSocket 连接 | ✅ 可用 | `lib/services/app_server_service.dart` |
| Chat 主视图（气泡、流式 streaming bubble） | ✅ | `lib/ui/chat_view.dart` |
| 连接状态栏（status dot + endpoint，无手动 Connect 按钮） | ✅ | `lib/ui/connection_panel.dart` |
| thread/start | ✅ | `workbench_controller.dart` |
| turn/start | ✅ 含 model / approvalPolicy | `workbench_controller.dart` |
| turn/interrupt | ✅ | `workbench_controller.dart` |
| 审批请求处理 | ✅ commandExecution + fileChange | `workbench_controller.dart` |
| agentMessage 流式 | ✅ delta 拼接 + streamingText getter | `workbench_controller.dart` |
| turn/diff/updated | ✅ 保存 lastTurnDiff，可折叠 diff panel | `workbench_page.dart` |
| provider 注入（config/batchWrite，apiKey + baseURL） | ✅ 联调可用 | `workbench_controller.dart` |
| 结构化前端日志（标签化，输出到 flutter run 终端） | ✅ | `workbench_controller.dart` |

### Setup 页面可配置的字段

- **Display Name**：用户显示名
- **Endpoint URL**：默认 `ws://127.0.0.1:60000`
- **Model**（可选）：若填写，turn/start 时会带上 `model` 参数
- **Auth Method**：ChatGPT / API Key（切换后显示额外字段）
- **Approval Policy**：`unlessTrusted`（默认）/ `always` / `never`
- **API Key**（可选，仅 API Key 模式）
- **LLM Provider Base URL**（可选，仅 API Key 模式）

### ⚠️ 已知接线缺口与边界

- **Workbench 不能自动拉起 app-server**，必须手动先启动后端
- **仅支持 Chat Completions 的 provider 不可用**：codex-rs `WireApi` 枚举只有 `responses`，SiliconFlow 等国内 provider 因此无法接入（见第 0 节）
- **provider 切换后的 cleanup 不完整**：重连后旧 `model_providers` 条目仍留在 config.toml，需手动清理
- **per-turn model override**：turn/start 传 `model` 参数，但 runtime 是否真正使用取决于 codex_core 内部逻辑，未完全验证

---

## 5. 已知限制与后续方向

### 当前未完成的高优先级项

- [ ] **Workbench 不能自动启动 app-server**：每次开发都需要手动先启 backend
- [ ] **provider 扩展（支持 Chat Completions）**：需修改 codex-rs，给 `WireApi` 加 `chat_completions` 变体；不要在此之前伪造兼容
- [ ] **provider 切换后的 cleanup**：旧 `model_providers.*` 条目不会自动从 config.toml 删除
- [ ] **审批 UI 完整链路**：当前 Approval Panel 可用，但 diff 展示、fileChange 细节还不完整
- [ ] **真实任务闭环验证**：目前只验证了简单对话，复杂 agent 任务（文件修改、命令执行）需专项测试

### 后续方向优先级

1. **稳定性与真实任务闭环**（最高优先）：跑通含命令执行、文件变更的完整 agent 任务
2. **审批与 diff 完整链路**：让用户能清晰看到并接受/拒绝每步变更
3. **自动拉起 app-server**：消除手动启动步骤
4. **provider 扩展**：支持 Chat Completions 路径，解锁 SiliconFlow 等国内 provider
5. **MCP / Skills**：中期目标，不是当前第一优先

---

## 6. 本地启动 Runbook

### 环境前提

```bash
rustup show          # 确认 Rust 工具链已安装
cargo --version
flutter --version
flutter doctor       # 确认 Flutter 环境正常
```

### 步骤 1：启动 Backend（先启动）

```bash
cd codex-rs
cargo run -p codex-app-server --bin codex-app-server -- --listen ws://127.0.0.1:60000
```

等待日志出现类似：
```
listening on ws://127.0.0.1:60000
```

调试模式（更详细日志）：
```bash
RUST_LOG=debug cargo run -p codex-app-server --bin codex-app-server -- --listen ws://127.0.0.1:60000
```

健康检查（另开终端）：
```bash
curl http://127.0.0.1:60000/readyz   # 应返回 200 OK
```

### 步骤 2：启动 Frontend（后启动）

```bash
cd apps/workbench
flutter run
```

首次运行进入 Setup 页面，填写：
- Display Name（随意）
- Endpoint URL：`ws://127.0.0.1:60000`（与 backend 一致）
- Auth Method：选 ChatGPT（无需 API Key）
- Approval Policy：保持默认 `Unless Trusted`
- 点击 Save

### 步骤 3（可选）：Smoke Tests

**基础 smoke（无需认证，验证 WebSocket 握手和 thread/turn 流程）：**
```bash
python3 tools/smoke/app_server_smoke.py
```

**Auth smoke（JSON 配置方式，验证 account/login/start + thread/start）：**
```bash
# 首次：从模板复制配置文件，填入真实 apiKey
cp tools/smoke/app_server_auth_config.json.example tools/smoke/app_server_auth_config.json
# 编辑 app_server_auth_config.json，填入 apiKey

python3 tools/smoke/app_server_auth_smoke.py
```

**Config smoke（验证 provider / baseURL 配置是否真正进入 runtime）：**
```bash
# 需要 app_server_auth_config.json 中有真实的 providerBaseUrl + apiKey
python3 tools/smoke/app_server_config_smoke.py
```

说明：
- JSON 配置文件是 smoke test 的唯一输入，不使用环境变量
- `apiKey` 通过 `account/login/start` RPC 传入，不硬编码在脚本中

**三个 smoke 脚本对比：**

| 脚本 | 验证内容 | 需要真实配置 |
|------|----------|-------------|
| `app_server_smoke.py` | WebSocket 握手 + thread/turn 流程 | 否（匿名可跑） |
| `app_server_auth_smoke.py` | account/login/start (apiKey auth) | 需要真实 apiKey |
| `app_server_config_smoke.py` | config/batchWrite 写入 provider + runtime 是否生效 | 需要真实 providerBaseUrl + apiKey |

**Config smoke 工作原理：**
1. `config/read` — 读取当前有效配置（快照）
2. `config/batchWrite` — 写入 `model_providers.smoke_siliconflow`（base_url + experimental_bearer_token）+ 设置 `model_provider`，带 `reloadUserConfig: true`
3. `config/read` — 读回验证写入持久化
4. `thread/start` — 检查 `thread.modelProvider` 字段，确认 runtime 已切换到新 provider
5. 恢复 `model_provider` 到原始值（null = 移除 key，恢复默认 openai provider）

**已验证结论（2026-04-05）：**
- `config/batchWrite` + `reloadUserConfig: true` **无需重启 app-server 即可生效**
- 新 `thread/start` 会立即使用写入的 provider
- 真实 config key 名：`model_providers.<id>`（点分隔路径）和 `model_provider`
- `experimental_bearer_token` 字段用作 `Authorization: Bearer <token>` 头
- Config smoke **只有在 app_server_auth_config.json 中有真实 providerBaseUrl 时才有意义**

### 连接失败排查

| 现象 | 排查点 |
|------|--------|
| "Connection refused" | app-server 未启动，或端口不同 |
| 连接后无响应 | 检查是否完成了 initialize 握手 |
| "Empty connection panel" | Setup 页面 Endpoint URL 配置错误 |
| 端口占用 | `lsof -i :60000`，结束冲突进程 |

---

## 7. 关键文件速查

| 路径 | 用途 |
|------|------|
| `apps/workbench/lib/main.dart` | 应用入口，自动连接逻辑在此 |
| `apps/workbench/lib/ui/setup_page.dart` | 首次配置页面 |
| `apps/workbench/lib/ui/workbench_page.dart` | 主工作台页面（chat 布局） |
| `apps/workbench/lib/ui/chat_view.dart` | 聊天气泡视图 |
| `apps/workbench/lib/ui/connection_panel.dart` | 连接状态栏（只读，无按钮） |
| `apps/workbench/lib/ui/approval_panel.dart` | 审批面板 |
| `apps/workbench/lib/controllers/workbench_controller.dart` | 核心状态管理，thread/turn/approval/log 全在此 |
| `apps/workbench/lib/models/chat_message.dart` | 聊天消息数据模型 |
| `apps/workbench/lib/models/runtime_config.dart` | 配置数据模型 |
| `apps/workbench/lib/services/app_server_service.dart` | WebSocket 连接与 JSON-RPC 实现 |
| `codex-rs/app-server/src/main.rs` | app-server 启动入口 |
| `codex-rs/app-server/README.md` | app-server 完整协议文档（必读） |
| `tools/smoke/app_server_smoke.py` | 基础 smoke（无需认证） |
| `tools/smoke/app_server_auth_smoke.py` | Auth smoke |
| `tools/smoke/app_server_config_smoke.py` | Config/provider smoke（含 turn/start 验证） |
| `little-crab-ui/` | 调试工具（非主线） |

---

## 8. 开发原则

> 这些规则是给后续每一个 Claude 会话的。请严格遵守。

### 动手前

1. **先读 CLAUDE.md，再动手**——不要跳过，不要只看前几节
2. **改动前说明改哪些文件**——告知用户影响范围
3. **小步修改**——不做无关重构，不顺手"清理"周围代码

### 边界控制

4. **优先推进 `apps/workbench` 主线**，不要把 `little-crab-ui` 当主产品推进
5. **除非明确必要，不要修改 `codex-rs` 深层核心**——除非是 provider/config 支持缺口
6. **不要伪造 provider 登录/认证**——认证逻辑要真实可用，不要做假接线
7. **`apiKey` / `providerBaseUrl` 在确认协议支持前不要接入 runtime**——当前仅本地保存是已知限制，不是 bug

### 改动后

8. **说明影响范围和遗留 TODO**——让下一个 Claude 知道还有什么没做完
9. **需要真实联调验证**——静态分析看起来正确不等于运行时正确

---

## 9. 技术方向结论

- **当前主线继续押 Flutter Workbench**：这是产品外壳，不换
- **little-crab-ui 作为调试工具保留**：有价值但不是主线
- **后续可以考虑统一协议层/类型层**（如 `little-crab-types/`），但这不是当前第一优先级
- **当前优先级高于"共享协议层"的**：Workbench 主链路的完善（审批 UI、diff 展示、真实联调）
- **provider 解耦是中期目标**：先跑通 OpenAI 协议主链路，再考虑多 Provider 抽象

---

**最后更新**：2026-04-05（Milestone 1 收尾：chat 主视图、自动连接、结构化日志、smoke 验证、千问联调通过）
