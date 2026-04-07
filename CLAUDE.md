# 小螃蟹 (OpenCrab) 项目作战手册

> **给后续 Claude 会话**：先读完本文件，再动手。不要跳过任何一节。

---

## 0. 当前里程碑状态（v0.2 · 2026-04-07）

**Milestone 1 已完成**：最小可运行闭环已跑通。
**Milestone 2 进行中**：UI 架构升级——Blocks 机制 + 工具调用可视化。

| 项目 | 状态 |
|------|------|
| Flutter Workbench 主链路（chat 视图、自动连接、Settings） | ✅ 可用 |
| app-server WebSocket 协议（initialize / thread / turn / approval） | ✅ 已打通 |
| config/batchWrite provider 注入（apiKey + baseURL → runtime 即时生效） | ✅ 已验证 |
| 三个 smoke 脚本（baseline / auth / config） | ✅ 已建立 |
| 真实联调（千问，支持 OpenAI Responses API） | ✅ 联调通过 |
| 前端结构化日志（debugPrint，标签化，终端可见） | ✅ 已上线 |
| CodexMonitor 参考库引入（reference/CodexMonitor submodule） | ✅ 已引入 |
| Blocks 机制（TextBlock / ToolCallBlock 数据模型） | 🚧 进行中 |
| 工具调用折叠 UI（ExpansionTile 胶囊）| 🚧 进行中 |

**当前可用 provider**：阿里云千问（`qwen` 系列）——支持 OpenAI Responses API 路径（`/v1/responses`），经真实联调验证可用。

**已知不兼容**：SiliconFlow 及仅支持 Chat Completions（`/v1/chat/completions`）的 provider 目前无法使用。原因是 codex-rs `WireApi` 枚举当前只有 `responses` 一个合法值，`chat_completions` 会被 config 写入阶段拒绝。

---

## 1. 项目愿景

**小螃蟹**（OpenCrab）是一个**基于 Flutter 的本地 Agent 工作台（Workbench）**，底层 Runtime 坚决使用 `codex-rs/app-server`。

**终极愿景：私人数字公司。**  
用户一键拉起具备不同技能边界的 Agent"员工"，处理本地文件、执行任务、审批变更——整个过程完全透明可控，运行在本地，不依赖云端。

**长期方向**：
- **任务执行可视化**：让用户看清 Agent 每一步在做什么（工具调用、文件变更、命令执行）
- **审批与安全**：命令执行、文件变更的可审查审批流，高危操作独立弹出面板
- **Diff 审查**：每次 turn 产生的代码变更清晰可见、可接受/拒绝
- **Skills / Workflows**：可组合的任务流程
- **Provider 解耦**：不绑定 OpenAI，支持 DeepSeek、本地模型、拼车 API 等
- **MCP 扩展**：原生支持 Model Context Protocol 工具链

---

## 2. 组件定位

| 组件 | 定位 | 优先级 |
|------|------|--------|
| `apps/workbench/` | **主线产品**，Flutter UI，用于真实使用 | ★★★ 最高 |
| `codex-rs/app-server` | **唯一 Runtime 基座**，WebSocket 后端，不可替换 | ★★★ 依赖 |
| `reference/CodexMonitor` | **标准参考实现**（React/Tauri），遇到 API 疑问必查 | ★★★ 参考 |
| `little-crab-ui/` | 调试/开发工具，非主线 | ★☆☆ 辅助 |

**关键判断**：
- `little-crab-ui` 是开发调试辅助，不要把它当主产品推进。所有主线功能都在 `apps/workbench`。
- `codex-rs/app-server` 是唯一 Runtime，不考虑替换。
- `reference/CodexMonitor` 是参考指南针，不是要复刻的产品。

---

## 3. 核心参考库：CodexMonitor

**仓库位置**：`reference/CodexMonitor`（git submodule，来自 `Dimillian/CodexMonitor`）

### 使用法则（强制）

> **遇到不懂的 Codex API 交互、不知道传什么参数、不确定协议细节时：禁止靠猜测或幻觉！必须先查 `reference/CodexMonitor` 的源码是怎么处理的，再用 Flutter/Dart 降维复刻。**

CodexMonitor 是用 React/TypeScript + Tauri 写的，但它和我们用的是同一套 `codex-rs/app-server` WebSocket 协议。它是目前最权威、最及时的协议参考实现。

**典型查阅场景**：
- 不确定某个 RPC 方法的参数结构（如 `turn/start` 的完整 payload）
- 不清楚某个事件（如 `agentMessage` delta）的数据格式
- 不知道 `initialize` 握手后应该发什么
- 不确定 approval 的响应格式

