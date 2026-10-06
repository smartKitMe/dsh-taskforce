---
name: agent-team-protocol
description: 专案组（dsh-taskforce）动态团队运行手册：28 个 TEAM_* 错误码与触发/处置/依据、容量与限额（maxMembers 本机 profile 8 / 实现默认 16，以运行时为准；maxTasks 256、mailbox 64、消息体 65536 字节）、write_scopes 合法与非法写法（含工作区绝对路径必被拒）、五个岗位模板与成员 5 段回报格式、六要素委派契约、验收 rubric（≥90 PASS / 60–89 返工 / <60 或造假 FAIL）与证据等级三分。Use when working inside the 专案组 (dsh-taskforce) preset — error codes, capacity limits, member reporting format, write-scope rules, and the acceptance rubric.
---

# 专案组（dsh-taskforce）· 动态团队运行手册

> 本手册是 persona 的配套：**persona 写「必须遵守什么」，本手册写「怎么做：工具字段、错误码表、岗位模板、评分表」**。
> persona 已写死的承重规则（组队准入、任务板先行、写协议、唤醒顺序、预算与终止、安全红线、workflow 治理、降级条款）**本手册不复述**，只给操作层细节与可抄的模板。
> 开工前加载本 skill；回复用户时不要复述本手册全文。

## 0. 一句话定位与代价

以**共享任务板**为唯一事实源，把一个任务动态路由到按需招募的 teammate；
Lead 只做拆解、委派、消解冲突与最终验收。

**与静态编制的根本差别**：静态编制里角色是 preset 的固定工具行，权限由 `toolFilter` **机械**保证；
动态团队里角色是运行时的「任务 + prompt」，**没有工具白名单机制**（`spawn_teammate` 只有
`name` / `description` / `prompt` / `context` 四个参数，不能设工具白名单、模型或深度）。
所以本模式把机械保证换成了下面这份「替代品清单」——每一项都必须由 Lead 主动执行，否则就是裸奔：

| 静态编制里的机械保证 | 动态团队的替代品（缺一即失效） |
|---|---|
| `toolFilter` 工具白名单 | prompt 里显式写「能用哪些工具」+ 岗位只读纪律 + Lead 抽查 |
| 固定角色与职责边界 | 任务板 `write_scopes` + 六要素委派契约（第 4 节） |
| 编译/类型系统的即时反馈 | 每条验收标准必须带可执行命令 + 真实输出（第 5 节） |
| 独立 CI 评审 | 执行者不得自评；评审必须是**另一个** teammate 或 Lead 亲验 |
| 版本控制合并保护 | read/edit/write 的文件版本守卫（`FS_STALE_VERSION`）+ `revision` CAS |
| 构建产物的确定性 | 承重内容落盘 + sha256 指纹 + 涵盖 `diff` 的独立核对 |

## 1. 工具速查（必填/可选 + 容量上限 + 陷阱）

