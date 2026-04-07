# CodexMonitor 协议字典

> **用途**：本文件是从 `reference/CodexMonitor`（React/Tauri 参考实现）逆向提炼的协议字典，供 Flutter/Dart 端参照实现。  
> **权威来源**：`reference/CodexMonitor/src/`，同一套 `codex-rs/app-server` WebSocket 协议。  
> **生成日期**：2026-04-07（基于 CodexMonitor commit 分析）

---

## 目录

1. [连接与会话初始化](#1-连接与会话初始化)
2. [消息数据结构：ConversationItem Blocks](#2-消息数据结构conversationitem-blocks)
3. [事件流解析：所有 Server → Client 事件](#3-事件流解析所有-server--client-事件)
4. [状态机：Tool 调用的生命周期](#4-状态机tool-调用的生命周期)
5. [UI 渲染策略](#5-ui-渲染策略)

---

## 1. 连接与会话初始化

### 1.1 连接方式

CodexMonitor 通过 **Tauri IPC 事件总线** 与后端通信（因为它是桌面 App）。  
我们的 Flutter 端使用 **直接 WebSocket**——协议载荷完全相同，只是传输层不同。

**核心事件频道**：`"app-server-event"`（所有 server → client 消息通过此频道下发）

```
参考文件: reference/CodexMonitor/src/services/events.ts
参考文件: reference/CodexMonitor/src/utils/appServerEvents.ts
```

### 1.2 初始化握手序列

连接建立后必须按以下顺序完成握手：

#### Step 1: `initialize` 请求（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "clientInfo": {
      "name": "workbench",
      "version": "0.1.0"
    }
  }
}
```

#### Step 2: `initialized` 通知（Client → Server，无 id）

```json
{
  "jsonrpc": "2.0",
  "method": "initialized",
  "params": {}
}
```

#### Step 3: Server 确认连接

Server 下发 method `"codex/connected"`：

```json
{
  "method": "codex/connected",
  "params": {
    "workspace_id": "<uuid>"
  }
}
```

### 1.3 Thread 创建

#### `thread/create` 请求（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "thread/create",
  "params": {}
}
```

#### Server 响应 `thread/started`

```json
{
  "method": "thread/started",
  "params": {
    "thread": {
      "id": "<threadId>",
      "preview": "<初始线程名预览>"
    }
  }
}
```

### 1.4 Turn 启动（发送用户消息）

#### `turn/start` 请求（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "turn/start",
  "params": {
    "threadId": "<threadId>",
    "userMessage": "<用户输入文本>",
    "model": "<可选，如 qwen-plus>",
    "effort": null,
    "serviceTier": null,
    "collaborationMode": null,
    "accessMode": "full-access",
    "images": [],
    "appMentions": []
  }
}
```

**关键字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `threadId` | string | 必填，当前会话 ID |
| `userMessage` | string | 用户消息文本 |
| `model` | string \| null | 可选，覆盖 config 中的 model |
| `effort` | string \| null | 可选，"low" / "medium" / "high" |
| `serviceTier` | string \| null | "fast" \| "flex"，通常 null |
| `collaborationMode` | object \| null | 协作模式，通常 null |
| `accessMode` | string | "read-only" \| "current" \| "full-access" |
| `images` | string[] | Base64 图片列表，通常 [] |
| `appMentions` | array | 应用提及，通常 [] |

#### Server 响应（turn/start 的 JSON-RPC result）

```json
{
  "id": 3,
  "result": {
    "turn": {
      "id": "<turnId>",
      "threadId": "<threadId>"
    }
  }
}
```

### 1.5 Turn 中断

#### `turn/interrupt` 请求（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "turn/interrupt",
  "params": {
    "threadId": "<threadId>",
    "turnId": "<turnId>"
  }
}
```

---

## 2. 消息数据结构：ConversationItem Blocks

### 2.1 核心原则

**禁止将所有内容拼接为单一字符串**。每条 server 下发的 item 都应转化为带有 `kind` 判别字段的 Block 对象，按类型分离渲染。

```
参考文件: reference/CodexMonitor/src/types.ts (Lines 100-142)
参考文件: reference/CodexMonitor/src/utils/threadItems.conversion.ts
```

### 2.2 ConversationItem 完整类型（TypeScript 原文）

```typescript
// 判别字段：kind
type ConversationItem =
  // 普通消息（用户 / AI 文字回复）
  | {
      id: string;
      kind: "message";
      role: "user" | "assistant";
      text: string;
      images?: string[];
    }

  // 工具调用（命令执行、文件变更、MCP 工具等）
  | {
      id: string;
      kind: "tool";
      toolType: ToolType;    // 见 2.3
      title: string;         // 人类可读的标题
      detail: string;        // 参数摘要（命令行、文件路径等）
      status?: string;       // "in_progress" | "success" | "error" | "completed"
      output?: string;       // 累积的输出文本
      durationMs?: number | null;
      changes?: {            // 仅 fileChange 类型有
        path: string;
        kind?: string;       // "add" | "delete" | "modify"
        diff?: string;
      }[];
    }

  // 用户输入请求（approval / userInput）
  | {
      id: string;
      kind: "userInput";
      status: "answered";
      questions: unknown[];
    }

  // 推理过程（reasoning）
  | {
      id: string;
      kind: "reasoning";
      summary: string;
      content: string;
    }

  // Diff 展示
  | {
      id: string;
      kind: "diff";
      title: string;
      diff: string;
      status?: string;
    }

  // 代码审查
  | { id: string; kind: "review"; state: "started" | "completed"; text: string }

  // 目录探索
  | { id: string; kind: "explore"; status: "exploring" | "explored"; entries: unknown[] };
```

### 2.3 ToolType 枚举值

```typescript
type ToolType =
  | "commandExecution"    // bash / shell 命令
  | "fileChange"          // 文件读写变更
  | "plan"                // Agent 计划步骤
  | "mcpToolCall"         // MCP 扩展工具
  | "webSearch"           // 网络搜索
  | "imageView"           // 图片查看
  | "collabToolCall"      // 协作工具调用
  | "contextCompaction";  // 上下文压缩
```

### 2.4 Server Item → Client Block 转换规则

```
参考文件: reference/CodexMonitor/src/utils/threadItems.conversion.ts (Lines 44-206)
```

| Server `type` 字段 | 转换为 Client `kind` | 备注 |
|-------------------|---------------------|------|
| `"agentMessage"` | `kind: "message"`, `role: "assistant"` | text 从 streaming delta 累积 |
| `"userMessage"` | `kind: "message"`, `role: "user"` | content 数组解析 |
| `"commandExecution"` | `kind: "tool"`, `toolType: "commandExecution"` | - |
| `"fileChange"` | `kind: "tool"`, `toolType: "fileChange"` | 含 changes 数组 |
| `"mcpToolCall"` | `kind: "tool"`, `toolType: "mcpToolCall"` | - |
| `"plan"` | `kind: "tool"`, `toolType: "plan"` | - |

### 2.5 Flutter/Dart 对应建议

```dart
// 对应 TypeScript 的判别 union，用 sealed class 或 abstract class 实现：

abstract class MessageBlock {
  final String id;
  const MessageBlock(this.id);
}

class TextBlock extends MessageBlock {
  final String role;   // "user" | "assistant"
  String text;
  TextBlock({required super.id, required this.role, this.text = ''});
}

class ToolCallBlock extends MessageBlock {
  final String toolType;
  final String title;
  String detail;
  String? output;
  String status;  // "in_progress" | "success" | "error" | "completed"
  int? durationMs;
  List<FileChange> changes;
  ToolCallBlock({required super.id, required this.toolType, ...});
}
```

---

## 3. 事件流解析：所有 Server → Client 事件

### 3.1 完整事件方法列表

```
参考文件: reference/CodexMonitor/src/utils/appServerEvents.ts (Lines 3-36)
```

| 事件方法名 | 触发时机 |
|-----------|---------|
| `item/agentMessage/delta` | AI 回复文字流（每个 token 块） |
| `item/started` | 新 item 开始（工具调用启动） |
| `item/completed` | item 完成（工具调用结束） |
| `item/commandExecution/outputDelta` | 命令执行的标准输出流 |
| `item/commandExecution/terminalInteraction` | 命令执行的终端交互 |
| `item/fileChange/outputDelta` | 文件变更的增量输出 |
| `item/plan/delta` | Agent 计划文本流 |
| `item/reasoning/summaryTextDelta` | 推理摘要文本流 |
| `item/reasoning/summaryPartAdded` | 推理摘要段落边界 |
| `item/reasoning/textDelta` | 推理过程文本流 |
| `item/tool/requestUserInput` | 工具请求用户输入（approval） |
| `turn/started` | Turn 开始 |
| `turn/completed` | Turn 结束 |
| `turn/plan/updated` | Turn 级别计划更新 |
| `turn/diff/updated` | Turn 产生的 Diff 更新 |
| `thread/started` | Thread 创建完成 |
| `thread/closed` | Thread 关闭 |
| `thread/archived` / `thread/unarchived` | Thread 归档状态 |
| `thread/name/updated` | Thread 名称更新 |
| `thread/status/changed` | Thread 状态变化 |
| `thread/tokenUsage/updated` | Token 用量更新 |

### 3.2 AI 回复文本流

#### `item/agentMessage/delta`

```json
{
  "method": "item/agentMessage/delta",
  "params": {
    "threadId": "<threadId>",
    "itemId": "<itemId>",
    "delta": "你好，我"
  }
}
```

**处理逻辑**：
1. 在 `items` 中根据 `itemId` 查找或新建 `TextBlock`（role: "assistant"）
2. 将 `delta` 追加到 `text` 字段（`text += delta`）
3. 触发 UI 重建

### 3.3 工具调用生命周期

#### `item/started`（工具调用启动）

```json
{
  "method": "item/started",
  "params": {
    "threadId": "<threadId>",
    "item": {
      "id": "<itemId>",
      "type": "commandExecution",
      "command": "ls -la",
      "workdir": "/home/user"
    }
  }
}
```

**处理逻辑**：
1. 按 `item.type` 创建对应 Block
2. 设置 `status = "in_progress"`
3. 填充 `title` 和 `detail`（从 `item` 字段提取）

#### `item/commandExecution/outputDelta`（命令输出流）

```json
{
  "method": "item/commandExecution/outputDelta",
  "params": {
    "threadId": "<threadId>",
    "itemId": "<itemId>",
    "delta": "total 48\n-rw-r--r-- ..."
  }
}
```

**处理逻辑**：将 `delta` 追加到对应 ToolCallBlock 的 `output` 字段

#### `item/completed`（工具调用完成）

```json
{
  "method": "item/completed",
  "params": {
    "threadId": "<threadId>",
    "item": {
      "id": "<itemId>",
      "type": "commandExecution",
      "status": "success",
      "aggregatedOutput": "完整输出文本...",
      "durationMs": 1234
    }
  }
}
```

**处理逻辑**：
1. 根据 `item.status` 更新 Block 状态（`"success"` / `"error"` / `"completed"`）
2. 若有 `aggregatedOutput`，覆盖 `output`（比 delta 累积更准确）
3. 设置 `durationMs`

### 3.4 Turn 生命周期

#### `turn/started`

```json
{
  "method": "turn/started",
  "params": {
    "threadId": "<threadId>",
    "turnId": "<turnId>",
    "turn": { "id": "<turnId>", "threadId": "<threadId>" }
  }
}
```

**处理**：标记 thread 为 "processing" 状态，记录 `activeTurnId`

#### `turn/completed`

```json
{
  "method": "turn/completed",
  "params": {
    "threadId": "<threadId>",
    "turnId": "<turnId>"
  }
}
```

**处理**：清除 "processing" 状态，清空 `activeTurnId`

#### `turn/diff/updated`

```json
{
  "method": "turn/diff/updated",
  "params": {
    "threadId": "<threadId>",
    "turnId": "<turnId>",
    "diff": "diff --git a/file.txt b/file.txt\n..."
  }
}
```

**处理**：保存至 `lastTurnDiff`，可在 Diff Viewer 中展示

### 3.5 Approval 请求

#### `item/tool/requestUserInput`

```json
{
  "method": "item/tool/requestUserInput",
  "params": {
    "threadId": "<threadId>",
    "itemId": "<itemId>",
    "request": {
      "type": "commandExecution",
      "command": "rm -rf /tmp/old_files",
      "workdir": "/home/user"
    }
  }
}
```

**处理**：弹出 Approval Panel，等待用户操作

#### `turn/approval/respond` 响应（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "turn/approval/respond",
  "params": {
    "threadId": "<threadId>",
    "itemId": "<itemId>",
    "decision": "allow"
  }
}
```

**`decision` 可选值**：`"allow"` | `"deny"`

---

## 4. 状态机：Tool 调用的生命周期

### 4.1 状态流转

```
(未存在) ──item/started──▶ "in_progress"
                                │
          outputDelta 持续追加 output
                                │
         ──item/completed──▶  "success"
                           或  "error"
                           或  "completed"