**查阅方法**：
```bash
# 搜索关键词
grep -r "turn/start" reference/CodexMonitor/src/
grep -r "agentMessage" reference/CodexMonitor/src/
grep -r "approval" reference/CodexMonitor/src/
```

---

## 4. 架构

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

## 5. UI 设计原则（1.0 阶段）

这是本阶段最重要的架构约束，所有 UI 相关改动必须遵守。

### 原则一：数据与 UI 分离

**禁止**将 API 吐出的 JSON 和工具调用栈直接拼接成一个巨大的纯文本 String 塞进聊天气泡。这会导致乱码、不可控的格式混乱，以及无法做可视化。

### 原则二：时间线切片（Blocks 机制）

每条 ChatMessage 必须被拆分为独立的 Block 序列：

```
ChatMessage
  └─ blocks: List<MessageBlock>
       ├─ TextBlock        ← 普通对话文本（用户可见的回答）
       └─ ToolCallBlock    ← 工具调用过程（bash、file_read 等）
            ├─ toolName: String
            ├─ input: Map
            ├─ output: String?
            └─ status: loading | success | error
```

**TextBlock** 负责渲染 Markdown 对话内容。  
**ToolCallBlock** 负责渲染工具调用过程，默认折叠，仅展示状态标志。

### 原则三：工具调用折叠可视化

所有后台命令（`bash`、`file_read`、`file_write` 等）的执行过程**必须折叠隐藏**在 UI 中。

- 使用 `ExpansionTile` 或小胶囊组件实现折叠
- 收起状态只显示：工具图标 + 工具名 + 状态（Loading/Success/Error）
- 展开后才显示输入参数和执行输出
- **目标：保持聊天流极其干净，用户不会被命令输出淹没**

### 原则四：高危操作解耦

**Diff 展示和 Approval 审批，绝不塞在聊天气泡里。**

- Approval 请求触发时，弹出独立的 Approval Panel（底部抽屉或全屏 Modal）
- Diff 展示使用独立的 Diff Viewer 面板
- 聊天气泡中仅显示一个简洁的"等待审批中..."占位提示

---

## 6. 当前已实现状态

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

### Setup 页面可配置字段

- **Display Name**：用户显示名
- **Endpoint URL**：默认 `ws://127.0.0.1:60000`
- **Model**（可选）：若填写，turn/start 时会带上 `model` 参数
- **Auth Method**：ChatGPT / API Key（切换后显示额外字段）
- **Approval Policy**：`unlessTrusted`（默认）/ `always` / `never`
- **API Key**（可选，仅 API Key 模式）
- **LLM Provider Base URL**（可选，仅 API Key 模式）

### 已知接线缺口

- **Workbench 不能自动拉起 app-server**，必须手动先启动后端
- **仅支持 Chat Completions 的 provider 不可用**：codex-rs `WireApi` 枚举只有 `responses`，SiliconFlow 等国内 provider 因此无法接入
- **provider 切换后的 cleanup 不完整**：重连后旧 `model_providers` 条目仍留在 config.toml，需手动清理
- **Blocks 机制尚未完全落地**：当前 agentMessage 仍以纯文本拼接，待 Milestone 2 完成

---

## 7. 后续优先级

1. **Blocks 机制落地**（最高优先）：ChatMessage 拆分为 TextBlock + ToolCallBlock，工具调用折叠展示
2. **真实任务闭环验证**：跑通含命令执行、文件变更的完整 agent 任务，验证工具调用可视化效果
3. **Approval + Diff 完整链路**：弹出独立面板，让用户能清晰看到并接受/拒绝每步变更
4. **自动拉起 app-server**：消除手动启动步骤
5. **provider 扩展**：支持 Chat Completions 路径，解锁 SiliconFlow 等国内 provider
6. **MCP / Skills**：中期目标，不是当前第一优先

---

## 8. 本地启动 Runbook

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

等待日志出现：
```
listening on ws://127.0.0.1:60000
```

调试模式：
```bash
RUST_LOG=debug cargo run -p codex-app-server --bin codex-app-server -- --listen ws://127.0.0.1:60000
```

健康检查：
```bash
curl http://127.0.0.1:60000/readyz   # 应返回 200 OK
```

### 步骤 2：启动 Frontend

```bash
cd apps/workbench
flutter run
```

首次运行进入 Setup 页面，填写：
- Endpoint URL：`ws://127.0.0.1:60000`
- Auth Method：选 ChatGPT（无需 API Key）
- Approval Policy：保持默认 `Unless Trusted`
- 点击 Save