| 工具 | 参数（★=必填，其余可选） | 返回 | 容量与限制 | 关键陷阱 |
|---|---|---|---|---|
| `spawn_teammate` | ★`name` ★`description` ★`prompt`；`context`(fresh/fork，默认 fresh) | `{member}` | 成员总数 ≤ `maxMembers`：**本机 profile 为 8，实现默认 16，以运行时为准** | **不能设工具白名单/模型/深度**；名字永久占用，创建失败也占名 |
| `send_message` | ★`target` ★`message` | `{messageId, status: accepted\|queued}` | 同一成员待处理消息上限 64 条；已有 64 条未投递时，后续 `send_message` 被拒（`TEAM_MAILBOX_FULL`）；单条 `deliveryContent` ≤ 65,536 字节 | `queued` 已持久化，**绝不重发**；单条 > 65,536 字节 → `TEAM_MESSAGE_TOO_LARGE` |
| `list_agents` | 无 | 成员数组：`target/role/status/description/provider/context/model/diagnostics` | — | `inactive` 只表示当前无轮次执行，**≠ 完成** |
| `wait_agent` | `timeout_ms` | `{timedOut, noProgress?}` | `timeout_ms` 10,000–3,600,000，默认 30,000 | 不会唤醒任何人；无 running/provisioning 成员时立刻返回 `noProgress{reason:"no-active-peer"}` |
| `interrupt_agent` | ★`target` | `{previousStatus}` | Lead-only | 只中断当前轮次，**保留对方 inbox、不释放任务 owner** |
| `team_task_create` | ★`subject` ★`description`；`blocked_by[]`、`write_scopes[]` | 任务视图 | 活跃任务 ≤ 256（`maxTasks`） | 创建即 `pending`、无 owner；`write_scopes` **API 层可选、协议层必填** |
| `team_task_list` | `status`、`owner`（可用 `unowned`）、`ready`、`cursor`、`limit` | `{tasks, nextCursor?}` | `limit` 1–100，默认 50 | 需分页；tombstone（已删除）不在列表出现 |
| `team_task_get` | ★`task_id` | 任务视图（含 `revision`） | — | 改之前必读，否则 `TEAM_TASK_STALE_REVISION` |
| `team_task_update` | ★`task_id` ★`expected_revision` ★`action` + 各 action 字段 | 新任务视图 | — | CAS 更新；`owner` 字段仅 Lead 可赋值（`reassign`） |

`action` 取值：`claim` · `release` · `edit` · `set_dependencies` · `complete` · `reopen` · `reassign` · `delete`。

**任务视图字段**：`id` `revision` `subject` `description` `status`(pending/in_progress/completed/deleted)
`ownerName?` `blockedBy[]` `writeScopes[]` `ready` `writeScopeWarnings[]`。

> `subagent` / `subagent_fork` 在 Team 层被禁用（同名全局控件亦是）；
> 但 `workflow` 仍保留 spawn provider —— 它的 `agent()` 子代理**不进 roster、不占 maxMembers、不占任务板、不受 write scope 约束**。治理规则见 persona 的 workflow 节，本手册只在第 7、8 节列为反模式与自检项。

## 2. 任务板协议与 28 个 `TEAM_*` 错误码

```
list → get(拿 revision) → claim → 干活 → complete
```

**「依据」列语义（必须原样保留，不得省略，不得把 `命名推定` 写成实测）**：

- `源码` = 在实现中读到抛出点 / Promise reject 点或其分支（并尽量引原文）；**不等于在真实会话里触发过**（可达性由代码上下文推断）。
- `文档` = 官方 README / 限额表明确描述。
- `命名推定` = 未读到触发点，或读到的站点不足以确定完整触发语义（含站点与码名不一致的情况）——断言时必须标注为推定；**当前表中无用例，保留该类别供将来使用**。

### 2.1 配额 / 容量（4）

| 错误码 | 触发 | 处置 | 依据 |
|---|---|---|---|
| `TEAM_MEMBER_LIMIT` | 招募超出 `maxMembers`（含失败成员） | 停止招人，收敛任务；换名也不能绕过 | 源码 |
| `TEAM_TASK_LIMIT` | 创建任务时，未删除（活跃）任务数 ≥ `maxTasks`（256）即被拒；删除后为 tombstone，**不计入**该计数 | 完成即 `complete`、废弃即 `delete`（tombstone 不占额度） | 源码 |
| `TEAM_MAILBOX_FULL` | 同一成员已有 64 条未投递消息时，再发 `send_message` 即被拒（`pendingForTarget >= maxPendingMessagesPerMember`） | 停止连发；改为合并成一条摘要或等其消化 | 源码 |
| `TEAM_MESSAGE_TOO_LARGE` | 单条消息 > 65,536 字节 | 落盘为文件，消息内只给路径 | 源码 |

### 2.2 命名与参数（7）