```

### 4.2 Status 字符串规范化

```
参考文件: reference/CodexMonitor/src/features/messages/components/MessageRows.tsx (Lines 725-730)
```

CodexMonitor 使用正则判断"是否正在运行"：

```typescript
const normalizedStatus = (item.status ?? "").toLowerCase();
const isRunning = /in[_\s-]*progress|running|started/.test(normalizedStatus);
```

**实践建议（Flutter）**：

```dart
bool get isRunning {
  final s = (status ?? '').toLowerCase();
  return s.contains('progress') || s == 'running' || s == 'started';
}

bool get isDone {
  final s = (status ?? '').toLowerCase();
  return s == 'success' || s == 'completed' || s == 'error';
}
```

### 4.3 Tool 类型对应的标题/详情提取规则

| `toolType` | `title` 来源 | `detail` 来源 |
|-----------|-------------|--------------|
| `commandExecution` | `"$ " + command` | `workdir` |
| `fileChange` | 文件路径 basename | `changes.length + " files"` |
| `mcpToolCall` | tool name | JSON.stringify(input_args) |
| `plan` | `"Plan"` | plan text delta |
| `webSearch` | query | - |

---

## 5. UI 渲染策略

### 5.1 工具调用折叠组件结构

```
参考文件: reference/CodexMonitor/src/features/messages/components/MessageRows.tsx (Lines 686-930)
```

```
ToolRow (ToolCallBlock 对应)
  ├── [collapsed state]
  │     工具图标 + title + detail摘要 + status标志 (loading/✓/✗)
  │
  └── [expanded state]
        ├── detail（命令参数、文件路径）
        ├── changes list（仅 fileChange，显示 diff）
        └── CommandOutput（终端输出，最多 100 行）
