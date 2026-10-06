# dsh-taskforce · 专案组

> **Task-board-first dynamic Agent Teams for DeepSeek Harness.**
> Muster a team for one task, dissolve it when the task is done.

一个 DSH Agent preset：Lead 不写死岗位，
而是**先建任务板任务 → 按需招募 teammate → 用消息与等待推进 → 亲自验收**。

**名字的由来**：`taskforce` 指为**一个具体任务**临时编队、任务结束即解散 ——
这正是动态编制相对静态固定角色的根本差别。中文名叫「专案组」。

> ⚠️ **非官方项目**：本项目是第三方 DSH preset，与 DeepSeek **无隶属关系**，未经其审核或背书。
> 文档中出现的 `@deepseek-ai/dsh-*` 名称仅用于说明依赖关系。
>
> 仓库：<https://github.com/smartKitMe/dsh-taskforce> · License: [MIT](LICENSE) · 版本 1.1.0

本 bundle 只声明一个 preset，内容分三层：

| 层 | 载体 | 内容 |
|---|---|---|
| 承重规则 | `cordis.patch.yml` → `persona.prefix` | 组队准入、任务板先行、写协议、唤醒纪律、委派契约、验证独立性、预算终止、workflow 治理、安全红线 |
| 操作手册 | `skills/agent-team-protocol/SKILL.md` | 工具速查、28 个错误码、五个岗位模板、六要素契约、评分 rubric、反模式、自检清单 |
| 工具面 | `cordis.patch.yml` → `plugins` | shell / 文件 / 检索 / 后台 / skill / goal / 计划 / 压缩 / 交互 —— **刻意不含任何 Team 行，也不含 subagent 行** |

## 工具面：什么被禁用，什么仍在（重要）

Team 工具面由 **profile 层**提供（见下节）。本 preset 复用 profile 的 Team 层，同时这带来两个必须说清的事实：

1. **`subagent` / `subagent_fork` 及同名全局控件被 profile 禁用。**
   在启用 Team 层的 profile 里，进程内子代理工具（以及 `tool-subagent-control` 之类同名控件）
   不再暴露给会话 —— 否则它们会与 `spawn_teammate` / `send_message` / `list_agents` 等 Team 工具同名冲突。
   所以本 preset 的并行编制只有一条正路：**共享任务板 + `spawn_teammate` 具名 teammate**。
2. **`workflow` 仍保留 spawn provider —— 这是本 preset 最需要治理的旁路。**
   `workflow` 的 `agent()` 子代理**不进 roster、不占 `maxMembers`、不占任务板、不受 `write_scopes` 协议约束**，
   也不出现在 `list_agents` 里。它是一条绕过全部团队协议的并行通道。

`workflow` 治理规则（persona 与手册一致）：

- 会写工作区的活**禁止**用 workflow；
- 只允许**只读 fan-out**（检索、多角度阅读、对抗性核对）；
- 一次 workflow 的并发子代理数**上限 ≤ 5**；
- 产物**必须落盘**，并计入本轮预算（预算口径 = 消息条数 / 轮次 / 并发 running 成员数 / workflow 子代理数）；
- 违反以上任一条，即视为**绕过本协议**。

## 前置条件（重要）

Team 运行时（域服务 + 9 个工具 + Web UI）由 **profile 层**提供：

```
@deepseek-ai/dsh-experimental-agent-team-profile
```

本 bundle **刻意不重复声明** `agent-team` / `tool-agent-team`：同一进程重复挂同一服务会撞 realm，
且 Team 工具与全局 subagent 控件同名。所以：

- profile 已装该层 → 会话里有 `spawn_teammate` / `team_task_*` / `send_message` / `wait_agent` /
  `interrupt_agent` / `list_agents`，本 preset 即全功能。
- profile 未装 → 会话里没有这些工具。persona 第十条是**降级条款**：停止组队、如实告知、单 agent 完成。
- 该层还需要**持久会话存储**才能激活（`@deepseek-ai/dsh-session-persistence-jsonl`）。

DSH 自带的 `desktop` / `web` profile 通常已包含该层（本项目的核对记录即基于这两个 profile）。

## 安装（三步：`install_bundle` → `link-skills` → `validate`）

安装动作**只有** `install_bundle` 一个；后两步是补充（junction 镜像、静态校验），不是安装包。

### 1) `install_bundle`：`target` 指向**工作区**里的 bundle 目录

```
plugin_manager: install_bundle   target=<本仓库的绝对路径>   # 例：D:\src\dsh-taskforce
```

- `target` 必须是**工作区里的 bundle 源码目录**（即上例），**不要**指向
  `%DSH_HOME%\agent-preset-bundles\dsh-taskforce` 这个镜像路径。
- 改 profile 的 `package.json`、跑 pnpm、把本 bundle 登记进 `bundles` 列表，**全部是 `install_bundle` 的职责**。
- 所以**不要手工改 profile 的 `package.json` / `cordis.patch.yml`，不要手工在 `$DSH_HOME` 下创建包，
  也不要在 profile 目录手跑 pnpm** —— 手工插手会绕过 `install_bundle` 的登记与依赖解析，
  产出"文件写了但 Loader 不认"的僵局。（以上是加载体 / `plugin_manager` 安装说明的含义复述。）