| 错误码 | 触发 | 处置 | 依据 |
|---|---|---|---|
| `TEAM_INVALID_WRITE_SCOPE` | 见第 2.6 节 write scope 规则 | 改成工作区相对 POSIX 前缀 | 源码 |
| `TEAM_INVALID_MEMBER_NAME` | 名字不匹配 `^[a-z0-9]+(?:-[a-z0-9]+)*$`，或长度 > 64，或等于保留名 `lead` | 改小写 kebab（`review-2`）；长度 ≤ 64；不要用 `lead` | 源码 |
| `TEAM_MEMBER_NAME_TAKEN` | 名字已被占用（失败成员也永久占名） | 换新名字，禁止复用 | 文档 |
| `TEAM_INVALID_TIMEOUT` | `wait_agent` 超时值越界 | 用 10s–1h 内的整数毫秒 | 文档 |
| `TEAM_INVALID_TARGET` | `interrupt_agent` 的目标非法（实现中明确可见的抛出错：Lead 试图 interrupt 自己） | 不要 interrupt 自己；用 `list_agents` 核对 `target` | 源码 |
| `TEAM_INVALID_ARGUMENT` | 参数缺失/类型错 | 按 schema 修正 | 源码 |
| `TEAM_INVALID_CONFIG` | 部署限额不是正安全整数（启动期 `positiveLimit()` 校验，如 maxMembers/maxTasks 传 0 或负数） | 报告人类，改 profile 配置 | 源码 |

### 2.3 任务板（9）

| 错误码 | 触发 | 处置 | 依据 |
|---|---|---|---|
| `TEAM_TASK_STALE_REVISION` | 用过期 `revision` 更新 | 重读 → 重基 → 重试；不得覆盖 | 源码 |
| `TEAM_TASK_BLOCKED` | claim 一个 `ready=false` 的任务 | 先完成 `blockedBy`；依赖满足后由完成者 `send_message` 唤醒 | 文档 |
| `TEAM_TASK_INVALID_TRANSITION` | `release` 非 in_progress / `reopen` 非 completed 等 | 先读状态再选 action | 文档 |
| `TEAM_TASK_ALREADY_CLAIMED` | claim 时任务已有 owner（`ownerId !== undefined && ownerId !== caller.id`） | 先 `reassign` 或 `release`，再 claim | 源码 |
| `TEAM_TASK_DEPENDENCY_CYCLE` | 可读的具体站点是**任务自依赖**（`blockedBy` 含自身）；一般成环由依赖图校验的 `TASK_GRAPH_ERROR_CODES` 映射表判定 | 重划依赖，禁止环 | 源码 |
| `TEAM_TASK_HAS_DEPENDENTS` | delete 时仍有其他任务的 `blockedBy` 引用它 | 先处理/重挂下游，再删 | 源码 |
| `TEAM_TASK_NOT_FOUND` | 任务 id 不存在（实现另含「blocker id 不存在」变体） | 用 `team_task_list` 重新取 id | 源码 |
| `TEAM_TASK_DELETED` | 对 `status === "deleted"`（tombstone）的任务继续 update | 不再操作；需要就新建任务 | 源码 |
| `TEAM_TASK_UNAUTHORIZED` | mutation 的调用者既非 owner 也非 Lead | 找 owner 或让 Lead `reassign` | 源码 |

### 2.4 成员与权限（5）

| 错误码 | 触发 | 处置 | 依据 |
|---|---|---|---|
| `TEAM_LEAD_REQUIRED` | teammate 调用 Lead-only 操作（spawn / interrupt / reassign） | 由 Lead 执行；teammate 只回报 | 文档 |
| `TEAM_MEMBER_NOT_FOUND` | 目标不是成员 | 用 `list_agents` 核对 `target` | 文档 |
| `TEAM_NOT_MEMBER` | agent 不属于任何活跃 Team（membership 解析失败） | 说明该会话未启用 Team 层 | 源码 |
| `TEAM_PROVISIONING_CONFLICT` | 恢复期同进程竞态抢到同一 provisioning 记录 | 接受终态或换名重试；不要并发建同名 | 源码 |
| `TEAM_SELF_MESSAGE` | `target.id === caller.id`（给自己发消息） | 直接推进，不要自发自收 | 源码 |