```

**展开/折叠状态管理**（组件级 Set，不进入全局状态）：

```typescript
// CodexMonitor 实现
const [expandedItemIds, setExpandedItemIds] = useState<Set<string>>(new Set());

const handleToggle = (itemId: string) => {
  setExpandedItemIds(prev => {
    const next = new Set(prev);
    next.has(itemId) ? next.delete(itemId) : next.add(itemId);
    return next;
  });
};
```

**Flutter 对应**：在 ChatView widget 中维护 `Set<String> expandedIds`

### 5.2 工具图标选择规则

```
参考文件: reference/CodexMonitor/src/features/messages/components/MessageRows.tsx (Lines 251-286)
```

| toolType | 对应图标 |
|---------|---------|
| `commandExecution` | Terminal / Code 图标 |
| `fileChange` | FileDiff / Edit 图标 |
| `webSearch` | Search 图标 |
| `imageView` | Image 图标 |
| `plan` | ListOrdered / Task 图标 |
| `mcpToolCall` | Wrench 图标 |
| 其他 | Wrench（默认）|

### 5.3 命令输出展示策略（关键细节）

```
参考文件: reference/CodexMonitor/src/features/messages/components/MessageRows.tsx (Lines 734-756)
```

CodexMonitor 的命令输出展示有 **3 种触发条件**（满足任一即显示）：

1. **用户主动展开**：`isExpanded == true`
2. **命令运行超过 600ms**：设置 600ms 延时后自动显示实时输出（避免闪烁）
3. **长时间运行**：`isLongRunning == true`（超过某阈值）

```typescript
// 600ms 防抖逻辑
useEffect(() => {
  if (!isRunning) { setShowLiveOutput(false); return; }
  const id = setTimeout(() => setShowLiveOutput(true), 600);
  return () => clearTimeout(id);
}, [isRunning]);