### 2) `link-skills.ps1`：为 skills 路径建立 junction（定向 workaround，不是安装）

```powershell
# 在 bundle 目录下执行
powershell -NoProfile -File scripts\link-skills.ps1
```

- **为什么需要**：`cordis.patch.yml` 里的 skill 目录写的是
  `customSkillDirs: - !!js dshHomePath('agent-preset-bundles/dsh-taskforce/skills')`，
  它**必然**解析到 `%DSH_HOME%\agent-preset-bundles\dsh-taskforce\skills`
  —— 这是 DSH 既有的 `dshHomePath('agent-preset-bundles/<bundle>/skills')` 约定，**不是**工作区源码目录。
- **脚本做的事**：把该镜像路径建成**指向工作区源码目录的 junction**，让上面的路径表达式可解析，
  同时保持**单一事实源**。这是为匹配既有 `dshHomePath(...)` 约定的**定向 workaround**；
  `install_bundle` 不负责这条路径，因此它**不是安装动作**。
- **幂等**：已存在且指向正确 → no-op 并打印 `OK`；若该路径是**真实目录副本**（非 junction）→
  报 `CONFLICT` 并要求人工决策（备份 + 重建），**不静默覆盖**；
  `%DSH_HOME%` 未定义或是相对路径 → 退出码 2，不猜测、不退化成根目录路径。
- `-Check`（只检查：正确链接 = 退出码 0，缺失/指错 = 1）与 `-WhatIf`（只打印计划，不落盘）。
- **不要用复制（`Copy-Item`）维护第二份副本。** 两条理由都是**静默**故障：
  1. **静默漂移**：改了工作区源码里的 `SKILL.md`，会话读到的仍是旧副本，没有任何报错；
  2. **静默降级**：skill 缺失时 preset **仍能正常加载**（协议退化为 persona 内的规则），表面无错、实际手册没生效。

  缺镜像不会让 preset 失效，但会让你**以为**手册在生效 —— 这正是必须用 junction 而不是复制的原因。

### 3) `validate-preset.ps1`：静态校验

```powershell
powershell -NoProfile -File scripts\validate-preset.ps1
```

逐项打印 `PASS/FAIL <id>`（V1–V12），任一 FAIL 则退出码 1。
注意 **V12 要求交付目录内不存在 `.work/`**，所以集成收尾（删除 `.work/`）之前 V12 FAIL 是**预期**的，不是缺陷。

### 装完重载

改完 patch 后让 Loader 重读，并**新开会话**才生效：

```
plugin_manager: set_bundle   target=dsh-taskforce   enabled=false
plugin_manager: set_bundle   target=dsh-taskforce   enabled=true
```

关于热重载，两个 profile 的配置**不同**：

- `web` profile 显式开了 `patchReload: live` → patch 改动可以热重载；
- `desktop` profile **没有**开 `patchReload: live` → patch 改动必须**新开会话**才生效。

## 验证

| 检查 | 期望 |
|---|---|
| `plugin_manager: list_bundles` | 出现 `dsh-taskforce`（应来自 `install_bundle` 的自动登记；profile 的 `package.json` / `bundles` 不由手工编辑） |
| `plugin_manager: list_plugins` | 出现 `preset-dsh-agent-team`，`enabled: true`、`fiberPhase: active` |
| 新会话 → Agent 预设 | 出现「动态团队」 |
| 该会话工具列表 | 9 个 Team 工具齐全（`spawn_teammate` / `team_task_*` / `send_message` / `wait_agent` / `interrupt_agent` / `list_agents`） |
| 该会话 skill 列表 | 出现 `agent-team-protocol` |
| 镜像路径可解析 | `Test-Path "$env:DSH_HOME\agent-preset-bundles\dsh-taskforce\skills\agent-team-protocol\SKILL.md"` 为 `True`，且该路径是 **junction**（`(Get-Item ...).LinkType -eq 'Junction'`），不是第二份真实副本 |
| 静态校验 | `powershell -NoProfile -File scripts\validate-preset.ps1` 逐项 `PASS/FAIL`，退出码 `0`；**V12 需要交付目录已无 `.work/`**，故集成收尾前 V12 FAIL 属预期 |
| 负向校验 | `scripts\link-skills.ps1 -Check`：镜像缺失或指错时应以退出码 `1` 报 `CHECK FAILED`，而不是静默通过 |

## 可选：静态守卫岗（补回机械权限）

动态团队的硬缺口：**`spawn_teammate` 不能给 teammate 设工具白名单**。
因此「评审/探索必须只读」在纯动态方案下只是协议约束，不是机械保证。

若某个岗位需要**机械**只读（这是静态编制最大的优势），按下面的片段在
`cordis.patch.yml` 的 `plugins` 里（`present` 行之前）追加一条带 `toolFilter` 的固定岗位行：