### 2.5 生命周期（3）

| 错误码 | 触发 | 处置 | 依据 |
|---|---|---|---|
| `TEAM_WAIT_ABORTED` | wait 被取消/释放（含会话销毁）；实现里是 Promise **reject**，且**只有取消原因不是 Error 时**才包装成该码（Error 原因原样透传） | 重新 `list_agents` + `team_task_list` 再决策 | 源码 |
| `TEAM_DISPOSED` | Team 服务已进入 disposing 状态后继续 `spawn`/`send` | 停止；如实告知用户团队已终止 | 源码 |
| `TEAM_DISPOSAL_TIMEOUT` | 关闭清理超过 `disposalTimeoutMs`（5,000ms）仍未完成；实现里是 Promise **reject**，不是 throw | 记录并如实报告，不要谎报清理成功 | 源码 |

> 合计：4 + 7 + 9 + 5 + 3 = **28** 个。遇到表中没有的 `TEAM_*`：如实报告原文，不要猜语义。

### 2.6 write_scopes 规则（最高频机械报错来源）

源码函数 `writeScope()` 的行为：

1. 归一化：`\` → `/`；去掉开头 `./`；去掉结尾 `/`。
2. 以下一律抛 `TEAM_INVALID_WRITE_SCOPE`：空串、以 `/` 开头（绝对路径）、盘符前缀（`X:`）、
   任何空段 / `.` / `..`。
3. **`team_task_create` 的 `write_scopes` 在 API 层是可选参数**；**协议层要求必填**，
   缺失即视为违规（协议纪律，不是工具强制）。

| 合法示例 | 非法示例 |
|---|---|
| `src/agents`、`docs/plans/x.md`、`src/**`、`a/b-c/d` | `C:\proj\src`（Windows 盘符）、`/abs/x`、`../x`、`.`、`./`、`` |

> **绝对路径一律被拒**：Windows 盘符（`C:\...`）与 POSIX 绝对路径（`/abs/x`）都会报
> `TEAM_INVALID_WRITE_SCOPE`——Lead 很容易顺手写绝对路径。
> 统一写成工作区相对 POSIX 前缀（如上表左侧）。这是本 preset 最高频的机械报错来源。

### 2.7 硬规则

1. `revision` 从 1 开始，每次变更 +1；所有编辑都带 `expected_revision`（CAS）。
2. 同一个 write scope 前缀只允许一个 `in_progress` 任务；`writeScopeWarnings` 出现即调整划分。
3. 任务粒度 = **一个可独立验收的交付物**，不是「一个动作」。
4. 依赖只表达顺序：**不会唤醒 owner**。依赖满足后由**完成者** `send_message` 唤醒下游（或 Lead 代唤）。
5. `interrupt_agent` 不释放 owner；换人顺序：`reopen` → `release`/`reassign` → `send_message` 唤醒新 owner。
6. 任务 `complete` 之前，任何「已完成」的表述都是不实呈现。
7. 删除的任务保留为 tombstone：不占额度、不出现在 list，继续操作会报 `TEAM_TASK_DELETED`。
8. Lead 自己的工作也必须上板：`claim`(ownerName=lead) → 做 → `complete`，不允许「任务板只记别人」。

## 3. 五个岗位模板（spawn 的 prompt 骨架，按需裁剪）

> 通用要求：prompt **自包含**（fresh 看不到 Lead 历史）；六要素齐全；显式写「你能用哪些工具、绝不能改哪些路径」。

**成员回报格式（5 段，写进每个 spawn prompt，缺段即返工）**：

```
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行：T-<id>｜<一句话可执行结论>
② 证据等级：真实文件级行为验证 / 构造级等价验证(副本) / 静态判据（三选一，不得混写）
③ 产物路径：<落盘文件路径，可多个>
④ 验收命令与真实输出摘要：<实际跑过的命令 + 关键输出行（长输出先落盘再引路径）>
⑤ 阻塞/未做项：<无则写「无」；有则写清现象与需要谁决策>
```

### 3.1 探索岗（fresh，只读）

```
你是探索员 <name>。使命：<一句话可验证的目标>（任务 id：T-<id>）。
输入：<路径/引用>
产出：把结论写入 <artifact 路径>，只回一句结论 + 该路径 + 关键行号；不要粘贴大段原文。
纪律：只读。不得修改工作区任何文件；不得创建文件（除了上面那个 artifact）。
证据：每条结论指到 文件+行号 或 命令回显；找不到就如实说缺口，不得编造。
预算（可机械核对）：≤ <N> 条消息回报、≤ <N> 轮工具循环、并发队友 ≤ <N>。遇到不明确处先提问，不要猜。
额外要求：指出任何可能影响其他任务的发现（越界提示）。
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行；② 证据等级（三分选一，不混写）；③ 产物路径；
④ 验收命令与真实输出摘要；⑤ 阻塞/未做项。
```

### 3.2 写者岗（fresh 或 fork，单一写作用域）

```
你是实现者 <name>。使命：<一句话>（任务 id：T-<id>）。
写作用域（唯一允许改动的范围）：<工作区相对 POSIX 前缀，如 src/agents>。**范围外一律不得改动。**
输入：<上游产物路径>
产出格式：<严格结构>
改文件方式：一律 read → edit/write。收到 FS_STALE_VERSION 时重读、重基、重试。
禁止：shell 重定向写文件、跑 formatter/代码生成（需要时先向 Lead 申请独占写作用域任务）。
自证：给出你实际运行的命令与真实输出（不要描述「应该会通过」）。
预算（可机械核对）：≤ <N> 条消息回报、≤ <N> 轮工具循环、并发队友 ≤ <N>。
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行；② 证据等级（三分选一，不混写）；③ 产物路径；
④ 验收命令与真实输出摘要；⑤ 阻塞/未做项。
```

> `fork` 仅用于必须延续 Lead 已完成的判断链；其余用 `fresh`（上下文更省、污染更少）。

### 3.3 评审岗（fresh，只读，只报告）

```
你是独立评审员 <name>。评审对象：<artifact 路径或 diff 范围>（任务 id：T-<id>）。
你只报告，不修改：任何文件写入都不是你的产出。
评分表：<逐项 + 分值 + 满分要求>。满分 = <N>（第 5 节 rubric）。
反造假逐项排查：①陈旧产物 ②时间窗伪影 ③计数不可靠 ④假 FAIL ⑤副本/桩替代真实被测物 ⑥脚本失败可见性缺失。
证据等级三分，不得混写：真实文件级行为验证 / 构造级等价验证(副本) / 静态判据。
产出：<评分记录路径>（含 sha256 指纹、评审时刻、逐项得分、扣分理由 + 实测证据）。
结论只能是 PASS / FAIL / UNCERTAIN 之一；不确定就判 UNCERTAIN，不得「看起来没问题」给满分。
预算（可机械核对）：≤ <N> 条消息回报、≤ <N> 轮工具循环、并发队友 ≤ <N>。
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行；② 证据等级（三分选一，不混写）；③ 产物路径；
④ 验收命令与真实输出摘要；⑤ 阻塞/未做项。
```

### 3.4 文档岗（fresh，写交付物目录）

```
你是文档员 <name>。使命：按 <模板路径> 产出 <交付物清单>（任务 id：T-<id>）。
写作用域（唯一允许改动的范围）：<docs/... 相对 POSIX 前缀>。
铁律：内容必须与真实产物一致（图表与实际结构一致、数字与实际输出一致），不得凭记忆编写。
产出：<文件列表> + 每份一句话摘要。
预算（可机械核对）：≤ <N> 条消息回报、≤ <N> 轮工具循环、并发队友 ≤ <N>。
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行；② 证据等级（三分选一，不混写）；③ 产物路径；
④ 验收命令与真实输出摘要；⑤ 阻塞/未做项。
```

### 3.5 复盘岗（fresh，只读，元复盘）

```
你是复盘员 <name>。审视**本模式这一次运行本身**，而不是业务代码（任务 id：T-<id>）：
闸门是否真拦住东西 / 角色是否冗余或缺失 / 拆解是否准确 / 委派 prompt 是否含糊 /
协作通道（消息、任务板、唤醒时机）是否出问题 / 产物是否可追溯 / 有无假 PASS /
workflow 是否被用作写路径的旁路。
产出：<复盘文件>，含「可执行的优化项」（每条：现象 → 根因 → 具体改法）。
允许批评 Lead 的编排决策。
预算（可机械核对）：≤ <N> 条消息回报、≤ <N> 轮工具循环、并发队友 ≤ <N>。
回报格式（严格 5 段，首行即结论）：
① 任务 id + 结论首行；② 证据等级（三分选一，不混写）；③ 产物路径；
④ 验收命令与真实输出摘要；⑤ 阻塞/未做项。
```

## 4. 六要素委派契约（缺一不可）

| # | 要素 | 合格写法 | 反例 |
|---|---|---|---|
| 1 | 目标（可验证，不是主题） | 「让 `validate-preset`（Windows `.ps1` / Linux、macOS `.sh`）对当前 bundle 输出全 PASS」 | ✗「研究一下供应链」 |
| 2 | 输入与路径 | 给出文件绝对/相对路径、上游产物、行号 | ✗ 让对方自己找 |
| 3 | 输出格式（严格结构 + 必须字段） | 落盘路径 + 必须字段 + 5 段回报格式 | ✗「写个报告」 |
| 4 | 边界（不要做什么 + 写作用域） | 工作区相对 POSIX 前缀（见 2.6）+ 禁区清单 | ✗ 不说边界 → 越权改动 |
| 5 | 验收标准（可执行命令 + 预期输出） | 「跑 X，期望 Y；不过就报真实输出」 | ✗「做完告诉我」 |
| 6 | 预算（可机械核对口径） | 消息条数上限、工具循环轮次上限、并发队友数上限 | ✗ 无上限；✗ 用「多少 token」这类无计量载体的口径 |

> 预算一律使用**可数指标**：`send_message` 条数、工具循环轮次、并发 running 成员数、
> workflow 子代理数（参考第 9 节容量数字）。**不要写 token 数**——没有计量载体，无法机械核对。

## 5. 验收 rubric（可直接抄，按域替换）

| 维度 | 权重 | 满分要求 |
|---|---|---|
| 事实正确性 | 30 | 每条结论可指到真实来源（文件+行号 / 命令回显） |
| 验收标准达成 | 25 | 逐条给出实际执行的命令与真实输出 |
| 完整性 | 20 | 需求逐条对应，无静默遗漏；未做项显式列出 |
| 边界遵守 | 15 | 改动全部落在声明的写作用域内（用 `git diff --numstat` 核对） |
| 证据等级标注 | 10 | 三分标注正确、无混写 |

**阈值（与 persona 统一，不得自行放宽）**：

- **≥90 且无造假证据 → PASS**
- **60–89 → 返工**
- **<60 或存在造假证据 → FAIL 并升级人类**

**静态判据计分上限**：静态判据（只读源码/文档、未实际执行）可计入「验收标准达成」分，
但必须**逐条显式标注**「静态判据」；当该维度只有静态判据支撑时，得分上限为**中位分 12/25**。
要拿满 25 分，必须有真实执行的命令与真实输出。
同一评审连续 3 轮未 PASS（返工也计入）→ 停止循环、升级人类。

## 6. 产物目录约定（抗上下文腐化）

```
docs/plans/<需求代号>/
  task-board.md        任务板快照 —— **硬要求：每阶段落一次盘**（不止开工时）
  impact-map.md        影响面/拆解
  artifacts/           各岗位产物（子代理只回路径，不回正文）
  score-round-<n>.md   各轮评分记录（含 sha256 指纹）
  review.md            最终评审结论
  retrospective.md     复盘
```

**硬要求**：`task-board.md` 不是「可选目录约定」，而是**每阶段落一次盘**的强制产物；
冷恢复（会话恢复/压缩）后必须重新落盘一份对账后的快照。
**原则**：承重内容落盘；子代理回「路径 + 关键行号 + 一句话结论」，不回大段正文。

## 7. 反模式（动态团队特有，逐条对照）

| 反模式 | 后果 | 正确做法 |
|---|---|---|
| 想到就 spawn，先建人后建任务 | 职责重叠、重复劳动 | **先任务板，后招人** |
| 两个任务写同一路径 | 决策碎片化、互相覆盖 | write scope 互斥；看到 `writeScopeWarnings` 立刻调整 |
| 用 shell 重定向/formatter/codegen 改文件 | 绕过文件版本守卫 | 一律 read/edit/write；需要时建独占写作用域任务并授权 |
| write scope 写成绝对路径（`F:\...` / `/abs/...`） | 必报 `TEAM_INVALID_WRITE_SCOPE` | 改成工作区相对 POSIX 前缀（见 2.6） |
| 对 inactive 成员连续发消息 | 撑爆 mailbox → `TEAM_MAILBOX_FULL` | 合并成一条摘要，或先唤醒/等待其消化 |
| 中断/换人后不 `release` owner | 任务永久 in_progress、无人能领 | `reopen` → `release`/`reassign` → `send_message` 唤醒新 owner |
| 任务板不落盘 | 压缩/恢复后事实源丢失 | 每阶段落一次 `task-board.md`（硬要求） |
| Lead 自己不上板 | 任务板只记别人，工作量与归属不可核对 | Lead 的工作也 `claim`→`complete` |
| 压缩/恢复后不重新对账 | 认领状态与真实现场不一致 | 执行冷恢复 4 步：`list_agents` → 处置 provisioning/failed → `team_task_list` → 落盘快照 |
| 用 workflow 写工作区 | 子代理不进 roster、不受 write scope 约束 → 协议旁路 | workflow 只做只读 fan-out，并发 ≤ 5、产物落盘、计入预算 |
| 依赖满足后干等 | 永久卡住（依赖不唤醒人） | 完成者 `send_message` 唤醒下游 owner |
| 把 `inactive` 当「做完了」 | 提前汇报、漏等成员 | `team_task_list` 看任务状态，不是看成员状态 |
| 重发 `queued` 消息 | 重复劳动 | `queued` = 已存储，不要重发 |
| 执行者自己评自己 | 回音室、假 PASS | 换一个 teammate 或 Lead 亲验；只给产物 |
| 让 teammate 转述大段内容给你 | 上下文爆炸 | 让它落盘，只回路径 |
| 指望 owner 自动释放 | 任务永久 in_progress | 显式 `complete`/`release`/`reassign` |
| 招人接近上限还继续招 | `TEAM_MEMBER_LIMIT`，浪费名额 | 先收敛任务、复用现有成员；上限表述见第 9 节 |
| 会话恢复后假装无事发生 | 假 PASS、重复劳动 | 冷恢复 4 步 + 如实报告中断影响 |

## 8. 最终答复前的自检（Lead 逐项过）

- [ ] 冷恢复 4 步已执行（若本轮发生过恢复/压缩）：`list_agents` → 处置 `provisioning`/`failed` 成员 → `team_task_list` → `task-board.md` 落盘
- [ ] `team_task_list` 里没有「应该完成却还 in_progress」的任务
- [ ] Lead 自己的任务也已 `claim` → `complete`（任务板不只记别人）
- [ ] 所有必需成员都结束（不是 `running` / `provisioning`）
- [ ] workflow 用量为 0，或已声明用途且仅为只读 fan-out（并发 ≤ 5、产物落盘）
- [ ] 我**亲自**看过最终 diff，并跑过验收命令
- [ ] 每条汇报结论都标了依据/证据等级，reject 点与推定（若有）均已显式注明；没有把未实测写成已通过
- [ ] 产物已落盘，路径在回复里给出（长输出先落盘再引路径）
- [ ] 越界改动（写作用域外）为零，或有显式说明与人类确认
- [ ] 没有 `TEAM_*` 报错被静默吞掉；出现过的报错都已按第 2 节处置并说明
- [ ] 任务板快照是最新的（每阶段落一次，不是只有开工那一次）

## 9. 容量与限额速查

| 项 | 值 | 依据 |
|---|---|---|
| `maxMembers` | 实现默认 **16**；本机 desktop/web profile 配置为 **8** | 源码默认值 + profile 配置（源码） |
| `maxTasks` | **256**（活跃任务上限；删除后为 tombstone，不占额度、不出现在 list） | 官方限额表 + 源码注释（文档） |
| `maxPendingMessagesPerMember` | **64**（同一成员待处理消息上限；已有 64 条未投递时，后续 `send_message` 被拒 → `TEAM_MAILBOX_FULL`） | 官方限额表 + 源码（源码） |
| `maxMessageBytes` | **65,536**（按 `deliveryContent` 的 JSON 字节计，超限 → `TEAM_MESSAGE_TOO_LARGE`） | 官方限额表 + 源码（源码） |
| `disposalTimeoutMs` | **5,000**（关闭清理上限） | 官方限额表（文档） |
| `wait_agent.timeout_ms` | 10,000 – 3,600,000，默认 30,000 | 工具 schema（源码） |
| 成员名正则 | `^[a-z0-9]+(?:-[a-z0-9]+)*$`；`lead` 为保留 target（Lead 自身，不是 teammate） | 源码 `MEMBER_NAME` 常量（源码） |

**表述纪律**：**本机 profile 配置为 8；实现默认 16；以运行时为准**。
不得把「8」写成 preset 的机械上限。接近上限即收敛任务、不再招人。

## 10. 证据等级与判定

**三分（不得混写，每条结论只属于其中一类）**：

1. **真实文件级行为验证** —— 在被测的真实文件/真实环境上执行并观察到的结果。
2. **构造级等价验证（副本）** —— 在副本/等价构造上验证；必须说明副本与真身的差异与等价性依据。
3. **静态判据** —— 只读源码/文档/配置得出的断言，未实际执行。

**标注纪律**：

- 手册中出现「实现如此」的断言时，必须按其依据标注：`源码` 只表示读到抛出 / reject 站点或其分支（**≠ 在真实会话里触发过**），`命名推定` 必须显式标注为推定，**不得写成实测**（第 2 节依据列即为此设）。
- 把「未实测」写成「已通过」= 呈现不实，属造假证据 → rubric 直接 FAIL。
- 计数类结论须独立对账；计数为 0 且对账不支持时必须判 UNCERTAIN。
- 长验收输出先落盘为文件，再在汇报里引用路径（工具结果会被截断）。
- **依据列出处**：2026-10-03 对照 `@deepseek-ai/dsh-experimental-agent-team@0.2.0-rc.2`（app.asar 内 `lib/types/*.js` 可读源码）逐条复核；站点存在属**静态判据**，**未在真实会话中触发**；其中 `TEAM_DISPOSAL_TIMEOUT`、`TEAM_WAIT_ABORTED` 为 Promise reject 点。