### 步骤 3（可选）：Smoke Tests

| 脚本 | 验证内容 | 需要真实配置 |
|------|----------|-------------|
| `app_server_smoke.py` | WebSocket 握手 + thread/turn 流程 | 否（匿名可跑） |
| `app_server_auth_smoke.py` | account/login/start (apiKey auth) | 需要真实 apiKey |
| `app_server_config_smoke.py` | config/batchWrite 写入 provider + runtime 是否生效 | 需要真实 providerBaseUrl + apiKey |

```bash
python3 tools/smoke/app_server_smoke.py

# Auth/Config smoke 首次配置：
cp tools/smoke/app_server_auth_config.json.example tools/smoke/app_server_auth_config.json
# 编辑 app_server_auth_config.json，填入 apiKey / providerBaseUrl
python3 tools/smoke/app_server_auth_smoke.py
python3 tools/smoke/app_server_config_smoke.py
```

**已验证结论（2026-04-05）**：
- `config/batchWrite` + `reloadUserConfig: true` 无需重启 app-server 即可生效
- 新 `thread/start` 会立即使用写入的 provider
- config key 名：`model_providers.<id>`（点分隔路径）和 `model_provider`
- `experimental_bearer_token` 字段用作 `Authorization: Bearer <token>` 头

### 连接失败排查

| 现象 | 排查点 |
|------|--------|
| "Connection refused" | app-server 未启动，或端口不同 |
| 连接后无响应 | 检查是否完成了 initialize 握手 |
| "Empty connection panel" | Setup 页面 Endpoint URL 配置错误 |
| 端口占用 | `lsof -i :60000`，结束冲突进程 |

---

## 9. 关键文件速查

| 路径 | 用途 |
|------|------|
| `apps/workbench/lib/main.dart` | 应用入口，自动连接逻辑在此 |
| `apps/workbench/lib/ui/setup_page.dart` | 首次配置页面 |
| `apps/workbench/lib/ui/workbench_page.dart` | 主工作台页面（chat 布局） |
| `apps/workbench/lib/ui/chat_view.dart` | 聊天气泡视图 |
| `apps/workbench/lib/ui/connection_panel.dart` | 连接状态栏（只读，无按钮） |
| `apps/workbench/lib/ui/approval_panel.dart` | 审批面板 |
| `apps/workbench/lib/controllers/workbench_controller.dart` | 核心状态管理，thread/turn/approval/log 全在此 |
| `apps/workbench/lib/models/chat_message.dart` | 聊天消息数据模型（待扩展 Blocks） |
| `apps/workbench/lib/models/runtime_config.dart` | 配置数据模型 |
| `apps/workbench/lib/services/app_server_service.dart` | WebSocket 连接与 JSON-RPC 实现 |
| `codex-rs/app-server/src/main.rs` | app-server 启动入口 |
| `codex-rs/app-server/README.md` | app-server 完整协议文档（必读） |
| `reference/CodexMonitor/` | 标准参考实现（React/Tauri），协议疑问必查 |
| `tools/smoke/app_server_smoke.py` | 基础 smoke（无需认证） |
| `tools/smoke/app_server_auth_smoke.py` | Auth smoke |
| `tools/smoke/app_server_config_smoke.py` | Config/provider smoke（含 turn/start 验证） |
| `little-crab-ui/` | 调试工具（非主线） |

---

## 10. 开发原则

> 这些规则是给后续每一个 Claude 会话的。请严格遵守。

### 动手前

1. **先读 CLAUDE.md，再动手**——不要跳过，不要只看前几节
2. **改动前说明改哪些文件**——告知用户影响范围
3. **小步修改**——不做无关重构，不顺手"清理"周围代码
4. **遇到 API 疑问，先查 `reference/CodexMonitor`**——禁止靠猜测或幻觉填参数

### 边界控制

5. **优先推进 `apps/workbench` 主线**，不要把 `little-crab-ui` 当主产品推进
6. **除非明确必要，不要修改 `codex-rs` 深层核心**——除非是 provider/config 支持缺口
7. **不要伪造 provider 登录/认证**——认证逻辑要真实可用，不要做假接线
8. **遵守 Blocks 机制**——不要把工具调用输出和对话文本混成一个字符串

### 改动后

9. **说明影响范围和遗留 TODO**——让下一个 Claude 知道还有什么没做完
10. **需要真实联调验证**——静态分析看起来正确不等于运行时正确

---

**最后更新**：2026-04-07（v0.2：战略调整——引入 CodexMonitor 参考库，确立 Blocks 机制和工具调用可视化原则，明确"私人数字公司"终极愿景）