```yaml
          # 静态守卫岗：机械只读（无 write/edit），用于必须独立且不许改动的评审
          - id: tool-subagent-guard-review
            name: '@deepseek-ai/dsh-tool-subagent'
            config:
              provider: spawn
              toolName: subagent_guard_review
              backgroundMode: continuable
              maxDepth: 1
              toolFilter:
                allow: [pwsh, read, glob, grep, job_list, job_output, job_kill, todo_write, skill]
              persona: |-
                你是独立评审员。你只报告，不修改：任何文件写入都不是你的产出。
                证据等级三分不得混写；不确定就判 UNCERTAIN。
```

这样形成**混合编制**：机械必须保证的（评审、只读探索）走静态岗位行，
需要灵活组队的（多路探索、并行实现、文档）走动态 teammate。

> 已知实验性限制：进程内一次性子代理在发布后才获得 subagent descriptor，
> Team 安装可能**短暂**把它们误认作 Lead 并暴露 Team 策略与工具；descriptor 识别出非成员后，
> 相关调用会被拒绝。

## 已知限制（设计时必须接受）

- **写作用域只是提示**，从不阻止任何操作；Bash / formatter / codegen 会绕过文件版本守卫。
- 所有成员**共享同一个 cwd**，没有 worktree、没有文件锁、没有 merge 冲突检测。
- **并行编制容量**：`maxMembers` 本机 profile 配置为 **8**、实现默认 **16**，**以运行时为准**
  （接近上限即收敛任务、不再招人，不要按"固定名额"做规划）；招人超限报 `TEAM_MEMBER_LIMIT`。
  其余限额：活跃任务 `maxTasks` **256**（删除后为 tombstone，不占额度）、单成员待处理消息
  `maxPendingMessagesPerMember` **64**（超限 `TEAM_MAILBOX_FULL`）、单条消息
  `maxMessageBytes` **65,536**（超限 `TEAM_MESSAGE_TOO_LARGE`）、关闭清理上限
  `disposalTimeoutMs` **5,000**。
- **workflow 旁路**：`workflow` 的 `agent()` 子代理不进 roster、不占 `maxMembers`、不占任务板、
  不受 `write_scopes` 约束（治理规则见上文「工具面」）。它不会出现在 `list_agents` 里，
  因此**无法靠 roster 对账发现**，只能靠声明与落盘产物核对。
- **任务板是 Lead 会话 log 的派生视图**：`team_task_*` 的状态活在 Lead 所在会话的日志/上下文里，
  **会话外不可见**（换会话、换进程都看不到同一块板）。需要跨会话留痕时，必须按协议把任务板快照
  落盘到 `docs/plans/<代号>/task-board.md`。
- 成员名**永久占用不复用**，roster **扁平不可变**（不支持嵌套 Team）。
- 任务 owner **不会自动释放**：不活动、被中断、失败都不释放。
- 单进程；**mailbox 不保证跨进程 exactly-once**（`queued` 表示已安全存储，不代表跨进程去重）。
- **实验性，无稳定性承诺**，schema 可自由变更。

## 核对记录

| 项 | 值 |
|---|---|
| 核对对象 | `@deepseek-ai/dsh-experimental-agent-team@0.2.0-rc.2`（同版本 `dsh-experimental-tool-agent-team`、`dsh-experimental-agent-team-profile`） |
| 核对日期 | 2026-10-03 |
| 核对方式 | **静态判据**：读取实现与官方 README/JSDoc；并读本机 `desktop` / `web` 两个 profile 的配置文件 |
| 启用状态 | 本 preset **当前不在 `desktop` / `web` 任一 profile 的 `bundles` 列表里**（两个 profile 都含 `@deepseek-ai/dsh-experimental-agent-team-profile`）；启用方式见「安装」段 |
| 热重载差异 | `web` 开了 `patchReload: live`；`desktop` 未开，需新开会话 |
| 依据标注纪律 | 手册「依据」列逐条标注 `源码` / `文档` / `命名推定`（当前分布 **22 / 6 / 0**，无推定项）：`源码` 只表示"在实现中读到抛出 / reject 站点"，**不等于**在真实会话中触发过；不得把推定写成实测 |

## 与「固定角色」类 team preset 的差别

不少 team preset 走**静态编制**：角色是 preset 里写死的插件行，权限由 `toolFilter` 机械保证。
本项目走**动态编制**，取舍写在明面上 —— 不要指望它提供机械保证：

| 维度 | 静态编制（固定角色行） | 本项目（动态招募） |
|---|---|---|
| 角色定义 | preset 里写死，改角色 = 改配置 | 运行时按任务创建；`spawn_teammate` 只有 `name` / `description` / `prompt` / `context` 四个参数 |
| 权限边界 | `toolFilter` **机械**只读 | `write_scopes` + 协议纪律 + Lead 抽查（**提示性**，从不阻止操作） |
| 并行容量 | 静态行数固定 | 受 `maxMembers` 约束，可运行时收敛 |
| 代价 | 改需求要改配置 | 全靠协议纪律；纪律一松就是裸奔 |

需要机械只读的岗位，用下面「可选：静态守卫岗」把固定岗位行补回来，形成**混合编制**。

## License

[MIT](LICENSE)。第三方项目，详见文首免责声明。

## 卸载

```
plugin_manager: remove_bundle   target=dsh-taskforce
```