const showOutput = isCommand && output &&
  (isExpanded || (isRunning && showLiveOutput) || isLongRunning);
```

**Flutter 建议**：用 `Timer` 实现同样的 600ms 延迟逻辑

### 5.4 命令输出行数限制

```
参考文件: reference/CodexMonitor/src/features/messages/components/MessageRows.tsx (Lines 192-249)
```

- 最多显示 **100 行**（`MAX_COMMAND_OUTPUT_LINES = 100`）
- 超出时从**顶部截断**，只保留最新 100 行
- 提示用户"已省略 N 行"
- 自动滚动到底部（`scrollTop = scrollHeight`，仅 pinned 时）

### 5.5 Diff Viewer 与 Approval Panel 独立性原则

**严格遵守**：以下内容**绝不嵌入聊天气泡**：
- Approval 请求弹出独立底部抽屉（Bottom Sheet）
- Diff 展示在独立 Diff Viewer 面板
- 聊天气泡中的 ToolCallBlock 收起时仅显示"等待审批中..."占位

---

## 附录：JSON-RPC 消息格式规范

### 请求（Client → Server）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "<method>",
  "params": { ... }
}
```

### 通知（Client → Server，无 id）

```json
{
  "jsonrpc": "2.0",
  "method": "<method>",
  "params": { ... }
}
```

### 响应（Server → Client，回复请求）

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { ... }
}
```

### 事件推送（Server → Client，无 id）

```json
{
  "method": "<event-method>",
  "params": { ... }
}
```

---

## 附录：常用字段别名说明

`codex-rs` 的事件字段存在下划线/驼峰两种格式，需双向兼容：

| 下划线格式 | 驼峰格式 | 含义 |
|-----------|---------|------|
| `thread_id` | `threadId` | Thread ID |
| `item_id` | `itemId` | Item ID |
| `turn_id` | `turnId` | Turn ID |
| `workspace_id` | `workspaceId` | Workspace ID |

**建议**：Dart 端的 `fromJson` 应同时兼容两种格式：
```dart
final threadId = json['threadId'] ?? json['thread_id'];
```
