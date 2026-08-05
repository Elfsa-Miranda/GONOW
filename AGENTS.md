# GoNow 仓库级执行宪章

> 文档：`AGENTS.md`  
> 版本：`3.0.0-personal`
> 目标架构：`GoNow_Industrial_Multi-Agent_and_Database_RAG_Architecture_Design_Remote_Main_v1.6.1.docx`  
> 目标架构 canonical locator：`D:\gonow\deliverables\GoNow_Industrial_Multi-Agent_and_Database_RAG_Architecture_Design_Remote_Main_v1.6.1.docx`（用户提供的本轮只读输入；路径本身不构成不可变身份）  
> 目标架构 artifact SHA-256：`644ab9f5ad04a65383bb34b6628b49472d9f68b50fa3681aa46671f59794c3a6`  
> 目标架构 artifact owner：`Architecture + Product`；本 hash 版本 MUST 至少保留到 Release C/所有依赖 ADR 退役并满足组织保留政策。BOOT 阶段 MUST 建立获批不可变对象 URI/version；未建立前其状态为 `unknown`，不得用同名文件替换  
> 任务指定远程：`https://github.com/Elfsa-Miranda/GO_NOW.git`  
> 基础分支：`main`  
> 本次核验 `BASE_SHA`（固定远程基线的不可变提交）：`142abfc339f003ede8d85d9534336923b5610252`  
> 基线提交：`2026-07-18T23:33:34+08:00`，`Update README.md`  
> 生成时间：`2026-07-31T01:11:04+08:00`  
> 本次执行治理修订：`2026-08-05T13:30:00+08:00`
> 采纳状态：`active_personal_automated_governance`；仓库 owner 已在本轮明确授权 §0.4.3 的个人项目自动门禁、阶段 push/merge、owner-only canary 与机械 acceptance。所有授权仍受候选 OID、最小权限、成本上限、kill switch、零安全红线和可逆性约束
> 默认时区：`Asia/Shanghai`

## 0. 文档目的、适用范围与术语

本章解决“以什么为准、哪些话是事实或目标、Agent 应如何解释规则”的问题。

### 0.1 权威、范围与规范等级

本文件是仓库级执行宪章，规定“GoNow 是什么、允许做什么、怎样证明合规”。用户口语中的 `agents.md` 均指根目录这个大写文件。未来的 `execplan.md` 是阶段执行计划，只规定“先做什么、任务如何排列、何时合并”；它 MUST 精确引用本文件的稳定章节号，不得复制、弱化或改写硬约束。

冲突时按下列顺序裁决：

1. 用户本轮明确要求和安全限制。
2. 本文件中已经批准的 `Hard Constraint`。
3. 用户已确认为最终目标的 v1.6.1 架构合同。
4. 执行时重新 `fetch` 得到的 `origin/main` 代码事实。
5. 仓库锁文件、迁移、测试、CI 与运行配置。
6. 官方一手资料。
7. 参考模板和历史建议。

v1.6.1 是最终要实现的总架构，但不是当前实现证明。其目标边界按 `Target Contract` 执行；主线尚不存在的代码、表、服务或能力一律不得写成“已实现”。若架构正文中的历史 `Proposed` 与本文件冲突，以用户本轮确认后的本文件为准；若实施者要偏离 v1.6.1，则 MUST 先提交 ADR（记录架构取舍与批准的决策文档）并取得相应 owner 批准。

规范词含义如下：

- `MUST`：必须做到；缺失即不合规。
- `MUST NOT`：绝对不得做；违反即停止。
- `SHOULD`：原则上应做；偏离必须写明证据、风险与 owner。
- `MAY`：满足前置门禁后可以选择，不代表默认启用。

四类陈述不得混用：

- 现在可由指定提交的文件、命令或测试证明，叫 `Current Fact`。
- 最终方案要求未来落地，但主线尚未具备，叫 `Target Contract`。
- 需要真实流量、账单或样本校准的阈值，叫 `Initial Hypothesis`。
- 任一阶段都不能放宽的边界，叫 `Hard Constraint`。

### 0.2 核验边界

本次已执行 `git fetch --prune --tags origin`，并确认远程默认引用 `origin/HEAD → origin/main`。控制仓实际 `remote.origin.url` 为 `https://github.com/Elfsa-Miranda/gonow.git`，与任务指定的 `https://github.com/Elfsa-Miranda/GO_NOW.git` 在仓库名大小写及下划线形式上不同；当前 fetch 成功不等于两者可无条件互换。新控制仓 MUST 使用任务指定 URL，并做区分大小写的精确比较；若服务端重定向或组织 owner 确认 canonical URL 已变化，先把输入 URL、最终 URL、重定向证据和 owner 决定写入 baseline/ADR，不得静默改源。本次仓库工作目录有用户拥有的 untracked 内容，且本地 `main` 落后远程，因此所有 `Current Fact` 均来自 `origin/main` 的 Git 对象，不来自工作树。这里记录的 `BASE_SHA` 只约束本文生成证据；未来任何 Phase 开始前 MUST 重新 fetch 并记录新的不可变 SHA。

### 0.3 术语

下列术语先给日常解释，再给技术名称：

- 现在能拿文件或命令证明的事实——`Current Fact`。
- 最终要建成但现在还没有的合同——`Target Contract`。
- 先试用、上线后再用数据修正的数字——`Initial Hypothesis`。
- 不因进度、成本或故障而降低的底线——`Hard Constraint`。
- 一段有独立范围、分支和验收的施工阶段——`Phase`。
- 机器或明确 owner 能判定通过/失败的检查——`Gate`。
- 对决定和证据承担责任的人——`owner`；实施 Agent 不是批准者。
- 记录重要架构取舍、方案比较与批准的文档——`ADR`。
- 一次可持久恢复的 Agent 执行——`Run`。
- 多次 Run 共用的用户会话容器——`Thread`。
- AI 只能先交出的待确认草案——`Candidate`。
- 经权限、版本和审批后写正式数据的命令——`Domain Command`。
- 只有版本仍符合预期才允许写入——`CAS`（compare-and-swap）。
- 让旧 Worker 即使复活也不能写的代际令牌——`fencing token`。
- 数据库按当前主体限制行访问的最后防线——`RLS`（row-level security）。
- 进程崩溃后仍能领取和恢复的任务——`durable job`。
- 保存最小可恢复状态的持久点——`checkpoint`。
- 把 Graph、Prompt、Tool、Model、Schema、Eval 和预算固定在一起的发布单元——`Behavior Package`。
- 能说明事实来源、时间、版本与可信状态的记录——`Evidence`。
- 高风险动作让人看见差异后明确批准——`HITL`（human in the loop）。
- 服务端按序推送并支持断线续传的事件流——`SSE`。
- 从有来源、版本和权限的知识中检索证据——`RAG`。
- 跨系统标准化暴露工具的可选协议边界——`MCP`。
- 用失败样本、分层评测和灰度证据驱动发布——`EDD`。
- 与业务事务一起写入、随后可靠投递的事件箱——`outbox`。
- 事故时立即切断新路径的总开关——`kill switch`。
- 失败后只修受影响局部且限制次数——`bounded repair`。

### 0.4 修订规则

- 本文件使用语义化版本。删除或放宽安全边界、公共接口、状态机、数据用途或数据库事实源属于 `MAJOR`；增加兼容阶段或门禁属于 `MINOR`；不改变语义的措辞和证据路径修正属于 `PATCH`。
- 公共 API、Event/State Schema、RLS/授权、正式写链、删除链、事实源、进程边界、外部数据用途、Release 范围或 v1.6.1 偏离均 MUST 有 ADR。ADR 至少比较安全、数据、兼容、成本和回滚，并由工程 owner 与相关安全/产品/数据 owner 批准；格式与证据要求见 §16。
- 以下任一情况都 MUST 在实现前建立 ADR，不得等到验收时补写：新增 §3 已批准技术线之外的生产直接依赖或进程边界；新增业务表或改变主键、RLS、Event/State Schema；改变 §5 的安全失败方式；增删或实质修改 Phase mandatory gate/non-goal；改变已发布 OpenAPI、SSE 或 Dart 合同；提前/推迟 Release 能力；改变 §6.1 任一运行时不变量；改变外部数据用途、保留、驻留或删除语义。完整触发清单以 §16.1 为准。
- 同一依赖的兼容 patch 升级、仅测试使用且不进入产物的工具、文档排版或不改变合同的内部重命名通常不需要 ADR，但仍 MUST 在 TASK 与依赖审计中说明理由。无法确定是否触发时先按“需要 ADR”处理，由相应 owner 书面裁决。
- 本文件变化若影响任务顺序、DoD、依赖、命令、分支或证据，MUST 同步评估 `execplan.md`；硬约束变化先合并本文件与 ADR，再改执行计划。
- `1.2.0` 候选修订记录：增加逐 TASK CAS 状态账本与稳定 `docs/execution/status/` 目录，限定 089 的 Harness Catalog CAS 聚合和派生看板写入，修正 baseline 归档路径；影响 `execplan.md` 的 status Schema、write-set、BOOT 物化和 089/990/999 门禁，不改变 v1.6.1 产品能力、Release 范围或生产数据用途。本记录不冒充批准；采纳时必须保存 Architecture+Product 及受影响 Security/Data owner 的决策引用。
- `1.3.0` 候选修订记录：消除 BOOT 工具先后循环，增加 Gate/PhaseMerge mode 注册与 Catalog 结构校验，明确治理采纳 receipt 的可执行解锁输入与 BOOT-001/002 内容寻址断点续跑，并移除未供应的 `ConvertFrom-Yaml` 隐含依赖；这是兼容性执行门禁增强，不改变 v1.6.1 产品能力、Release 范围或生产数据用途。`1.3.0` 重新冻结后，任何旧版本采纳 receipt 均不得沿用。
- `1.4.0` 候选修订记录：把治理采纳从“创建控制仓前的全局锁”调整为“正式合并、推送、生产写和 Release acceptance 前的治理门”，增加本地 provisional bootstrap、机械证据依赖、自诊断/自修复、替代路径和局部阻断规则。该修订不放宽 secret、跨租户、生产写、数据丢失、不可逆操作等 Hard Constraint；它只消除等待外部批准或工具时对全部安全本地工作的无差别停工。
- `2.0.0-personal` 修订记录：在完整保留原 enterprise governance、五档生产观察和独立 owner 审批合同的同时，为本个人项目启用 §0.4.3 的自动治理 profile；以 C1–C5 高密度压缩认证加最终 owner-only production canary 替代 Release B 的 31 天日历等待，并允许门禁通过后自动 accepted、阶段 push/merge 和受限 Release 操作。该修订改变 Release acceptance、批准与灰度时间硬约束，属于 `MAJOR`；不放宽 secret/PII、跨租户、任意 SQL/Tool、未经 Domain Command 的正式写、数据丢失、不可逆删除、force-push 或安全红线。
- `3.0.0-personal` 修订记录：仅对当前已进入 landing 的 Phase 12D、12B、12A 建立一次累计 Release C 收口例外，按 `P12D → P12B → P12A` 保留历史和证据并作为同一候选接受；P12C 继续 dormant。该修订以 `ADR-P12-003-cumulative-release-c-close.md` 和仓库 owner 本轮明确授权为依据，取代旧 P12 XOR/单能力发布限制，属于 `MAJOR`。它不授权 Multi-Agent、生产部署、生产数据写入、流量分配、force-push、直接 push main 或弱化 RLS/CAS/删除恢复/安全红线。
- 子目录未来可以有更严格的 `AGENTS.md`，但 MUST NOT 放宽本文件。根文件是唯一仓库级权威。
- 批准本文件表示认可实施合同，不表示任何 Phase 已完成；完成状态只能由对应提交、机器证据、回滚演练和适用 profile 的 acceptance 共同证明：enterprise 使用独立 owner，current personal 使用 §0.4.3 自动 attestation。

### 0.4.1 持续推进、自修复与局部阻断

本仓执行采用 `progress-first, evidence-honest`：优先完成目标、持续修复，但绝不把未验证结果伪装为通过。任务卡中的 `blocked`、`不得开始`、`后继停止` 和 `fail closed`，除 P0 事故、正在发生的 secret/PII 暴露、跨租户访问、生产写、数据丢失、不可逆外部动作或用户明确要求全停外，默认只约束“当前失败的最小动作”，不得被解释为整个工程停止。

- Agent 遇到失败后 MUST 先读取真实错误、检查输入/环境/依赖和最近 diff，实施最小可逆修复并重跑受影响检查；只要仍有新的诊断信号或安全替代路径，就继续修复，不得用一句“缺条件”结束任务。
- 文档存在歧义、路径漂移或卡片细节与仓库事实不一致时，Agent MUST 按用户目标、v1.6.1 和最小变更原则选择可逆解释，记录 `assumption/impact/rollback`，同步修正文档或任务合同后继续。只有会改变产品语义、生产数据或不可逆边界的歧义才要求用户决定。
- 工具、凭据、外部服务或 reviewer 暂不可用时，Agent MUST 继续所有不依赖该条件的本地代码、合同、fixture、静态检查、fake/隔离测试、文档和证据工作；可安全安装或供应本地工具时自行完成，可用兼容替代实现时采用并明确标记能力差异。不得把 mock/fake 冒充生产验证。
- 一个 TASK 真正等待外部条件时，状态可为 `blocked`，但 coordinator MUST 立即选择下一个依赖已满足的安全任务；若严格 DAG 没有 ready task，则可创建不改变目标合同的 `repair/enabler` 子任务，先解决工具、脚本、fixture、路径或计划缺口。等待外部批准不得让 Agent 空转或反复请求同一信息。
- `ready_for_review` 且机械门禁通过的候选，在 `local_provisional` 模式下可满足后续本地实现的依赖；它不等于 `accepted`。enterprise governance 下的远程 push、PR 合并、生产与 Release acceptance 仍须正式 owner 批准；本仓当前启用的 personal automated governance 则只按 §0.4.3 的候选绑定自动授权执行。
- 依赖正式 BOOT-005 的本地 P00 入口可由 BOOT-003 native pass 暂代，缺失能力按任务补齐；依赖上一 Phase `999`/Release accepted 的下一 Phase 本地入口可由上一 Phase `990 ready_for_review + mechanical gates passed + provisional checkpoint OID` 暂代。该投影不改变正式集成依赖。
- 只有所有剩余工作都依赖同一个无法由 Agent取得的外部授权/秘密，且没有安全的实现、测试、修复、模拟、文档或证据工作可继续时，才可暂停整次执行。暂停报告必须只列精确缺项、已完成的修复尝试、可立即执行的 owner 动作和恢复命令，不得笼统拒绝。

enterprise governance 的正式采纳仍使用目标控制仓之外的只读 `governance-adoption-v1.json` 及预期 SHA-256。receipt 采用 `execplan.md §0.3.0` 的规范结构，绑定本文件、本计划、目标架构及 Architecture、Product、Security、Data 四个不同 `actor_id` 的真实决定；Agent 不得伪造批准。本个人项目启用 §0.4.3 后不要求虚构这些互相独立的自然人；改由一次性 owner 授权、版本化 ADR、候选绑定的自动门禁 attestation 和完整机械证据承担同一审计职责。任何 profile 都不把 receipt 当作本地实现、测试、修复或候选证据的前置。

未提供 receipt 时，BOOT-001 MUST 自动进入 `local_provisional`，校验并封存两份 guidance 与架构 docx 的实际 bytes/hash，创建控制仓和独立 worktree并继续；不得因缺少 `GovernanceReceiptPath` 或 `GovernanceReceiptSha256` 返回全局 `not_started`。enterprise receipt 后续可用时，BOOT-004 将其作为新增、不可覆盖的正式治理证据复核并把 enterprise 模式升级为 `formal_adopted`；升级不得改写此前 sealed bytes、base SHA 或机械测试历史。BOOT-004 未升级只使 enterprise 的正式合并/推送/生产/acceptance 保持 pending；current personal profile 改由 §0.4.3 的 adoption/attestation 链解锁其明确动作，两种情形都不阻止安全本地工程推进。

新控制仓的远程基线不假定已经包含本文件或 `execplan.md`。BOOT-001 必须把两份 guidance 和架构 docx 的已验证 bytes 原样、原子封存到 control repo `.git/gonow-bootstrap/inputs/`；`formal_adopted` 模式再追加 governance receipt，manifest 因而明确记录 `bootstrap_mode` 与 `sealed_input_count=3|4`。该目录不入 Git、禁止覆盖，只作为 BOOT 的 content-addressed 只读输入。BOOT-001/002 每一步必须可在进程中断后安全重入；冲突内容不得覆盖或删除，但 Agent 应先尝试复用完全一致状态、选择新的空任务路径或修复可验证的局部问题，只有用户文件、reparse point 或身份不明的外部对象无法安全避让时才暂停该动作。已形成 BOOT-001 receipt 后，所有重跑与 BOOT-002 使用其中固定 `base_sha`，不得因后续 `origin/main` 漂移改变基线。

`TASK-BOOT-003` 是唯一 guidance materializer：它从 sealed manifest 读取两份 guidance bytes；目标不存在时以同目录临时文件、原子 rename 和写后 hash 逐字物化，目标已存在且 hash/size 完全相同时幂等 no-op，已存在但不同则保留文件、诊断来源并改用新的干净 worktree，不得覆盖用户内容。为防 Windows `core.autocrlf` 改变身份，BOOT-003 在根 `.gitattributes` 仅加入 `/AGENTS.md -text` 与 `/execplan.md -text`，并在 clean checkout 后再次证明 SHA-256 与 sealed manifest 相同。BOOT-005 的架构永久对象登记读取同一 sealed docx；该登记在本地 provisional 实施期间可 pending，但在正式 acceptance/发布前必须完成。

### 0.4.2 根因优先与阶段推进补充

本补充由用户明确指示，属于执行方式和阶段隔离的增强；不放宽任何 secret、跨租户、生产写、数据丢失、不可逆操作、独立审批或正式合并边界。

- `1.5.0` 候选修订记录：增加根因优先闭环、无新信息时禁止重复小规模审查、第二次失败的 blocker 升级，以及每 Phase 新建干净 worktree/新分支和完成后的及时合并投影。它不改变产品能力、公共接口、运行时不变量或正式 owner 采纳要求；影响 `execplan.md` 的执行顺序、Phase 入口和 local/formal merge 语义，故两份 guidance 必须一同 reseal 后才可成为新的 bootstrap 输入。
- `1.6.0` 候选修订记录：把 STAR 从阶段叙事升级为预先冻结口径的行为量化合同，增加可比 baseline/candidate、指标公式与分母、运行级 trace、失败分类、护栏和证据边界。每个 Phase 只需记录与本次改造直接相关且确有改善的指标，不要求凑齐所有维度；未测、不可比或无改善不得写成成果。该修订不改变产品能力、公共接口、运行时不变量或正式 owner 采纳要求，但影响 `execplan.md` 的 089/retrospective/phase-close 证据合同，故两份 guidance 必须一同 reseal 后才可成为新的 bootstrap 输入。
- `1.7.0` 候选修订记录：仅细化 STAR 记录规范，把能力存在、行为改善和治理合规分开，增加“主要结果 + 诊断 + 护栏/红线”的精简计分结构、每成功任务成本及按实际模块启用的专项指标 profile。安全红线不得与普通指标平均抵消；RAG、Memory、Multi-Agent 或生产运行指标只在对应能力实际进入范围时适用。本修订不新增产品能力、基础设施、Phase/TASK、门禁阈值或发布权限；`execplan.md` 仅同步 STAR 收尾记录合同，两份 guidance 必须一同 reseal。

- Agent MUST 以可验证根因为单位解决问题：先收集首个失败、最小复现、输入/环境/依赖和最近 diff，再一次性修复该根因影响的实现、合同、fixture、测试、文档和证据；不得把同一根因拆成无新诊断信息的连续小修、小审或重复审计。
- 同一失败第二次出现、mandatory gate 无法立即修正、方案需要改变、外部依赖/授权阻塞或出现未知生产事实时，MUST 按 §12 建立 blocker；blocker 记录根因假设、已排除路径、影响面、完整修复方案、回滚和恢复条件。建档是为了推进，不是暂停其他 ready/repair 工作的理由。
- 每次根因修复 MUST 先重跑最小受影响检查，再重跑受影响的回归集合；只有结果产生新的区分信号时才允许下一轮 repair。禁止通过反复重跑、拆分微小审查、忽略失败、降低阈值、skip/xfail 或只改报告来获得表面通过。
- coordinator MUST 并行推进所有不依赖当前卡点的 ready 或 repair/enabler 工作；严格 DAG 暂无 ready TASK 时，MAY 创建最小、可逆且不改变目标合同的 enabler。只有 §0.4.1 列出的全局停止条件才允许停止整个工程。

### 0.4.3 个人项目自动治理与授权 profile

本仓当前 profile 固定为 `personal_automated`，决策记录为 `docs/architecture/adr/ADR-P10-001-personal-automated-release-governance.md`。仓库 owner 已在 `2026-08-02` 的本轮任务中明确授权：由自动门禁代替逐阶段人工签名，在全部适用 mandatory gate、压缩发布认证、回滚和证据完整性检查通过后，Agent MAY 自动把任务/Phase/Release 标为 `accepted`，push 当前 Phase 分支，把已认证树以保留历史的 merge 合入 `codex/gonow-agent-landing`，创建/更新 Release PR，并在 Release 门禁和托管平台 required checks 全绿后完成非强制合并。本授权不要求实施 Agent 冒充 Engineering/Security/Product 等多个自然人；自动 attestation 代表“预先授权条件已经机械满足”，不是伪造独立 reviewer。

原 enterprise governance、§2.4 的独立 owner 记录以及 §9.2.1 的 `1% → 5% → 20% → 50% → 100%` 生产观察合同继续完整保留，可由未来 owner 通过新的 MAJOR 修订重新启用；在 `personal_automated` profile 下，它们不参与当前 Release B 的依赖解析、blocking、acceptance 或 push/merge 判定。任何报告都 MUST 清楚标记实际 profile，禁止把个人压缩认证写成“完成 31 天生产观察”或把 synthetic/staging 证据写成真实用户流量。

自动 acceptance attestation 至少绑定：`profile`、完整 `candidate_head_oid`、Git object format、phase base/landing OID、AGENTS/execplan/架构 hash、锁文件与 Behavior digest、测试 manifest/dataset/seed/fault-plan/pricing hashes、逐门禁结构化结果、skip/xfail/flaky-rerun 计数、P0/P1 与安全红线计数、回滚结果、证据 manifest SHA-256、生成时间和 runner digest。以下条件必须同时成立：

- 所有适用 mandatory gate、受影响回归、真实 PostgreSQL 边界测试和回滚演练通过；`skipped=0`、`xfailed=0`、`flaky_rerun_count=0`，不得以重复运行到绿替代修复。
- `cross_tenant_leak_count=0`、`secret_or_pii_leak_count=0`、`unauthorized_write_count=0`、`duplicate_formal_side_effect_count=0`、`permanent_run_count=0`，无开放 P0/P1、数据丢失或不可回滚缺陷。
- 候选 OID、依赖/配置/Behavior、测试输入和报告 hash 在认证后未改变；任何会影响产物或结论的变化立即使 attestation 失效并触发受影响认证重跑。
- push/merge 只作用于计划中明确的 Phase/landing/Release refs；禁止 force-push、重写历史、直接把未认证工作树写入 `main`、删除远程分支证据或绕过 required checks。

本 profile 对生产的自动授权仅限 `execplan.md` 明确列出的 owner-only canary：使用预配置的最小权限 canary identity、固定 feature flag、成本上限和同一个已认证构建；允许通过现有 typed API/Domain Command 创建、取消、拒绝或采用 owner 自有测试数据。它不授权任意 SQL、migration、跨租户查询、扩大到其他用户、删除未知数据、修改权限/secret、不可逆供应商操作或无上限消费。缺少 credential、生产 endpoint、canary identity、budget cap、kill switch 或审计接线时，只阻断 canary；不得伪造输入，也不得阻止其他本地认证工作。

任何不可逆删除、force 操作、权限扩大、secret 轮换、付费上限外消费、全量生产分配或计划未列明的外部动作仍须新的明确用户授权。P0、secret/PII 暴露、跨租户访问、未授权正式写、数据丢失或 kill switch 失效时，自动授权立即撤销，allocation 必须归零并按 §5/§12 处置。

### 0.4.4 Phase 12 累计 Release C 收口例外

本小节是当前 `personal_automated` 收口周期对旧 §10/§11 P12 XOR 约束的唯一、窄化覆盖。累计能力集合固定为 `cumulative_capabilities=[P12D,P12B,P12A]`，顺序固定为 Domain Command 单写链、确定性 Cost Router、显式 Structured Memory；三者已经以保留历史的 local provisional merge 进入 `codex/gonow-agent-landing`，不得删除、重写、squash、rebase 或倒签其历史和证据。`P12C=dormant`，Multi-Agent 实现数和流量分配必须为 0。

累计不等于同时启用生产流量。工程候选仍保持产品运行时 Single-Agent；P12D、P12B、P12A 的独立 flag/route/read port 默认关闭或 allocation=0。Release C 本轮只认证累计代码与合同在关闭状态下可共存、回滚和恢复，不证明真实生产 schema/RLS/grants、备份链、流量或业务改善。生产部署、生产写和流量分配不在本轮授权内。

累计收口必须满足：三个能力各自 990/999 的 exact candidate、完整回归、merge tree 和 focused smoke 证据无未解释漂移；P12-000/001/002 依次登记集合、授权/ADR/风险/回滚和拓扑；P12-089 聚合文档、handoff、Harness Catalog 与状态；`REL-C-000` 固定 path=`phase12`；`REL-C-001` 只完成候选验证和发布准备。之后工程级 089/990/999 才能冻结唯一 landing candidate、执行一次全工程回归、focused smoke、非强制 push、受保护 PR 和非强制 main 合并。

若任一累计能力出现安全红线、无法解释的产物漂移、跨租户/未授权写、删除恢复失败或旧路径不兼容，累计 acceptance 必须 fail closed；回滚按能力独立关闭 flag/route/read port，必要时通过受保护 PR revert 精确 Release C merge，任何情况下都不 reset、force 或删除耐久证据。

### 0.5 架构追踪

本文没有复制架构正文；合同来源可按下表复核：

| 本文件 | v1.6.1 对应章节 |
|---|---|
| §1 当前事实与边界 | 第 1、2、30 章 |
| §3、§6 进程与 Runtime | 第 4、6、7、15–19、22、28 章 |
| §5 安全底线 | 第 18、25、26 章 |
| §7、§9 证据、观测与成本 | 第 23、24、26 章 |
| §8 数据库与迁移 | 第 17–19、26、28 章 |
| §10、§11 Phase/Release | 第 29、30 章 |
| §15、§16 收尾证据与 ADR | 第 24、26、29、30 章 |

## 1. 当前仓库事实与目标边界

本章解决“远程主线现在到底有什么、缺什么，以及最终架构在哪个阶段落地”的问题。

### 1.1 `Current Fact`

- `origin/main@142abfc339f003ede8d85d9534336923b5610252` 是 Flutter 根项目；`pubspec.yaml` 与 `pubspec.lock` 约束 Dart `>=3.11.5 <4.0.0`、Flutter `>=3.38.4`。这是本提交的 `Current Fact` 锁文件基线，不是禁止未来升级的永久版本上限。
- `lib/core/constants/**`、`lib/core/services/**`、`lib/features/ai_custom/**`、`lib/features/itinerary/**`、`lib/features/diary/**` 与 `lib/features/auth/**` 主要实现 Flutter UI、Provider、SharedPreferences、Supabase 客户端、地图/天气和客户端 AI HTTP 调用。
- `ai_custom_screen.dart` 同时承担 Prompt、历史、外部数据、模型调用、手工 JSON 解析和导入；行程与游记也有客户端模型调用和大文件内的写入逻辑。模型凭据已出现在受跟踪客户端常量中；本文只记录风险，不复现任何值。
- 行程 Provider 具有本地缓存、Supabase Realtime 与版本比较，这是兼容基线；但回滚路径未做 CAS，所谓追赶合并也不是字段级三方合并。游记/行程的部分删除或更新仅按资源 ID 发起，最终安全性依赖仓库中不可见的 RLS。
- 远程 `supabase/` 只有手工执行的 `storage_avatars_policies.sql`。业务表、Runtime 表、迁移历史、完整 RLS、索引、函数、触发器、seed、备份与恢复配置均无法从仓库证明。
- 根测试只有 `test/amap_service_test.dart` 与陈旧的 `test/widget_test.dart`；后者引用根 App 中不存在的 `MyApp`。网络用例被显式跳过，且无 Auth、AI、行程、游记、RLS、Realtime/CAS 集成测试。
- 远程没有 `.github/workflows/**`，因此没有可证明的 CI 门禁。`analysis_options.yaml` 只继承 `flutter_lints`，没有额外 active rules 或 analyzer 排除项。
- `android/` 内还嵌有另一套 Flutter 样板；所有根工程命令 MUST 从仓库根运行，不得误把 `android/pubspec.yaml` 当主项目。
- README 对未公开核心后端有文字声明，但不可由远程代码验证，故状态为 `unknown`，不能反推私有实现存在。

风险表述必须守住证据边界：受跟踪客户端常量中的模型凭据证明“客户端可提取并需要轮换”，但在完成供应商使用审计前，实际滥用范围、费用和受影响用户仍是 `unknown`；仓库缺少业务 RLS/migration 证明“无法复现与审计”，不等于可以武断宣称生产数据库完全没有策略；日志中存在正文输出路径证明“可能泄露”，但未盘点设备日志和 collector 前不得声称第三方已经收集。Phase 0 必须把这些未知项变成只读清单、哈希、owner 结论和安全事件证据。

### 1.2 明确缺失

| 能力 | `origin/main` 证据 | 判定 |
|---|---|---|
| `AGENTS.md`、`execplan.md` | Git 树无路径 | 本文件为首版；执行计划尚未创建 |
| `agent-service/`、Agent API/Worker | 无目录、依赖或入口 | 缺失；Phase 2 起落地 |
| LangGraph、typed Runtime、checkpoint | 无依赖与代码 | 缺失；Phase 4–6 落地 |
| Runtime DDL、durable jobs、lease、outbox | 仅有头像 Storage policy | 缺失；Phase 3、5 落地 |
| RAG、pgvector/FTS、索引 manifest | 无 schema、依赖或实现 | 缺失；仅 Phase 11 条件启动 |
| Redis、消息队列 | 无依赖或部署配置 | 缺失；没有量化证据前不引入 |
| MCP adapter | 无协议、SDK 或测试 | 缺失；Release B 不使用 |
| Agent CI/eval/security/replay | 无 workflow 与套件 | 缺失；随 Phase 建设 |

本地未跟踪的 `deliverables/`、`.worktrees/`、`.tmp/` 或 `supabase/functions/` 均不是远程事实。实施者 MUST NOT 把其中任何内容写成 `origin/main` 已有实现，也 MUST NOT 读取或记录 secret-like untracked 文件的内容。

### 1.3 “当前事实 → 目标合同 → 阶段”追踪

| 当前事实 | v1.6.1 `Target Contract` | 首次落地 |
|---|---|---|
| 客户端含模型凭据和直连调用 | 撤销旧凭据，服务端 Secret Provider/最小网关，客户端包与流量不含模型 secret | Phase 0 |
| 数据库 schema/RLS 不可复现 | 只读盘点后建立可重建 migration、RLS/grant diff、备份恢复证据 | Phase 0、3 |
| 现有验证/导入语义分散 | 固化 hard/warning/unverified、始终可导入和 fallback fixture | Phase 1 |
| 没有服务端 Agent | 同仓新增 Python/FastAPI/Pydantic `agent-service/`，API 与 Worker 分入口 | Phase 2 |
| 没有持久 Run/Job/Event | PostgreSQL 成为 Run、Job、Event、版本指针事实源 | Phase 3、5 |
| 模型结果可进入 broad Map/客户端写链 | 模型只产 typed Candidate；用户确认后由 Domain Command、CAS、outbox 写正式表 | Phase 4、7、9 |
| 本地取消只断连接 | 持久 cancel intent、fencing、合法终态和 SSE 回放 | Phase 5、6 |
| 旧聊天、Auth、导入、fallback 已被产品使用 | Release B 前后保持兼容，以独立 flag 双路径接线 | Phase 1、9、10 |
| 无 RAG、Memory、生产 Multi-Agent | Release B 明确不含；真实失败数据达到阈值后一次只启动一个能力包 | Phase 11 或 12 |
| 无 MCP | 内部 Tool 继续静态 Registry；仅获批外部互操作需求使用隔离 adapter | Phase 12 或独立后续包 |

目标保持一个 GoNow 仓库：现有 Flutter 根目录先不搬，未来 `agent-service/`、`contracts/` 与 `docs/execution/` 顶层共存。只有所有权、发布权限或 CI 产生实质冲突时才讨论拆仓。v1.6.1 的 34 项 Harness 是代码控制责任与数据合同 `[硬约束]`，不是 34 个服务；Release B 的物理目标仍是一个 Agent 代码库、`agent-api` 与 `agent-worker` 两个进程 `[硬约束]`。

## 2. 干净基线、工作树和阶段分支协议

本章解决“从哪个提交施工、怎样不碰用户文件、何时才允许合并”的问题。

### 2.1 禁止污染现有目录

- 实施 Agent MUST NOT 在已有脏工作树直接施工；本次创建宪章不等于授权任何 Phase 实施。
- MUST NOT 删除、覆盖或移动用户已有 untracked 文件，也不得读取疑似凭据正文。
- MUST NOT 为了“变干净”执行 `git reset --hard`、`git clean -fdx`、强制 checkout、force-push 或改写历史。
- 控制仓或 worktree 目标路径若已存在且非空，MUST NOT 删除或覆盖；Agent SHOULD 自动选择一个新的空任务专属同级目录并在 BOOT receipt 中记录实际路径。只有无法找到安全空路径或用户明确要求固定路径时才暂停请求决定。
- 只读核验 MAY 在当前控制目录进行；任何代码、迁移、依赖或测试 fixture 变更必须进入新建的干净 worktree。

### 2.2 Windows PowerShell 建立基线

控制仓、landing branch 和 Phase 00 worktree 的唯一创建/中断恢复入口是 `execplan.md` Chapter 1 的两个完整代码块；缺治理采纳 receipt 时它们自动使用 `local_provisional`，有有效 receipt 时使用 `formal_adopted`。本文件不复制有状态创建逻辑。下面模板只读验证 Chapter 1 的结果，不执行 clone/fetch/branch/worktree add，也不授权推送远程；固定 OID、内容 hash、状态 CAS 与分支语义不可静默改变。

```powershell
$ErrorActionPreference = 'Stop'
$ExpectedRemote = 'https://github.com/Elfsa-Miranda/GO_NOW.git'
$ExpectedPlanBaseSha = '142abfc339f003ede8d85d9534336923b5610252'
$ControlRepo = 'D:\GO_NOW-control'
$Worktree = 'D:\GO_NOW-agent-worktree'
$BootstrapRoot = Join-Path $ControlRepo '.git\gonow-bootstrap'
$Boot1ReceiptPath = Join-Path $BootstrapRoot 'BOOT-001.native.json'
$Boot1StatusPath = Join-Path $BootstrapRoot 'TASK-BOOT-001.native-status.json'
$Boot2ReceiptPath = Join-Path $BootstrapRoot 'BOOT-002.native.json'
$Boot2StatusPath = Join-Path $BootstrapRoot 'TASK-BOOT-002.native-status.json'
foreach ($RequiredPath in @($Boot1ReceiptPath,$Boot1StatusPath,$Boot2ReceiptPath,$Boot2StatusPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) { throw "Missing bootstrap receipt/status: $RequiredPath" }
}
$Boot1Receipt = Get-Content -LiteralPath $Boot1ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$Boot1Status = Get-Content -LiteralPath $Boot1StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$Boot2Receipt = Get-Content -LiteralPath $Boot2ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$Boot2Status = Get-Content -LiteralPath $Boot2StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$Boot1ReceiptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Boot1ReceiptPath).Hash.ToLowerInvariant()
$Boot2ReceiptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Boot2ReceiptPath).Hash.ToLowerInvariant()
$Boot1Valid = [string]$Boot1Status.evidence_sha256 -ceq $Boot1ReceiptHash -and (
  ([string]$Boot1Status.status -ceq 'accepted' -and [bool]$Boot1Status.reviewer_independent) -or
  ([string]$Boot1Status.status -ceq 'ready_for_review')
)
$Boot2Valid = [string]$Boot2Status.evidence_sha256 -ceq $Boot2ReceiptHash -and (
  ([string]$Boot2Status.status -ceq 'accepted' -and [bool]$Boot2Status.reviewer_independent) -or
  ([string]$Boot2Status.status -ceq 'ready_for_review')
)
if (-not $Boot1Valid -or -not $Boot2Valid) {
  throw 'BOOT-001/002 receipt-hash binding or mode-specific status is invalid'
}
$BASE_SHA = [string]$Boot1Receipt.base_sha
if ($BASE_SHA -cne $ExpectedPlanBaseSha -or [string]$Boot1Receipt.expected_plan_base_sha -cne $ExpectedPlanBaseSha) {
  throw 'BOOT-001 receipt does not bind the jointly reviewed plan baseline'
}
git -C $ControlRepo cat-file -e "$BASE_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Pinned BOOT-001 base commit is unavailable' }
if ((git -C $ControlRepo remote get-url origin).Trim() -cne $ExpectedRemote) { throw 'Control remote mismatch' }
if ((git -C $ControlRepo rev-parse codex/gonow-agent-landing).Trim() -cne $BASE_SHA) { throw 'Landing OID mismatch' }
if ((git -C $Worktree rev-parse HEAD).Trim() -cne $BASE_SHA) { throw 'Worktree HEAD mismatch' }
if ((git -C $Worktree symbolic-ref --short HEAD).Trim() -cne 'codex/phase-00-baseline-security') { throw 'Worktree branch mismatch' }
if ((git -C $Worktree rev-parse --show-toplevel).Trim().TrimEnd('\') -cne $Worktree.TrimEnd('\')) { throw 'Worktree path mismatch' }
if (@(git -C $Worktree status --porcelain=v1).Count -ne 0) { throw 'Worktree is not clean' }
if ((git -C $Worktree remote get-url origin).Trim() -cne $ExpectedRemote) { throw 'Worktree remote mismatch' }
$GitLinks = @(git -C $Worktree ls-files --stage | Select-String '^160000\s')
if ($GitLinks.Count -ne 0) { throw 'Unexpected submodule/gitlink found' }
$NestedGit = @(Get-ChildItem -LiteralPath $Worktree -Recurse -Force -Filter .git |
  Where-Object { $_.FullName -ne (Join-Path $Worktree '.git') })
if ($NestedGit.Count -ne 0) { throw 'Unexpected nested .git found' }
$Untracked = @(git -C $Worktree ls-files --others --exclude-standard)
$CredentialLike = @($Untracked | Where-Object {
  $_ -match '(^|/)(\.env($|\.)|id_rsa|id_ed25519|.*\.(pem|key|p12|pfx))$'
})
if ($CredentialLike.Count -ne 0) { throw 'Untracked credential-like filename found' }
```

开始编辑前，实施者 MUST 把远程 URL、默认分支、`BASE_SHA`、提交时间/主题、命令退出码、树摘要、工具可用性和“未读取 secret 正文”的声明写入脱敏的 `docs/execution/evidence/boot/baseline.md`。该报告只能保存路径/哈希/结论，不能保存凭据或大日志。

### 2.3 每阶段一分支

- 每个 Phase MUST 在新的、干净且专属的 worktree 中开始，并从上一 Phase 的 formal accepted commit 或 local provisional checkpoint OID 创建新的 `codex/phase-XX-short-name` 分支；不得在上一 Phase worktree、分支或用户脏目录继续堆叠实现。worktree 路径、分支、base OID、创建前 clean status 和阶段入口 regression MUST 写入 phase runtime manifest。
- `formal_adopted` 模式下，每个 Phase MUST 从“上一阶段已验收并合入 `codex/gonow-agent-landing` 的提交”创建新 `codex/phase-XX-short-name` 分支并记录 `phase_base_sha`。`local_provisional` 模式下，上一阶段机械门禁通过且状态为 `ready_for_review` 后，MAY 先建立不推送的 provisional integration/checkpoint，再从其 OID 创建下一 Phase；必须记录 `provisional_base_oid`，不得把它称为 accepted 或推送到远程。
- 开始前 `git status --porcelain=v1` MUST 为空；阶段内只改任务卡 allowlist 中的文件。机会主义重构写成后续建议，不得搭车。
- 新 Phase 分支的第一个 TASK MUST 在未做本阶段功能修改前，重跑所有已验收或 provisional-complete Phase 的可重放 mandatory regression suite；至少包括上一 Phase 的机械测试/gate suite、此前稳定 CT/安全边界和旧产品关键旅程。任一失败先执行 §0.4.1 的诊断与 bounded repair；受影响功能未修复前不得继续扩大，但不依赖该失败路径的代码、测试、fixture、文档和修复任务可以继续。enterprise profile 的长期灰度/人工批准不可即时重跑时记录 pending；当前 personal profile 则必须重跑 §9.2.2 中可重放的受影响压缩认证，不得沿用旧候选结果。
- 若完整历史 gate 因运行时长不适合作为每次提交检查，MAY 由适用 profile 接受一个版本化的 `phase-entry-regression` 聚合集；该聚合集仍 MUST 覆盖每个已验收 Phase 的至少一个关键旅程、全部已落地 Hard Constraint/CT 以及所有曾发生过的 P0/P1 回归。缩短集合不得改变各 Phase 自己的完整退出门禁。
- 不得在上一阶段分支继续堆提交。提交信息 MUST 含 Phase 与 TASK ID，且每个提交可重放、可回滚。
- 实施期间若 `origin/main` 前进，MUST 记录新旧 SHA 与差异；MUST NOT 静默 rebase。另建同步任务评估兼容性、重跑受影响门禁，经适用 profile acceptance 后才 merge/rebase。
- enterprise profile 中阶段 Agent 只能把状态标为 `in_progress`、`ready_for_review` 或 `blocked`；`accepted`/`rejected` 由授权独立 reviewer 决定。当前 personal profile 允许受版本控制的 runner 在 §0.4.3 全部条件成立时写入自动 `accepted` attestation，实施代码本身不得直接改状态或绕过 runner。

### 2.4 合并门禁

“完美验收”是可核验状态，不是实施者评价。合并前 MUST 同时满足：

- 所有 mandatory gate 通过；不得靠 skip、xfail、忽略退出码、重复跑到偶然变绿或手改报告伪装。
- 未关闭的 P0/P1 安全、数据丢失、跨租户或不可回滚问题为零 `[硬约束]`。
- `git diff --name-only $phase_base_sha...HEAD` 与任务 allowlist 一致，`git diff --check` 成功，无意外文件。
- 结构化测试、安全、迁移、回滚演练和 `acceptance.md` 齐全，报告绑定 base/head Git OID、object format 和 artifact hash。
- enterprise profile 由工程/安全及适用产品/数据 owner 独立签署；current personal profile 由 §0.4.3 的候选绑定自动 attestation 代替，Agent 不能手写或伪造 attestation。
- `execplan.md` 定义的逐任务 CAS 状态账本与证据同步；计划正文只保存获批计划和初始快照，不作为执行期共享状态文件。实时状态固定写入 `docs/execution/status/TASK-ID.json`，任何普通 TASK 都不得通过改写 `execplan.md` 报进度。

当阶段已完整解决其根因、所有 mandatory gate/回归/回滚证据通过、allowlist 清洁且无开放 P0/P1 时，MUST 立即形成可复现 checkpoint 和 `ready_for_review` 证据。enterprise profile 仍按独立 owner 批准合入；current personal profile 在自动 attestation 通过后 MUST 及时 push Phase 分支并以 PR 或 `--no-ff` 合入/push `codex/gonow-agent-landing`。集成分支进入 `main` 仍只能走单独 Release PR，但 personal profile 可在 Release gate 与 required checks 全绿后自动完成该 PR；阶段中禁止直接改写 `main`。

#### Enterprise owner 批准操作规范

本小节只适用于 `enterprise_governed` profile；current `personal_automated` profile 使用 §0.4.3 和下述自动 attestation。

机器可读的单人批准角色固定为 `Engineering|Architecture|Security|Data|Product|Privacy|SRE|Eval|Domain|Compliance`。`Backend/API/Mobile/Search/Reliability/ReleaseEng` 等实施专长在批准记录中映射到上述责任角色，不能临时发明一个角色绕过 required owner。Engineering 与 Security 的独立批准必须由不同自然人完成；一人兼任多个角色时只计一个独立席位。

`Release Board` 是复合决策体，不是可由单个 `owner_role` 代替的签名。最低 quorum 为 Engineering、Security、Product 三名独立成员全部同意；涉及生产启停追加 SRE，涉及数据用途/RAG/Memory 追加 Data+Privacy，涉及监管义务追加 Compliance。任一 required role 拒绝或缺席即无 quorum。每档/Release 决定保存到 `docs/execution/evidence/phase-XX/release-board/decision-<stable-id>.json`，至少含 `decision_id/candidate_head_oid/git_object_format/members[]/required_roles/quorum_met/decision/conditions/decided_at/permanent_references`，并链接每位成员按下述格式作出的独立批准。

有效批准 MUST 绑定被审查的完整 `candidate_head_oid`，而不是模糊的分支名；当前仓库 object format 为 SHA-1，因此表现为 `40` 位。批准采用以下任一可长期复核的形式：

1. owner 亲自在 `docs/execution/evidence/phase-XX/acceptance.md` 对应批准记录上提交 commit；或
2. owner 在受保护 PR 提交 review，并在 `acceptance.md` 保存该 review 的永久链接与不可变标识。

每份批准 MUST 包含：

```yaml
owner_role: Engineering|Architecture|Security|Data|Product|Privacy|SRE|Eval|Domain|Compliance
owner_name: "真实可追责姓名"
git_object_format: "sha1（当前仓库；从 git rev-parse --show-object-format 读取）"
approved_head_sha: "当前仓库中等于 candidate_head_oid 的完整 40 位 Git SHA"
approved_at: "ISO 8601，精确到秒并带时区"
valid_until: "不晚于 approved_at 后 14 天"
conditions:
  - "unconditional，或逐条写可机械验证的关闭条件"
statement: "我已独立阅读本 acceptance.md，并对这里明确列出的责任范围和 mandatory gate 真实性负责。"
permanent_reference: "commit SHA 或 PR review 永久链接"
```

owner 直接提交批准记录时，`approval_record_oid` 必然晚于被批准的 `candidate_head_oid`，不会要求 commit 自己引用自己的 OID。该 approval commit 只能新增 owner 批准块/索引，其 parent 必须是被批准候选，Gate runner 必须证明 `candidate_head_oid..approval_record_oid` 没有代码、配置、lock、migration、contract 或机器结果变化；否则批准无效。PR review 形式则直接绑定未变化的 candidate head。

批准不可代理。口头同意、会议结论、即时通讯中的“可以”、仅写 `LGTM/approved`、由实施 Agent 代填，或没有绑定完整 OID 的签名均无效。即时通讯内容只有在 owner 亲自在 `acceptance.md` 确认其准确性后才可作为辅助证据。批准后若代码、迁移、依赖锁、gate 输入、报告计数或 artifact hash 改变，原批准自动失效；仅修正不影响证据的拼写也须由 reviewer 说明为何无需重签。超过 `valid_until`、条件未关闭或责任 owner 变化时 MUST 重新独立审核。

#### Personal 自动 acceptance attestation

personal profile 的 runner 只有在 §0.4.3 全部 predicate 成立时才可创建 `docs/execution/evidence/phase-XX/automated-acceptance-attestation.json` 并以 expected status SHA 做 CAS。该文件只记录机器事实、用户预授权 profile 和证据 hash；实现 Agent不能自行填写 `passed=true`。若 runner、Catalog、阈值、dataset、seed、fault plan、candidate tree 或证据发生变化，旧 attestation 自动失效。Phase/Release 的 `accepted` 状态必须引用 attestation SHA-256 和 candidate OID；缺任一绑定即为 blocked。

#### 获批树与合并等价性

- 合并前 `codex/gonow-agent-landing` 的当前 OID MUST 精确等于本 Phase 记录的 `phase_base_oid`；若 landing 漂移，停止合并，建立同步 TASK，重新跑受影响 gate/批准，不能在 merge 时临时解冲突。
- enterprise profile 的 `approval_tip_oid` 是最后一份有效 owner 批准记录所在的 source tip；若全部批准来自 PR review 且没有 approval commit，则等于 `candidate_head_oid`。personal profile 的 `approval_tip_oid=candidate_head_oid`，自动 attestation 作为后续 evidence-only commit 保存；两种模式都必须证明候选到 approval tip 没有运行时或合同漂移。
- Phase 合并只允许产生保留历史的双亲 merge commit，不允许 squash/rebase merge。合并后机械断言：parent 1=`phase_base_oid`；parent 2=`approval_tip_oid`；`merge_oid^{tree}`=`approval_tip_oid^{tree}`。任一不等表示目标漂移、冲突解决或额外文件进入，merge 不是获批候选，必须停止、可审计 revert，并重新跑完整门禁与批准。
- 校验结果保存为 `docs/execution/evidence/integration/<merge-oid>/merge-tree-verification.json`，包含 object format、三个 OID、各 tree OID、parent 数量、命令/退出码和 SHA-256；五分钟 smoke 只能在此校验通过后启动。

#### 合入后的五分钟集成烟雾

- 每个 Phase 的批准合并提交形成后，获授权的合并操作者 MUST 在 `5` 分钟内启动版本化 `integration-smoke`，其 wall-clock 上限也为 `5` 分钟。它验证“此前能启动和完成的最小关键路径仍能完成”，不是完整 mandatory suite 的替代品。
- 套件 MUST 至少验证：集成分支 clean 且 merge OID 正确；已存在的进程可启动/优雅停止；健康与 readiness 语义；非法身份仍以稳定安全错误拒绝；每个已验收 Phase 至少一个关键旅程；旧 Flutter 普通聊天/导入/Auth/fallback 的最小兼容检查；所有曾发生的 P0/P1 canary。某能力尚未实现时只能记录 `not_applicable + 合同依据`。
- 结果保存到 `docs/execution/evidence/integration/<merge-oid>/`，包含开始/结束时间、命令、退出码、结构化报告、工具版本和 artifact hash。超时、未运行或任一 mandatory smoke 失败都视为集成失败：立即停止后续 Phase/Release 分配并建立 blocker；enterprise 由 owner 选择回切，current personal 按预注册 rollback policy 自动执行 feature flag/route 回切或在回滚预检通过后形成可审计 revert commit。MUST NOT 用 reset、force-push 或删除证据处理。
- 烟雾失败后的修复合并也必须重新跑同一套件。smoke 通过后，获授权操作者 MAY 提交只含 smoke、merge addendum 和预收尾索引的 `smoke_attestation_oid`；Gate runner 必须证明从 `merge_oid` 起没有可执行合同/代码变化。
- 收尾链固定为 `merge_oid → smoke_attestation_oid → phase_close_oid`。`phase_close_oid` 在 §15 retrospective、适用 STAR、最终 versioned manifest 与 phase-close record 完成后形成，只允许这些治理路径；下一 Phase 只能从 `phase_close_oid` 分支。任一证据提交含代码、配置、lock、migration、`contracts/` 或运行时默认值变化，就成为新候选，原 smoke/批准失效并须完整重跑。

## 3. 变更范围、代码结构与进程边界

本章解决“代码放哪里、哪个进程负责什么、哪些目标目录目前尚不存在”的问题。

以下全部是 `Target Contract`；现有 Flutter 目录是 `Current Fact`，其余须由对应 Phase 创建：

```text
agent-service/
  app/
    api/
    auth/
    runtime/
    graphs/
    harness/
    models/
    tools/
    rag/
    validation/
    commands/
    persistence/
    observability/
  migrations/
  tests/
    unit/
    contract/
    integration/
    replay/
    security/
    eval/
contracts/
docs/
  api/
  architecture/
    adr/
    threat-model/
  runbooks/
  execution/
    blockers/
      phase-XX/
    commands/
    evidence/
      integration/
      phase-XX/
    schemas/
    status/                            # 每 TASK 一个 CAS 状态；派生看板不是第二事实源
    supply-chain/
```

治理产物 MUST 进入上述稳定目录，不得散落在仓库根目录、个人下载目录或未命名的 `tmp/` 中。OpenAPI/Dart 等可执行合同的事实源放 `contracts/`，`docs/api/` 只保存面向人的解释并链接事实源；架构决策放 `docs/architecture/adr/`；操作步骤放 `docs/runbooks/`；阶段证据、知识转移、回顾、STAR 与 blocker 的归档规则见 §15。尚未创建的目录仍是 `Target Contract`，不能反推当前主线已经存在。

v1.6.1 的目标技术线是 Python `3.13`、FastAPI `0.136.x`、Pydantic v2、LangGraph/LangChain v1、SQLAlchemy 2 与 Alembic `[硬约束：目标版本线]`。远程主线目前没有 Python lock，因此精确 patch、transitive dependency 和镜像 digest 仍为 `unknown`；Phase 2 MUST 先用官方兼容证据锁定并生成 SBOM。未经 ADR 不得因个人语言偏好换栈。

- `agent-api` MUST 负责 JWT/AuthZ、控制面、幂等、SSE、resume/cancel 与限流；MUST NOT 调用模型或 Tool，也不得执行长 LLM 工作。
- `agent-worker` MUST 执行有界 Graph，通过 PostgreSQL durable jobs 领任务；MUST NOT 暴露公网，也不得写正式行程/游记表。
- Release B 唯一 Agent 产品场景是多日行程规划 `[硬约束]`；旧普通聊天与手动导入继续保留且旁路 Agent。MUST NOT 顺手扩展为普通聊天 Agent、游记 Agent 或其他领域 Agent。
- Release B 只允许一个 planning Behavior 和一张有界 Graph `[硬约束]`；复杂度路由应让简单请求走 direct/API/rule/workflow，不得为了展示 Agent 而一律创建 Run。
- Release B 只使用一个主模型供应商及其经济/能力两档已认证确定性路由 `[硬约束]`；顺序 fallback 只能选择同一 Behavior 已认证的 route。MUST NOT 借 provider-neutral adapter 建多供应商平台、路由 LLM 或未经认证的自动故障切换。
- PostgreSQL MUST 是 Run、Job、Event、checkpoint 引用、调用账本和发布指针的事实源。Redis 在有量化证据前 MUST NOT 引入；以后也只能缓存、限流或唤醒，不能成为业务真相。
- Flutter 的普通聊天、导入、Auth 与 fallback 在 Release B 前后 MUST 兼容。规划新链通过独立 feature flag 接入。
- 模型只 MAY 产生 typed Candidate。用户确认后，Domain Command 才能以 principal、command hash、approval、expected version、CAS 与 outbox 写正式业务表。
- Release B 最多暴露 POI、路线、天气三类只读 Tool `[硬约束]`；RAG、隐式长期 Memory、生产 Multi-Agent、Redis、开放 MCP 市场和重型平台不在该 Release。

Phase 0 对已暴露 secret 的止损不受兼容窗口拖延；旧产品行为必须改走安全网关。其余旧直连 LLM、旧解析、旧写入或兼容 adapter 只有在新路径已完成 `100%` rollout `[硬约束：删除前置]`、持续满足批准的风险样本与观察窗、至少跨两个移动 App 发布周期 `[硬约束：删除前置]`、旧客户端占比低于预先批准且经生产校准的支持阈值 `[初始假设，需上线校准]`、回滚窗口关闭、迁移/导出完成并取得用户与相应 owner 批准后，才 MAY 删除。删除前必须先阻止新使用、观测残余调用并保留可回切 adapter；不得触碰 untracked/user-owned 文件。

Release A 的普通聊天安全网关属于兼容路径，不授予 `agent-api` 模型权限；其最终承载位置必须由 Phase 0 的生产只读盘点决定。进入 Release B 后，规划模型/Tool 调用只发生在 `agent-worker`，普通聊天仍走独立兼容网关。

## 4. 全局工程行为

本章解决“Agent 每次动手应遵守什么工作方式”的问题。

- MUST 先读本文件、当前 Phase 任务卡和相关源码，再编辑；不得先改后问。
- MUST 先复现基线。无法复现、工具不可用或结果与记录不一致时，按第 12 章建 blocker。
- MUST 使用最小变更，禁止 Big Bang 重写。巨型 Flutter 文件的改动必须围绕明确连接点并补针对性回归。
- 新依赖（Python/Dart/Node 包、系统工具、容器基础镜像或原生库）MUST 说明必要性、精确锁定版本或 digest、许可证、维护状态、供应链来源、替代方案与回滚；未知信息写 `unknown`，但 `unknown` 不能通过供应链门禁。
- 依赖 TASK 必须先记录直接与传递依赖 diff，再生成 SBOM、许可证清单、CVE 扫描、来源/provenance 与维护状态证据。直接依赖最近一次正式发布距审查日超过 `18` 个月、许可证为 `UNKNOWN`/与产品用途不兼容、来源不可验证，或扫描存在未关闭的 Critical/High 漏洞时，默认 `blocked`；继续采用必须有 §16 ADR、Security/Engineering owner 和有时限的风险处置，且不得放宽 Release 的高危为零门禁。
- 每次依赖审计归档到 `docs/execution/supply-chain/phase-XX/TASK-ID/`，至少包含 `dependency-diff`、`sbom`、`licenses`、`vulnerability-scan`、`maintenance`、`provenance` 与 `decision` 的结构化文件；这些文件及生成命令的 SHA-256 必须进入任务 `artifact-hashes.json`。大报告按 §15 只保存不可变链接、hash、保留期和访问级别。
- 机械命令 MUST 由已锁定的工具清单提供：Python 环境至少执行 lock 校验、SBOM、许可证和 CVE 扫描；Dart 至少执行 `pubspec.lock` diff、许可证与 advisory 扫描；镜像/系统工具至少执行 digest、SBOM、签名/provenance 与漏洞扫描。工具未供应或 advisory 数据无法更新时结果是 `blocked`，不得手写“无漏洞”。
- lock/SDK 升级必须是显式 TASK，提供依赖 diff、官方兼容证据、SBOM/许可证变化、全量回归和回滚；MUST NOT 由格式化、安装或生成命令静默漂移。
- MUST NOT 通过关闭 lint、放宽 ignore、降低阈值、删失败 fixture 或把 mandatory 测试改为 skip 来“修复”CI。
- 所有外部调用 MUST 有 timeout、总 deadline、稳定错误分类和有限重试；一个错误只能由一个责任层重试。
- 所有并发写 MUST 有幂等键、唯一约束、CAS 或 fencing。禁止先 `SELECT` 再靠应用内判断假装原子。
- MUST NOT 伪造测试、生产流量、成本、Judge、安全或 owner 批准。没有数据就写 `unknown`。
- mandatory 检查不得跳过；非 mandatory 检查若未运行，必须写原因、风险、owner 与补跑条件。
- 生产资源、密钥轮换、数据库写入、远程分支、部署和推送需要显式权限；只读分析不自动扩大为外部写操作。

## 5. 不可放宽的安全、隐私与合规边界

本章解决“无论赶工还是故障都绝不能做什么，以及安全怎样成为机械门禁”的问题。

### 5.0 主要威胁场景与防御链

安全规则必须能回答“防的是什么、哪一层拒绝、失败后谁停止”。至少维护以下威胁场景；新增入口、Tool、数据用途或进程边界时，TASK MUST 更新威胁模型、攻击路径、信任边界和对应测试，不能只在规则清单中加一句话。

| 威胁场景（白话） | 攻击者想得到什么 | 强制防御链 | 必须证明的失败结果 |
|---|---|---|---|
| 恶意规划内容/间接 Prompt Injection | 用“忽略规则”等文本诱导 Agent 泄露数据或调用未授权能力 | 不信任输入/检索指令 → `ContextCompiler` 隔离 → 静态 `ToolRegistry` → `ToolArgValidator` → `AuthorizationPolicy/TenantScope` → `AuditLogger` | 危险文本只能成为不可信数据；未知/越权 Tool 安全拒绝且 handler 零调用 |
| Worker 崩溃后的“幽灵写入” | 旧 Worker 复活后覆盖新 Worker 的状态、重复扣费或产生第二个终态 | PG lease → 更高 fencing token → `ConsistencyFence` → CAS/唯一约束 → invocation/outbox receipt → reconciler | 旧 token 的 event/candidate/terminal 写均拒绝；物理副作用与扣费不重复 |
| 跨租户读取或写入 | 用户 A 通过伪造 ID、缓存键或查询条件看到用户 B 数据 | server-derived principal → `TenantScope` → repository 强制 filter → RLS/grant 最后防线 → tenant/ACL 维度 cache key → canary | 正反主体在真实 PG 验证；`acl_leakage_count=0` |
| 费用爆炸或无限循环 | 用重复模型/Tool/repair 调用耗尽预算和资源 | `BudgetManager` → `MultiBudgetLimiter` → 原子 `PhysicalInvocationLedger` reservation → bounded retry/repair → deadline/no-progress → 供应商预算告警 | 超额调用在 handler 前被拒；达到预算 `80%` `[初始假设，需上线校准]` 时告警，达到硬上限时安全终止且账本不可改 |
| secret/PII 经日志、checkpoint 或供应商外发 | 从持久化证据、客户端包、trace 或第三方服务恢复敏感内容 | `SecretsProvider` 仅内存注入 → state/schema 字段拒绝 → `PIIRedactor` → 日志 allowlist/§9 schema → artifact/history scan → retention/deletion | synthetic canary 不出边界；redaction 失败时不发送；旧 secret 被撤销且新产物不含其值 |

威胁模型至少在每个 Phase 入口、公共合同/数据用途变化、P0/P1 事件后以及 Release PR 前复核。每个 Phase 都 MUST 保存 review receipt、当前模型 SHA-256、candidate head OID、Security owner 与时间；没有变化只能记录 `model_changed=false` 和比较依据，不能标 `not_applicable`。模型/复核产物放在 `docs/architecture/threat-model/` 与对应 Phase evidence；攻击者能力、受保护资产、入口、信任边界、缓解措施、残余风险与验证命令不得留空。

### 5.1 禁止清单

以下每项均为 `[硬约束]`：

- 模型 MUST NOT 直接写 `user_itineraries`、`activities`、`diaries` 或其他正式业务表。
- MUST NOT 提供任意 SQL、text-to-SQL、`run_sql`、通用数据库管理 Tool，也不得提供任意路径文件读写、shell/exec、包管理、动态代码求值或通用命令执行 Tool。
- 模型 MUST NOT 提供任意 URL。外部访问使用 `endpoint_id + typed params`，并校验 scheme、port、host、DNS/IP、重定向和路径，防 SSRF、重绑定和穿越。
- Redis MUST NOT 成为 Run、Job 或 Event 事实源。
- HITL 超时 MUST NOT 自动批准；高风险动作没有有效、一次性、未消费且绑定 principal/command hash/expected version 的凭证就拒绝。
- MUST NOT 把 LangGraph super-step 当业务阶段计数器；业务阶段、LLM、Tool、repair、Token、成本、deadline 与 no-progress 分开限额。
- secret、access token、连接池、provider client、完整 Prompt 原文和 opaque reasoning MUST NOT 进入 checkpoint、日志、trace、缓存或评测导出。
- 同一幂等键对应不同 body MUST 返回 HTTP 409，不得创建第二个 Run。
- tenant 数据缓存键必须含 tenant、principal、ACL policy 与 manifest 维度；MUST NOT 跨租户共享用户数据。
- OR-Tools 等 native solver 必须在独立进程运行，具有软超时和父进程硬 kill。
- 未完成认证的 Behavior Package MUST NOT 发布。
- MUST NOT 修改后再回传供应商 opaque reasoning block；PIIRedactor 不得把 reasoning 变成可记录内容。
- LangSmith 或任何外部观察平台 MUST NOT 成为 Run 真相或唯一发布门禁。
- negative consent 必须在提取、写入、合并、检索和评测导出前 hard deny；删除后不得自动重新挖掘。
- 新系统 JWT 路径 MUST 拒绝 `alg=none` 和 HMAC；算法 allowlist 先于 key/claim 验证。遗留 HMAC 若确实存在，只能走隔离且经批准的 Auth Server 验证/迁移路径。
- 日志使用字段 allowlist，默认不记录正文、用户行程、JWT、secret、Prompt 或 Tool 原始返回。
- 测试默认使用合成/脱敏数据。生产只读也需最小权限和审计；任何生产写入需显式批准。
- MUST NOT 运行来源不明的下载脚本，或把密钥写入命令行、Markdown、CI 输出、截图。
- MUST NOT force-push、绕过保护分支、删除远程 branch/tag 掩盖历史。
- Release B MUST NOT 同时引入 RAG、长期 Memory、生产 Multi-Agent、Redis、消息队列或重型平台。

### 5.2 安全检查矩阵

下表给出发现时的默认严重度；若已存在生产暴露、影响范围不明或多类边界同时失效，MUST 升高至少一级。降级严重度只能由 Security owner 以书面证据批准，不能由实施者自行判断。

| 类别 | 执行位置 | 失败方式 | 必须证据 | 默认严重度与最迟响应 | 批准 owner |
|---|---|---|---|---|---|
| 身份 | API middleware/JWT verifier | fail-closed；`auth.invalid_token` | 正反 token corpus、未知 `kid`、轮换、时钟偏差 | P1；当日停受影响 TASK，24h 内修复方案 | Security |
| 授权 | Policy、Tool、Command | deny；`auth.forbidden` | action/resource/field 正反例与 approval bypass | P1；当日立档，24h 内重跑 gate | Security + Domain |
| 多租户 | RequestContext、repository、cache | 缺 tenant 即拒绝 | cross-tenant canary，泄漏计数为零 `[硬约束]` | 生产/持久化 P0：30min 通知；仅隔离测试 P1 | Security + Data |
| RLS | PostgreSQL policy/grant | 数据库拒绝 | 真实 PostgreSQL 正反主体、RLS/grant diff | 可达路径 P1；24h 内方案且验收前关闭 | Data + Security |
| SSRF | Tool Gateway/egress | 拒绝请求且不 fallback | 内网、metadata、redirect、DNS rebinding 套件 | 可达环境 P1；仅隔离测试缺口 P2，72h 内计划 | Security |
| SQL | repository/RPC | 无 arbitrary executor | SAST、参数化查询、fuzz、最小 DB role | 生产可达/已执行 P0；隔离测试可达 P1 | Security + Data |
| Prompt Injection | 输入/检索隔离、Policy、Tool allowlist | 危险提议不得执行 | 直接/间接/多语言/编码攻击集 | 生产 Tool/泄露 P0；隔离测试可达 P1；仅覆盖缺口 P2 | Security + Eval |
| Tool 权限 | Registry、ArgValidator、Permit | 未知/越权安全 JSON | unknown tool、伪造 user_id、scope/预算及 file/shell/exec 拒绝用例 | 生产越权 P0；隔离测试可达绕过 P1；纯覆盖缺口 P2 | Security + Domain |
| PII | Context、log/trace/export | redaction 失败则不发送 | synthetic canary、字段 allowlist、删除链 | 已持久化/外发 P0；仅合成测试 P1 | Privacy |
| secret | Secret Provider、build、日志 | readiness/发布失败 | 全历史 scan、产物/网络检查、旧 key 失效证明 | 客户端/持久化/生产 P0；不可达测试值 P1 | Security |
| 供应链 | lock、CI、image | 未锁定/高危即阻断 | SCA、SBOM、签名/provenance、许可证清单 | Critical/High 或 provenance 失效 P1；其他 P2/P3 | Engineering + Security |
| 审计 | Command/Tool/security event | 高风险写阻断 | append-only receipt、篡改/缺失测试 | 高风险动作无 receipt P1；非强制字段缺口 P3 | Security + Compliance |
| 备份恢复 | PG/object/eval | 未演练不得宣称 RPO/RTO | 隔离恢复、RLS/grant、删除账本重放 | 无法恢复/删除复活 P1；演练覆盖缺口 P2 | Data + SRE + Privacy |

### 5.3 严重度、响应时限与验收效力

| 级别 | 判定 | 必须动作与时限 | 对 Phase/批准的影响 |
|---|---|---|---|
| `P0` | 可能已经发生生产泄漏、跨租户读写、任意 SQL/Tool 执行、secret/PII 进入持久化或影响仍在扩大 | 立即 kill/隔离并停止所有 Phase 实施；`30` 分钟内通知 Security owner；`1` 小时内形成初步影响范围；持续保全脱敏证据 | Security owner 书面解除前不得继续实施；所有现存 `accepted`/批准对受影响 SHA 失效 |
| `P1` | 测试发现可达的越权/RLS/HITL 绕过、高风险审计缺失、Critical/High 供应链风险但无已知生产暴露 | 当日建立 BLK 与停止受影响 TASK/路径；`24` 小时内提交可验证修复方案并重跑相关 gate | 未关闭时 Phase 不得 `accepted`；任何已有条件批准失效 |
| `P2` | 风险被隔离在测试/非生产，或重试、SSRF、恢复、审计完整性存在可控缺口 | 发现后尽快立档，最迟 `72` 小时内有 owner、修复计划和验证命令；Phase 验收前关闭 | 未关闭即强制拒绝该 Phase，除非合同明确 `not_applicable` |
| `P3` | 不直接改变安全结果的防御纵深、性能型安全隐患或非强制字段缺失 | 在本 Phase acceptance 记录 owner、到期日和验证条件；下一 Phase 入口回归前关闭 | 未按期关闭则下一 Phase `blocked`；不得长期滚动延期 |

严重度计时从首个可复验或可信告警出现时开始，不因周末、换人、重复复现或“正在调查”重置。P0/P1 不得接受风险 waiver；P2/P3 的任何延期也不得把 mandatory gate 改成通过。安全事件的 blocker 必须引用触发规则、通知时间、kill/隔离动作、影响范围、证据保全位置与 owner 解除决定。

### 5.4 已暴露 secret 的时间承诺

Phase 0 对已在受跟踪客户端代码中出现的模型凭据按 P0 处置。事件时钟 `incident_first_seen` 取安全系统首次可信告警或最早可复验发现时间，不能取较晚的 TASK/Phase 进入时间；若只能事后确定，使用能够证明的最早时间并把不确定性写入事件报告。本文 §1.1 已记录可信暴露事实，执行时若时限已过，必须标记 SLA breached 并立即处置，不能获得新的宽限期。

从 `incident_first_seen` 起：`30` 分钟内通知/隔离并建立 P0 记录，`1` 小时内形成初步影响范围，`4` 小时内由获授权人员启动供应商侧轮换，`24` 小时内撤销旧 key；`revoked_at` 后 `2` 小时内完成新 key 的服务端 Secret Provider 配置。权限、owner 或供应商访问未就绪时立即建立 P0 blocker 并继续升级，所有时钟照常运行；其他只读取证 MAY 继续，但任何 Phase 不得 accepted。

验证 MUST 通过不回显凭据的受控 Secret Provider/供应商审计完成：旧 credential ref 调用返回 `401/403` 或供应商明确的 revoked 状态；新 credential ref 的最小健康调用成功；当前树、构建产物、客户端包、CI/命令输出、运行日志和网络中的 `live_secret_match_count=0`；全历史扫描的 `new_history_findings=0`。历史旧值不得改写删除，而在 `revoked-history-registry.json` 中只保存不可逆 fingerprint、批准的既有 occurrence-set hash、最早 commit/path 引用、`revoked_at` 与供应商 receipt hash；`historical_revoked_match_count` 可以非零，但必须精确等于批准的既有集合，任何新 commit/路径出现同 fingerprint 都是失败。命令、HTTP 状态、时间和 owner receipt 进入脱敏证据，原 secret 不进入本文、CLI 或报告。

本文件其他位置的“secret scan/leak 为零”均指 live/current/build/CI/network 命中与新历史发现为零，不要求伪造全历史总命中为零；scanner 仍须扫描全历史并核对 revoked registry。

## 6. 核心运行时合同

本章解决“实现可以怎样变化，但哪些运行时不变量绝不能被改掉”的问题。

### 6.1 不变量

- `GoNowAgentState` 只保存可序列化业务事实和引用。身份凭据、secret、client、连接池和 provider 对象由 runtime context 注入；完整 transcript、Prompt、原始 Tool body 和 reasoning 不进 checkpoint。
- Run 终态不可逆，所有转移用状态白名单、CAS 与 fencing；cancel intent 与终态分离，晚到成功不能覆盖已赢得 CAS 的取消。
- Run 创建时固定完整 Behavior Package：Graph、State、Prompt、Context、Tool、Model、Schema、Eval、SLO、预算和回滚引用。运行中不得随 deployment pointer 漂移。
- manifest digest MUST 先做 schema normalize，再使用 RFC 8785 JCS 与 SHA-256，并提供 Dart/Python 跨语言 test vector。
- Prompt/Behavior 的不可变 release 与可变 deployment pointer 分离；pointer 只能通过 generation CAS 前移。旧 Run 永远引用原 release。
- Tool Registry 使用静态 allowlist；Release B 最多三类只读 Tool `[硬约束]`，每个 `ToolSpec.max_attempts` 只能取 `1` 或 `2` `[硬约束]`。未知 Tool 返回稳定安全 JSON，绝不执行 fallback。
- `PhysicalInvocationLedger` 在真实 handler 前以同一事务完成预算条件更新和 reservation；`(run_id, tool_call_id)` 唯一。相同 fingerprint 回放，参数不同冲突；未知第三方结果不退还物理预算。
- Evidence Gate 把结果分为 `verified_current`、`unverified`、`stale`、`conflicted`、`invalid`。只有当前已验证证据可支持事实；HTTP 成功不等于业务事实正确，外部失败不等于事实不存在。
- Context Compiler v0 确定性记录切片、来源、Token、变换与丢弃原因；必需硬约束放不下时拒绝继续。Release B 不做隐式长期 Memory。
- 供应商差异只经 `ModelGateway` capability adapter 暴露。reasoning 默认不展示、不记录、不入评测/checkpoint；若同一调用的后续 Tool turn 必须原样回传 opaque reasoning block，只能在受控内存中短生命周期原样透传，既不改写也不持久化。Prompt cache 只复用稳定、低敏、同 tenant 且同工具集的前缀；ZDR、数据驻留或保留政策不允许时必须关闭，不得预先承诺节省比例。
- bounded repair 最多两轮 `[硬约束]`，仅产出局部补丁；不得擦除硬冲突。no-progress、预算或新授权需求触发停止。
- Domain Command 包含 server-derived principal、typed ops、expected version、command hash 和批准凭证；正式写以 CAS 与 outbox 同事务完成。
- PostgreSQL 为每个业务事件分配 `BIGINT seq`，以 `UNIQUE(run_id, seq)` 保证同一 Run 内严格递增、无重复/逆序；EventWriter 必须用 per-Run 行锁/等价数据库串行化使较小 seq 先提交可见，禁止较大 seq 已被 SSE 回放后才出现较小 seq。事务回滚或共享数据库 sequence MAY 产生间隙，间隙不等于事件丢失。`Last-Event-ID` 回放同一 Run 中 `seq > id` 的持久事件；心跳不占业务序号，也不能伪造业务事件。
- EDD 使每次 Behavior 变更可追到 digest、离线数据集、灰度结果、成本、owner 和回滚版本；未校准 Judge 不能独自阻断或放行。
- Release B 内部 Tool 不使用 MCP。未来外部 adapter 只有在互操作需求、身份、协议版本、能力发现、幂等、取消、恢复、大小/时间限制、错误映射和隔离测试获批后才 MAY 启用；禁止动态工具市场。
- 跨系统时钟只用于时间窗、审计和 SLO，不用于决定因果顺序。`agent-api`、`agent-worker` 与 PostgreSQL 主机相对批准的 NTP 源偏差超过 `1` 秒必须告警；超过 `5` 秒时 readiness 为 false、停止领取新 Run/执行高风险写，但继续允许安全排空与取消。JWT `clock_skew_tolerance` 显式固定为 `300` 秒，并测试边界内 `299` 秒与边界外 `301` 秒；不得由客户端传入。Run/Event 的 `created_at` 由 PostgreSQL 生成，事件顺序只以数据库分配的 `BIGINT seq` 与 CAS 为准；seq 严格递增但可有间隙，MUST NOT 声称 wall clock 或 seq 连续无洞，也不得用应用层 `datetime.now()` 排序。

“最多六个可解释业务阶段”和“每 Run 最多八次物理 Tool 调用”均为 `[初始假设，需上线校准]`，不得写成框架事实。业务阶段、Graph super-step、LLM、Tool、repair、Token/成本、wall deadline 与 no-progress 必须分别持久计数。阈值可经数据与 owner 修订；但某个 Behavior Manifest 一旦发布，其 Run 在终态前 MUST 严格遵守固定上限，不能临时放宽。

Phase 2 起，每次部署门禁 MUST 运行平台适配的 NTP 检查（Windows `w32tm /query /status`，Linux `chronyc tracking` 或等价受管信号），并把 source、stratum、last sync、offset、退出码保存为结构化证据；只保留终端截图或只检查进程存在不算通过。隔离 CI 若没有可信 NTP 源应标 `blocked`，不得伪造偏差。JWT 边界与 DB sequence 的机械测试分别属于 AuthVerifier 单元测试和真实 PostgreSQL 集成测试。

### 6.2 Run 状态机、发布生命周期与执行顺序

Run 采用 at-least-once 调度，不承诺 exactly-once。系统通过唯一约束、CAS、fencing、幂等 receipt、调用账本和 reconciler，让重复观察最终只产生一个业务效果。

状态枚举固定为：事务内初始态 `created`；已提交非终态 `queued|running|waiting_input|resuming|recovering|cancelling`；终态 `succeeded|blocked|failed|cancelled`。`created` 只在 Run 创建事务内部存在，不得作为已提交孤儿态对外可见。终态没有任何出边；下表没有通配符，未明确列出的来源/目标组合一律拒绝。

| 转移 | 进入条件 | 不变量与恢复 |
|---|---|---|
| `created → queued`（同一创建事务） | 输入、身份、Run、幂等记录、version manifest、首事件与 durable job 全部写入，事务末尾把 Run 置为 `queued` | commit 成功后只观察到完整 `queued`；失败全部回滚，不留下 `created`/job/幂等半状态；commit 结果未知时按幂等 key 查询 reconcile，禁止盲重建 |
| `queued → running` | Worker 取得 PG job、lease 与最新 fencing token | lease 失败不执行；readiness 不健康停止领新任务 |
| `running → waiting_input` | 缺少高影响信息、遇到风险或需要 Candidate 批准 | checkpoint 与 typed interrupt 先持久化，写失败不得对外宣称等待 |
| `waiting_input → resuming` | server-issued interrupt ID、principal、schema、一次性 resume receipt 均有效 | 必须同 Thread；重复请求回放；旧 interrupt 只能消费一次 |
| `resuming → running` | resume receipt、checkpoint 与新 lease/fencing 已持久化 | 任一步失败保持可重放 `resuming`，不得二次消费授权 |
| `running → recovering` | Worker 死亡、lease/heartbeat 过期 | 新 Worker 以更高 fencing token 获恢复权，旧 Worker 的 event/candidate/terminal 写全部拒绝 |
| `recovering → running` | 新 Worker 恢复 checkpoint、job 与 ledger，并持有最新 lease/fencing | 恢复失败保留 `recovering` 供有界重试/reconcile；旧 token 永久拒绝 |
| `{queued, running, waiting_input, resuming, recovering} → cancelling` | 用户 owner 或系统 deadline 的 cancel intent 已持久化 | HTTP/SSE 断开不是取消；各安全边界传播；重复 intent 回放 |
| `cancelling → cancelled` | cancel intent 在下一安全边界赢得终态 CAS | 后续结果丢弃，不再写新 Candidate；已提交真实副作用只能用批准的补偿命令撤销 |
| `{running, resuming, recovering} → succeeded` | typed Candidate 已持久化，投影、event/outbox 与不变量完成 | 终态 CAS 唯一胜者；重复完成回放原 receipt |
| `{queued, running, waiting_input, resuming, recovering} → blocked` | 硬冲突、证据缺口或预算耗尽但可解释 | 返回 Issue/Evidence/partial，不产生未经批准的正式写 |
| `{queued, running, waiting_input, resuming, recovering} → failed` | 不可恢复内部错误或权威依赖超过 deadline | 保存稳定错误码与最小调试引用，不泄漏 stack/Prompt/token |

Behavior 生命周期与 Run 生命周期不得混用。内容 revision、认证证据和环境 pointer 分离：`draft → offline_qualified → replay_qualified → shadow_observed → canary_approved → active`；随后可 `deprecated/retired/quarantined`。任何依赖 digest 改变都产生新 package；P0/P1、跨租户、越权 Tool、未授权记忆或成本失控必须停止分配新 Run 并 quarantine。退役前需排空/迁移活跃 Run、结束旧客户端和回滚窗口，并按保留政策处理证据。

一次请求的固定顺序如下：

1. 入口顺序固定为 RateLimiter(IP) → AuthVerifier → RequestContext → TenantScope → AuthorizationPolicy → RateLimiter(principal) → IdempotencyGuard → FeatureFlags；随后在 PG 事务中写 Run、manifest、首事件、job 与幂等记录。
2. Worker 以 `SKIP LOCKED` 领取 job，取得 lease/fencing，检查 cancel；再按 Behavior/PromptRegistry + SchemaRegistry → StateGuard → BudgetManager/MultiBudgetLimiter 固定执行合同。
3. 模型链顺序为 ContextCompiler → ModelRouter → SecretsProvider → ModelGateway → OutputSchemaGuard。Context 只含当前 Goal、hard requirement、frontier 依赖、有效 evidence、允许 Tool 与剩余预算；不足则中断或停止。
4. Tool 链顺序为 ToolRegistry → ToolArgValidator → AuthorizationPolicy/TenantScope → PhysicalInvocationLedger reserve → ToolExecutor（CircuitBreaker + RetryPolicy）→ EvidenceLedger。任何一步拒绝都不能绕过到 handler。
5. invocation/evidence/snapshot 先持久化，再经 StateGuard → CheckpointAdapter → EventWriter → 可适用的 CitationAssembler → CandidateProjector；即使 schema 合法也不等于业务安全。
6. 用户采用时重新做 commit-time authorization、expected-version/CAS 和 approval 校验，在同一业务事务写正式表、receipt 与 outbox。
7. PIIRedactor 位于 audit/trace/eval 外发前；EventWriter 先写 PG，再由可选唤醒层通知 SSE。客户端用 GET Run 复核终态。外部调用超时且可能已产生效果时进入 `UNKNOWN_OUTCOME`，先 reconcile，禁止盲重试。

### 6.3 Harness 控制矩阵

本基线的 34 项状态均为 `contract_only`：远程主线没有实现。表中“首次 Phase”是根据 v1.6.1 §6 与 §29 做出的 `Target schedule inference`，不是当前完成状态。`S/I/D` 分别表示成功、非法输入、依赖失败/拒绝测试；控制一旦落地，三类测试均 MUST 存在，否则仍是 `contract_only`，不得用空壳或静默 no-op 伪装完成。

| # | 控制：职责；输入 → 输出 | 层与前置顺序 | 失败策略与稳定错误 | 最多三条禁止行为 | 必测证据 | 首次 Phase |
|---|---|---|---|---|---|---|
| 1 | `RequestContext`：形成请求上下文；HTTP/JWT/headers → principal ref、locale、timezone、trace | middleware；`AuthVerifier` 后、Policy 前 | closed；`context.invalid` | 不从 body 取 user_id；不存 token；不信客户端 tenant | S/I/D；缺 header、伪主体 | P2 |
| 2 | `AuthVerifier`：验证身份；Bearer → issuer/audience/alg/sub | middleware；`SecretsProvider/JWKS` 前置 | closed；`auth.invalid_token` | 不接受 `none`/新系统 HMAC；不由 header 扩 alg；不猜备用 issuer | S/I/D；token corpus、轮换 | P2 |
| 3 | `AuthorizationPolicy`：判定动作；principal/resource/action → allow/deny/obligations | service；Context、Tenant 前置 | closed；`auth.forbidden` | Prompt 不授予权限；策略不可用不放行；不信模型角色 | S/I/D；字段/资源/approval | P2 |
| 4 | `TenantScope`：固定租户；principal/workspace → tenant/ACL filter | middleware/repository；Auth 前置 | closed；`tenant.scope_missing` | 不全局后过滤；不接受覆盖 tenant；不跨主体缓存 | S/I/D；cross-tenant=0 | P2/P3 |
| 5 | `IdempotencyGuard`：合流重复请求；key/request hash → new/replay/conflict | middleware/repository；Auth/Context/Tenant/Policy 后，Run/Command 创建前 | closed；`idempotency.conflict`/409 | 不同 body 不复用；不二建 Run；不以内存为真相 | S/I/D；CT-001/002 | P3 |
| 6 | `RateLimiter`：限制请求；principal/IP/route → allow/retry-after | middleware；IP 限流在 Auth 前，principal 限流在 Context/Policy 后且 handler 前 | 高风险 closed；`rate.limit` | 不以 user text 作 key；不无限 retry；不依赖 Redis 真相 | S/I/D；故障降级、边界 | P2 |
| 7 | `BudgetManager`：管单 Run 预算；policy/usage → remaining/stop | service/node guard；Run 前置 | closed→safe terminal；`budget.exhausted` | 不用模型自报；不事后计费；不跨 Run 借额 | S/I/D；并发 reservation | P4 |
| 8 | `MultiBudgetLimiter`：汇总物理与分支预算；state/ledgers/deadline → continue/stop | graph/repository；Budget、Ledger 前置 | closed；`budget.global_exhausted` | super-step 不冒充业务阶段；分支不借预算；不漏 no-progress | S/I/D；CT-011；P8 扩分支 | P4/P8 |
| 9 | `ModelRouter`：只选认证路由；task/risk/capability → route/reason | service；Behavior、Budget 前置 | closed；`model.no_certified_route` | 不选未认证模型；不跨区域泄漏；不以 LLM 自由路由 | S/I/D；固定路由回放 | P4 |
| 10 | `ModelGateway`：封装模型调用；typed request → typed result/usage/ref | service；Router、Secrets、Retry 前置 | Agent result closed、旧路径可降级；`llm.*` | 不泄露原文；不多层重试；不选主供应商外未认证 route | S/I/D；429/5xx/4xx/schema | P0 兼容网关（非 `agent-api`）/P4 Worker |
| 11 | `Behavior/PromptRegistry`：固定行为；release/version → digest/render refs | service/repository；Schema、Eval 前置 | closed；`behavior.not_qualified` | 不改不可变 revision；不绕认证；不只发布 Prompt | S/I/D；pointer CAS、CT-012/013 | P3/P4 |
| 12 | `ContextCompiler`：确定性装配上下文；state/evidence/profile → ContextPlan | service/node；Evidence、State 前置 | closed；`context.required_slice_missing` | 不截硬约束；不塞完整历史；不隐式 Memory | S/I/D；预算/丢弃/回放 | P4 |
| 13 | `StateGuard`：验证状态差分；before/delta → valid state | node wrapper；Schema 前置 | closed；`state.invalid_delta` | 不写 token/client；不越权字段；不接受 extra | S/I/D；序列化与非法转移 | P4 |
| 14 | `InterruptPolicy`：产生可恢复中断；risk/missing data → typed interrupt | node/service；State、Policy 前置 | closed；`interrupt.invalid` | 不泄露私密 payload；不跨 Thread；超时不批准 | S/I/D；resume consume-once | P6 |
| 15 | `ToolRegistry`：解析允许工具；name → versioned ToolSpec | service；Behavior、Flags 前置 | closed-safe JSON；`tool.unknown` | 不动态发现；不 fallback；不暴露任意 SQL/URL/file/shell/exec | S/I/D；CT-008 与禁止 Tool 安全集 | P4 |
| 16 | `ToolArgValidator`：规范化参数；raw call → canonical args/hash | service；Registry 前置 | closed；`tool.invalid_args` | 不接受 user_id；不接受 arbitrary URL/SQL；不宽松 Map | S/I/D；fuzz/schema | P4 |
| 17 | `ToolExecutor`：执行受控 adapter；spec/args/context → ToolResult/Evidence | service；Policy、Validator、Ledger 前置 | verified claim closed、可返回 unverified；`tool.timeout/provider_unavailable` | 不无界重试；不越域；不返回超限原始 body | S/I/D；timeout/redirect/size | P4 |
| 18 | `PhysicalInvocationLedger`：崩溃安全记账；call/fingerprint → reserve/replay/conflict | repository/service；Auth/Schema 后、handler 前 | closed；`tool.invocation_conflict` | 不先调用后 reserve；不回退已用额度；不复用异参 ID | S/I/D；CT-005/006 | P5 |
| 19 | `CircuitBreaker`：隔离 provider 故障；health → closed/open/half-open | service；Executor/Gateway 周边 | 当前调用 closed、服务可降级；`provider.circuit_open` | 不熔断业务 DB；不以 Redis 为唯一状态；half-open 不群发 | S/I/D；单飞与恢复 | P4 |
| 20 | `RetryPolicy`：统一重试责任；error/attempt/deadline → retry/stop | service；Gateway/Executor 调用 | 上限后 closed；`retry.exhausted` | auth/schema/CAS 不重试；不叠层；不越 deadline | S/I/D；retry amplification | P4 |
| 21 | `OutputSchemaGuard`：验证输出；model/tool output → typed value/issues | service/node；Schema 前置 | closed/repair；`output.schema_invalid` | 不 broad Map；不改硬冲突；修复不超两轮 `[硬约束]` | S/I/D；invalid/repair/no-progress | P4 |
| 22 | `EvidenceLedger`：保存证据状态；Tool/RAG result → immutable refs/status | repository；Invocation 后 | closed for claims；`evidence.invalid` | 不把 200 当 verified；不覆盖历史；不存 secret | S/I/D；stale/conflict/hash | P3/P4 |
| 23 | `CitationAssembler`：把 claim 连到证据；claims/refs → citations/coverage | service；Evidence 前置 | claims closed；`citation.missing` | 不伪造引用；不隐藏冲突；不引用失效源 | S/I/D；Tool coverage/conflict，RAG claim→chunk | P4 Tool evidence；P11 RAG 完整化 |
| 24 | `CheckpointAdapter`：持久恢复状态；thread/state → checkpoint IDs | runtime adapter；Runtime PG 前置 | closed/readiness false；`checkpoint.unavailable` | 不用 serializer 冒充 saver；不存 secret；不以 Redis 替代 | S/I/D；kill/replay/migration | P5 |
| 25 | `EventWriter`：写单调事件；domain/run event → seq/event_id | repository；Runtime PG 前置 | closed；`event.sequence_conflict` | 心跳不占 seq；不从 PubSub 重建；不跳序静默 | S/I/D；SSE replay/race | P3 |
| 26 | `CandidateProjector`：输出最小草案；internal state → Candidate/public view | service/node；Schema、Evidence 前置 | closed；`candidate.invalid_projection` | 不暴露 Prompt/token；不直写正式表；不丢 evidence | S/I/D；幂等与权限投影 | P4 |
| 27 | `PIIRedactor`：最小化敏感数据；payload → redacted/tags | middleware/service；log/trace/audit/eval/SaaS 出口前 | closed for export；`privacy.redaction_failed` | 不记录正文；不改写 reasoning 后回传；不保留明文副本 | S/I/D；synthetic canary | P0/P2 |
| 28 | `AuditLogger`：写安全/写入审计；event → append-only receipt | service/repository；Redactor 后、Command/Tool 周边 | 高风险 closed；`audit.unavailable` | 不复制 Prompt；不允许应用修改；不无 owner | S/I/D；篡改/缺失/权限 | P0/P2/P3 |
| 29 | `Telemetry`：输出脱敏信号；span/metrics → OTLP/links | middleware/wrapper；Redactor 前置 | business-open、export 可丢；`telemetry.export_failed` | 不阻业务于外部 SaaS；不高基数 PII；缓冲不无界 | S/I/D；exporter down | P2/P10 |
| 30 | `EvalHooks`：产出评测证据；trace/result → scores/dataset refs | wrapper/async；Redactor、Telemetry、Behavior 前置 | 在线 business-open、发布 closed；`eval.unavailable` | Judge 不改业务；不把生产原文入集；不伪造样本 | S/I/D；校准/holdout | P4/P10 |
| 31 | `FeatureFlags`：控制路由；principal/tenant/version → route flags | middleware/service；Context/Policy/Idempotency 后、Behavior/route 前 | Agent path closed、回旧路径；`feature.disabled` | 不删除 fallback；不改变运行中 manifest；kill switch 优先 | S/I/D；flag-off 等价 | P0/P2/P4 |
| 32 | `SecretsProvider`：注入短期凭据；secret ref → in-memory client/value | service；Auth/Gateway/Tool 前置 | closed/readiness false；`secret.unavailable` | 不进 state/log/cache；不发 Flutter；不硬编码 | S/I/D；轮换/缺失/scan | P0/P2 |
| 33 | `SchemaRegistry`：管理合同版本；name/version → codecs/schema | service；所有 typed 边界前置 | closed；`schema.unsupported` | 不静默接 unknown major；不手改生成码；不删兼容版本 | S/I/D；OpenAPI/digest/compat | P1 合同/P2 启用/P3 数据 |
| 34 | `ConsistencyFence`：拒绝旧版本写；resource version/token → write permit | service/repository；Lease/CAS 前置 | closed；`consistency.stale_fence` | 不 force overwrite；不让旧 Worker 写终态；不跳 expected version | S/I/D；竞态/旧 Worker/CT-010 | P3/P5 |

任何 Harness 的输入、输出、失败策略、公开错误或依赖顺序若需要偏离本矩阵，MUST 先修订 ADR 与本文件。Phase 验收报告必须逐项声明 `implemented`、`contract_only` 或 `not_applicable`；`not_applicable` 必须给出当前 Release 不启用该能力的理由。

### 6.4 Harness 最少用例目录与机械验收

`S/I/D` 不是三个笼统标签，而是最少三条相互独立的测试：成功路径、非法/越权输入、依赖失败或拒绝。每条必须在版本化 `docs/execution/schemas/harness-test-catalog.yaml` 中有稳定 `case_id`、输入类别、精确 `expected_result`（返回值/错误码/副作用计数）和 pytest node ID。一个测试不得同时冒充多个类别；更高层集成测试不得替代这些单元边界。控制标为 `implemented` 时，下表最少用例必须全部存在且零 skip/xfail。

| # / 控制 | 最少独立用例（箭头右侧为必须断言的结果） | 目标测试文件 | 最少通过数 |
|---|---|---|---:|
| 1 `RequestContext` | 合法身份/headers→仅 server-derived refs；缺必要 header→`context.invalid`；body 伪造 user/tenant→不进入上下文；身份依赖失败→closed | `agent-service/tests/unit/harness/test_01_request_context.py` | 4 |
| 2 `AuthVerifier` | RS256 合法 claims→提取正确 `sub`；`alg=none`→拒绝；HS256 新路径→拒绝；过期→拒绝；错误 issuer→拒绝；错误 audience→拒绝；未知 `kid`→拒绝；旧 `kid` 从 JWKS 移除→拒绝；`nbf` +299s→按 300s 容忍；`nbf` +301s→拒绝；缺 Bearer→`auth.invalid_token`；非 Bearer scheme→同一安全错误；JWKS/Secrets 依赖不可用→closed 且 readiness=false | `agent-service/tests/unit/harness/test_02_auth_verifier.py` | 13 |
| 3 `AuthorizationPolicy` | 允许 action/resource/field→permit；禁止字段→`auth.forbidden`；伪 approval→拒绝；策略依赖不可用→closed | `agent-service/tests/unit/harness/test_03_authorization_policy.py` | 4 |
| 4 `TenantScope` | 合法主体→固定 tenant filter；缺 tenant→`tenant.scope_missing`；客户端覆盖 tenant→拒绝；两 tenant/cache canary→`leak_count=0`；tenant/ACL resolver 不可用→closed | `agent-service/tests/unit/harness/test_04_tenant_scope.py` | 5 |
| 5 `IdempotencyGuard` | 同 key/body→单 Run 回放；同 key/异 body→409；并发同 key→唯一胜者；repository 失败→不创建第二 Run | `agent-service/tests/unit/harness/test_05_idempotency_guard.py` | 4 |
| 6 `RateLimiter` | 额度内→允许；越界→`rate.limit` + Retry-After；store 失败→按风险 closed；IP 与 principal key 不受正文/伪 user 控制 | `agent-service/tests/unit/harness/test_06_rate_limiter.py` | 4 |
| 7 `BudgetManager` | 具体数值扣减→余额精确；硬上限→`budget.exhausted` 且 handler 零调用；并发 reservation→不超额；账本失败→closed | `agent-service/tests/unit/harness/test_07_budget_manager.py` | 4 |
| 8 `MultiBudgetLimiter` | 单分支正常；两分支原子共享预算→CT-011；非法/负 usage→拒绝；全局账本不可用→`budget.global_exhausted` | `agent-service/tests/unit/harness/test_08_multi_budget_limiter.py` | 4 |
| 9 `ModelRouter` | 简单/复杂输入→固定已认证 route/reason；未认证 route→`model.no_certified_route`；相同 manifest 回放→同 route；Registry 不可用→closed | `agent-service/tests/unit/harness/test_09_model_router.py` | 4 |
| 10 `ModelGateway` | typed 成功→结果/usage；429/5xx→仅责任层有限重试；4xx auth→零重试；schema invalid→安全错误；secret 缺失→closed/readiness false | `agent-service/tests/unit/harness/test_10_model_gateway.py` | 5 |
| 11 `Behavior/PromptRegistry` | 不可变 release 读取；修改既有 digest→拒绝；pointer generation 竞态→CT-012/013；registry 失败→`behavior.not_qualified` | `agent-service/tests/unit/harness/test_11_behavior_registry.py` | 4 |
| 12 `ContextCompiler` | 必需片段放入且预算精确；硬约束放不下→`context.required_slice_missing`；裁剪顺序确定性；Evidence 依赖无效→closed | `agent-service/tests/unit/harness/test_12_context_compiler.py` | 4 |
| 13 `StateGuard` | 合法 delta→新 state；extra/secret/client 字段→`state.invalid_delta`；非法转移→拒绝；Schema 依赖失败→closed | `agent-service/tests/unit/harness/test_13_state_guard.py` | 4 |
| 14 `InterruptPolicy` | 合法 interrupt/resume→一次消费；跨 Thread→拒绝；重复/过期 capability→拒绝；receipt 持久化失败→不宣称恢复 | `agent-service/tests/unit/harness/test_14_interrupt_policy.py` | 4 |
| 15 `ToolRegistry` | 已批准 Tool→versioned spec；未知 Tool→CT-008；SQL/URL/file/shell/exec 名称→拒绝且 handler 零调用；catalog 失败→closed | `agent-service/tests/unit/harness/test_15_tool_registry.py` | 4 |
| 16 `ToolArgValidator` | 合法参数→canonical hash；伪 `user_id/tenant`→拒绝；任意 URL/SQL/path→拒绝；schema/fuzz 非法输入→稳定 `tool.invalid_args`；SchemaRegistry 不可用→closed 且 handler 零调用 | `agent-service/tests/unit/harness/test_16_tool_arg_validator.py` | 5 |
| 17 `ToolExecutor` | 成功→typed result/evidence；timeout/provider unavailable→稳定错误；redirect/size 越界→拒绝；Policy/Ledger 拒绝→handler 零调用 | `agent-service/tests/unit/harness/test_17_tool_executor.py` | 4 |
| 18 `PhysicalInvocationLedger` | reserve 后 kill→CT-005；相同 fingerprint 回放→CT-006；同 call ID 异参→conflict；PG 失败→handler 零调用 | `agent-service/tests/unit/harness/test_18_invocation_ledger.py` | 4 |
| 19 `CircuitBreaker` | closed 成功；阈值到 open→拒绝；单个 half-open probe；恢复到 closed；状态依赖失败→有界安全降级 | `agent-service/tests/unit/harness/test_19_circuit_breaker.py` | 5 |
| 20 `RetryPolicy` | retriable 错误→批准次数；auth/schema/CAS→零重试；总 deadline→停止；检测嵌套责任层→拒绝放大 | `agent-service/tests/unit/harness/test_20_retry_policy.py` | 4 |
| 21 `OutputSchemaGuard` | 合法 typed 输出→通过；非法输出→局部 repair；第 2 轮后/no-progress→`output.schema_invalid`；Schema 依赖失败→closed | `agent-service/tests/unit/harness/test_21_output_schema_guard.py` | 4 |
| 22 `EvidenceLedger` | 当前有效证据→`verified_current`；stale/conflicted/invalid 分类；历史覆盖→拒绝；repository 失败→claim closed | `agent-service/tests/unit/harness/test_22_evidence_ledger.py` | 4 |
| 23 `CitationAssembler` | claim/有效 ref→citation；缺 ref→`citation.missing`；冲突 ref→显式冲突；Ledger 失败→不生成引用 | `agent-service/tests/unit/harness/test_23_citation_assembler.py` | 4 |
| 24 `CheckpointAdapter` | 保存/恢复最小 state；secret/Prompt 字段→拒绝；kill/replay→同一状态；PG 不可用→readiness false | `agent-service/tests/unit/harness/test_24_checkpoint_adapter.py` | 4 |
| 25 `EventWriter` | 单 Run 顺序写→seq 严格递增（允许间隙）；并发提交→无重复/逆序且低 seq 不晚于高 seq 可见；heartbeat→不占 seq；PG 失败→不对外发业务 event | `agent-service/tests/unit/harness/test_25_event_writer.py` | 4 |
| 26 `CandidateProjector` | 合法 state→最小 Candidate；Prompt/token/内部字段→不投影；重复投影→同 receipt；Schema 失败→`candidate.invalid_projection` | `agent-service/tests/unit/harness/test_26_candidate_projector.py` | 4 |
| 27 `PIIRedactor` | synthetic PII→替换且无明文；clean payload→不破坏；redactor 失败→不外发；opaque reasoning→不记录/不改写 | `agent-service/tests/unit/harness/test_27_pii_redactor.py` | 4 |
| 28 `AuditLogger` | 高风险动作→append-only receipt；receipt 缺失→动作阻断；篡改→拒绝/告警；repository 失败→`audit.unavailable` | `agent-service/tests/unit/harness/test_28_audit_logger.py` | 4 |
| 29 `Telemetry` | 脱敏 span/metric→符合 §9 schema；exporter down→业务按合同继续；buffer 满→有界丢弃/计数；高基数 PII label→拒绝 | `agent-service/tests/unit/harness/test_29_telemetry.py` | 4 |
| 30 `EvalHooks` | 脱敏结果→dataset/digest score；生产原文→拒绝入集；Judge 不可用→在线 open/发布 closed；未校准 Judge→不能独自放行 | `agent-service/tests/unit/harness/test_30_eval_hooks.py` | 4 |
| 31 `FeatureFlags` | flag on/off→新/旧确定路径；kill switch→优先关闭；运行中 Run→digest 不变；flag store 失败→Agent closed/旧路径保留 | `agent-service/tests/unit/harness/test_31_feature_flags.py` | 4 |
| 32 `SecretsProvider` | 合法 ref→仅内存注入；缺失→readiness false；轮换→旧 ref 失效/新 ref 生效；state/log/build scan→secret 零命中 | `agent-service/tests/unit/harness/test_32_secrets_provider.py` | 4 |
| 33 `SchemaRegistry` | 已支持 version→codec；unknown major→`schema.unsupported`；生成物/digest 不一致→拒绝；registry 不可用→closed | `agent-service/tests/unit/harness/test_33_schema_registry.py` | 4 |
| 34 `ConsistencyFence` | 当前 token/version→允许；旧 Worker token→`consistency.stale_fence`；并发 CAS→唯一胜者；repository 失败→拒绝写 | `agent-service/tests/unit/harness/test_34_consistency_fence.py` | 4 |

BOOT-005 工具供应与全量 bootstrap 复验完成后，Gate runner MUST 从 catalog 逐项运行，而不是依赖人眼看 pytest 文本。YAML 只允许由 BOOT-005 锁定、审计并写入 `toolchain-lock.json` 的 Python 解析器读取；PowerShell 不得调用未供应的 `ConvertFrom-Yaml`。`validate_harness_catalog.py --mode collect` 必须在同一进程完成 YAML 安全加载、Schema/语义校验和 pytest node 收集，并输出 `additionalProperties=false` 的规范化 JSON，至少含 `schema_version`、`catalog_sha256`、`controls[]`。下面是语义固定的 PowerShell 模板；报告路径按 Phase/TASK 生成：

```powershell
$CatalogPath = 'docs/execution/schemas/harness-test-catalog.yaml'
if (-not (Test-Path -LiteralPath $CatalogPath)) { throw 'Harness catalog missing' }
$PhaseEvidenceRoot = 'docs/execution/evidence/phase-XX' # 由 Gate runner 替换为当前 Phase 字面路径

$Toolchain = Get-Content -LiteralPath 'docs/execution/supply-chain/phase-boot/BOOT-005/toolchain-lock.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$PythonExe = [string]$Toolchain.python.executable
if (-not [System.IO.Path]::IsPathFullyQualified($PythonExe) -or -not (Test-Path -LiteralPath $PythonExe)) {
  throw 'Locked Python executable missing or non-absolute'
}
$CollectionReport = Join-Path $PhaseEvidenceRoot 'harness-catalog-collection.json'
& $PythonExe .\docs\execution\commands\validate_harness_catalog.py `
  --mode collect --catalog $CatalogPath --output $CollectionReport
if ($LASTEXITCODE -ne 0) { throw 'Harness catalog/collection validation failed' }
$Catalog = Get-Content -LiteralPath $CollectionReport -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($Control in @($Catalog.controls | Where-Object { $_.status -eq 'implemented' })) {
  $Report = Join-Path $PhaseEvidenceRoot "harness-$($Control.id).xml"
  & $PythonExe -m pytest $Control.test_file -v --tb=short --strict-markers "--junitxml=$Report"
  if ($LASTEXITCODE -ne 0) { throw "Harness test failed: $($Control.id)" }

  [xml]$JUnit = Get-Content -LiteralPath $Report -Raw -Encoding UTF8
  $Suite = if ($JUnit.testsuites) { $JUnit.testsuites.testsuite } else { $JUnit.testsuite }
  $Tests = [int](($Suite | Measure-Object -Property tests -Sum).Sum)
  $Failures = [int](($Suite | Measure-Object -Property failures -Sum).Sum)
  $Errors = [int](($Suite | Measure-Object -Property errors -Sum).Sum)
  $Skipped = [int](($Suite | Measure-Object -Property skipped -Sum).Sum)
  if ($Tests -lt [int]$Control.minimum_cases -or
      $Failures -ne 0 -or $Errors -ne 0 -or $Skipped -ne 0) {
    throw "Harness evidence incomplete: $($Control.id)"
  }
}

& $PythonExe .\docs\execution\commands\validate_harness_catalog.py `
  --mode results --catalog $CatalogPath --collection $CollectionReport `
  --junit-root $PhaseEvidenceRoot `
  --output (Join-Path $PhaseEvidenceRoot 'harness-catalog-results.json')
if ($LASTEXITCODE -ne 0) { throw 'Harness catalog/JUnit cross-check failed' }
```

锁定的 validator MUST 通过 pytest collection hook 读取每个测试的 `harness_case(case_id, category, expected_result)` marker，并机械校验：`case_id` 唯一；catalog/node ID 双向一一对应；category 只取 S/I/D 且每个 implemented 控制三类齐全；marker 与 catalog 的 expected result 完全一致且非空；逐控制/总 `minimum_cases` 等于 catalog 动态求和；JUnit 中每个 catalog node 恰好执行一次且零 failure/error/skip/xfail。两个 validator JSON、catalog 与 JUnit 的 hash 全部写入 gate result。`contract_only` 控制不得进入通过计数；`not_applicable` 只能按当前 Release 合同解释，不能靠空测试或 skip 伪造。

### 6.5 SSE 断线续传合同

Phase 6 第一个实现 TASK 前，Engineering/Security owner MUST 对 OpenAPI/Event Schema 中的 SSE 合同签字。Release B 的最低合同如下：

```text
event: run_created|run_queued|step_started|step_completed|tool_called|tool_result|candidate_ready|waiting_input|resuming|recovering|cancelling|cancelled|succeeded|blocked|failed
id: <当前 Run 内由 PostgreSQL 产生的十进制 BIGINT seq；客户端按字符串保存>
data: <由 SchemaRegistry 管理的单行 JSON，不含 secret、Prompt 正文或 reasoning>

```

- 两个业务事件之间有空行；`id` 只在当前 Run 的事件端点内有意义，MUST NOT 被解释为跨 Run 全局序号。客户端携带 `Last-Event-ID` 后，服务端查询同一 Run 的 `seq > Last-Event-ID` 并按升序重放。非法、未来、其他 Run 或非十进制 ID 以稳定安全错误拒绝。
- 业务事件超过批准的保留窗口后返回 HTTP `410`；`48` 小时只是 `[初始假设，需上线校准]`，必须在 Behavior/retention manifest 固定。收到 `410` 后客户端停止自动重连，显示“会话事件已过期”，并通过 GET Run 获取可用终态。
- 客户端重连延迟固定为第 1 次 `0ms`、第 2 次 `500ms`、第 3 次 `1000ms`，第 4 次起 `min(previous × 1.5, 30000ms)` 并加 `±20%` jitter，最多 `15` 次；manifest/客户端合同版本固定这些值，修改需 ADR。断线本身不是 cancel。
- 服务端每 `20` 秒发送 `event: heartbeat` 与 `data: {}`；heartbeat 没有业务 `id`、不写 event sequence，只重置连接存活计时。慢消费者必须有有界缓冲与明确断开，不得阻塞 EventWriter 或丢失持久业务事件。
- 合约测试必须覆盖无丢失重放、重复连接不重复业务副作用、并发订阅、非法/过期 ID、410、慢消费者、15 次重连停止、heartbeat 不占 seq 与旧客户端兼容。

## 7. 测试、质量与证据合同

本章解决“怎样用可重放证据证明改动，而不是用主观判断宣布完成”的问题。

### 7.1 当前工具与命令事实

本次 Windows PowerShell 核验发现：

| 工具 | 本机事实 | 文档处理 |
|---|---|---|
| Git | PATH 可用，`git version 2.52.0.windows.1` | MAY 使用下列 Git 命令 |
| Flutter | PATH 指向 stable SDK；SDK metadata 为 Flutter `3.41.7`、Dart `3.11.5`，满足本提交的锁文件基线；wrapper 因 sandbox 写状态而超时 | 命令语义可用，但本轮未宣称执行成功；Phase 在干净 worktree 重跑 |
| Dart | 直接 `dart.exe --version` 成功 | 当前主机格式检查使用已发现的绝对路径 |
| PostgreSQL client | PATH 不含 `psql`；`C:\Program Files\PostgreSQL\17\bin\psql.exe` 可用，版本 `17.10` | 只用于经批准连接；本轮仅验证版本 |
| Python | `python`/`py`/`pip` 不在 PATH；`uv` 的已安装 Python 清单为 `unknown` | Phase 2 前由 owner 安装、锁定并修订命令；不得伪造 pytest 已可用 |
| Supabase CLI | unavailable | Phase 0/3 前安装并锁版本，否则数据库本地门禁为 blocker |
| Docker/Podman/WSL 容器 | unavailable | 不能写成当前可运行；集成环境需另行提供 |

BOOT 的工具依赖 MUST 分为两个不可合并的阶段，防止 runner 验证自身时循环等待：

1. `TASK-BOOT-003` 的 `native` 阶段只允许已核验的 Windows PowerShell、Git、`Import-PowerShellDataFile`、`ConvertFrom-Json` 与 .NET 文件/加密 API；它创建并做语法/结构/哈希自测，但不得宣称 Python、YAML 或 Draft 2020-12 JSON Schema 验证已通过。
2. `TASK-BOOT-005` 供应并锁定 Python、Draft 2020-12 validator 和安全 YAML parser 后，必须执行 `BootstrapToolchainRevalidation`：全量验证 Catalog、全部 Schema/正反 fixture、两份 YAML、所有 Gate/PhaseMerge mode handler 与 runner 集成测试。结果和工具 hash 写入 evidence 后，才允许受限 `CatalogRevision`。
3. `local_provisional` 下，P00 本地实现可在 BOOT-003 的 native 结构/安全检查通过后开始；BOOT-004/005 与不依赖它们的 P00 工作并行推进。具体任务需要 Python、Schema/YAML validator、隔离 PostgreSQL 或 scanner 时，必须先供应相应能力或使用明确标记的本地替代测试，不能把 pending 当 passed。BOOT-005 `bootstrap_full_revalidation=passed` 仍是 Phase 0 正式验收、远程合并和发布前置，而不是全部本地编码的全局锁。

当前可复验的 PowerShell 模板只读取 BOOT-001 固定基线；不得在后续 Phase 以再次 fetch 后的 `origin/main` 重算 `BASE_SHA`：

```powershell
git --version
$ControlRepo = 'D:\GO_NOW-control'
$Worktree = 'D:\GO_NOW-agent-worktree'
$Boot1ReceiptPath = Join-Path $ControlRepo '.git\gonow-bootstrap\BOOT-001.native.json'
$Boot1Receipt = Get-Content -LiteralPath $Boot1ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$BASE_SHA = [string]$Boot1Receipt.base_sha
git -C $ControlRepo cat-file -e "$BASE_SHA^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Pinned BOOT-001 base commit is unavailable' }
git -C $ControlRepo show --no-patch --format='%H%n%cI%n%s' $BASE_SHA
git -C $ControlRepo ls-tree -r --name-only $BASE_SHA -- .github test integration_test supabase pubspec.yaml pubspec.lock analysis_options.yaml
git -C $Worktree status --porcelain=v1

$Flutter = (Get-Command flutter -ErrorAction Stop).Source
& $Flutter pub get
& $Flutter analyze
& $Flutter test
& $Flutter test .\test\amap_service_test.dart

$DartExe = 'D:\flutter\flutter_windows_3.41.7-stable\flutter\bin\cache\dart-sdk\bin\dart.exe'
& $DartExe format --output=none --set-exit-if-changed .\lib .\test
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' --version
```

所有 Flutter 命令 MUST 从仓库根运行。BOOT-005 建立锁定 Python 环境并完成 `BootstrapToolchainRevalidation` 后，`execplan.md` 才能执行真实 `$PythonExe -m pytest ... --junitxml=...` 命令；在此之前 Python 测试命令状态为 `pending_boot005`，不是可跳过的通过项。Phase 2 只创建 Agent service/Python 项目结构与业务依赖，不承担 bootstrap 解释器供应。

### 7.2 测试层次

每层都解决不同问题，MUST 作为独立 suite 运行并产生独立结构化报告；上层通过不能替代下层，代码覆盖率也不能替代合同边界。最低要求按“每个适用边界”计数，不允许用一个包含很多断言的测试凑数。

| 层 | 必须在本层直接覆盖的最低要求 | 禁止替代/伪证据 |
|---|---|---|
| Flutter unit | 每个受影响 Provider/serializer/重连状态机至少覆盖成功、非法/空输入、依赖失败；旧 fallback、active-run 持久化与 Dart schema 每条分支有确定断言 | 不用 widget/E2E 替代纯状态和序列化边界；不发真实网络 |
| Flutter widget/integration | 每个受影响用户旅程至少有正常、离线/超时、权限拒绝/恢复三条；普通聊天、导入、Auth、fallback 与 Candidate adopt 分别留有回归 | 不能只跑 AMap 单文件、截图或 golden 人工看图代替交互断言 |
| Python unit | §6.4 已实现 Harness 的最低数由 catalog 对 `minimum_cases` 动态求和；v1.4.0 当前 34 项全实现的静态下限为 `149` 条，且每项 S/I/D 齐全；§6.2 每条状态转移至少一条合法和一条非法来源；每个 JSON Schema 各有合法与每类非法输入；Context 裁剪、预算、retry/deadline 使用具体数字 | 禁止真实 DB/HTTP；使用 fake/MockTransport；一条测试只验证一个行为，不能推给 integration |
| contract | 每个已发布 OpenAPI request/response、Dart/Pydantic codec、SSE event、error code 与兼容 major 至少正反各一条；每个适用 `CT-001..015` 有稳定 node ID 和 producer/consumer 双边验证 | 不以宽松 `dict/Map`、单边 snapshot 或人工看 JSON 代替；实现与合同版本必须显式绑定 |
| integration | 每个 migration 在真实 PostgreSQL 覆盖空库、已有数据、重复执行与 downgrade/forward-fix；每项 RLS 用至少两个 principal × 两个 tenant 正反矩阵；事务、锁、CAS、lease、outbox、`SKIP LOCKED` 有并发断言 | mock/SQLite/Supabase Dashboard 截图不能替代真实 PG 语义 |
| replay/chaos | 每个物理副作用边界至少在“调用前、reservation 后、结果持久化前后、终态前”可适用位置 kill/replay；cancel/lease/fencing/reconciler 最终都收敛且副作用计数精确 | 不只抛一个异常假装进程死亡；不只验证 HTTP 状态而忽略账本/DB |
| security | §5.2 每个适用类别至少一条允许、一条攻击/拒绝、一条依赖失效；所有 P0/P1 历史回归与适用 CT 必跑；真实 PG 验证 tenant/RLS | 静态扫描不能替代动态授权/RLS/SSRF/Tool/PII canary，反之亦然 |
| eval | E0/E1 的 manifest、dataset hash、evaluator digest、slice 分母与 holdout 分离；hard requirement/失败 slice 100%，Judge 只有完成校准才可参与 | 不用单一平均分、变化过的样本、生产原文或未校准 Judge 放行 |
| performance/cost | 预先固定负载、并发、热身、重复次数、价格快照和环境；报告 p50/p95、Token、物理 Tool、队列、资源与每成功且采用任务成本及置信范围 | 不把本地小样本/供应商估价说成生产；失败任务不得从成本分母静默删除 |

EDD 的 Release B 数据集名称固定如下，防止后续计划只写缩写：`E0 PR 关键旅程集` 覆盖普通规划、硬约束、Tool 失败、Schema、取消/重放、越权和旧路径兼容，建议 `40–60` 条 `[初始假设，需上线校准]`；`E1 单规划 Behavior 分层集` 按城市、语言、预算、时长、无障碍、故障和攻击分层，建议 `150–300` 条且边界/失败样本不少于 `20%` `[初始假设，需上线校准]`。两者都必须把 baseline、近期失败与 holdout 分开；确定性 mandatory gate 的通过率仍为 `100%` `[硬约束]`，样本数不能替代风险覆盖和 owner 评审。

E0 在 Phase 4 Graph 实现前必须先版本化建立：至少 `30` 条主要规划请求与 `10` 条边界/矛盾/无效请求（合计下限 `40`，属于上述范围）；每条使用不会因插入而重排的稳定 ID，包含输入、hard requirement、期望失败方式和机器评分字段。E1 同样使用稳定 ID 与分层 manifest。数据只允许合成或经批准的去标识材料；真实城市名可以使用，真实用户行为、账号、精确轨迹和正文不得进入 Git。

每次评测 MUST 绑定 dataset SHA-256、manifest version、evaluator/Prompt/Behavior digest、生成许可、敏感级别、保留/删除策略和执行 head Git OID/object format。Product owner 书面确认场景覆盖，Eval owner 确认评分可机械重放，Privacy/Data owner 对任何非纯合成来源批准。baseline、近期失败与 holdout 目录和访问权限必须物理或逻辑分离；执行者不得查看后再修改 holdout。样本修订产生新版本，不覆盖旧版本；删除请求由 deletion ledger 传播到 dataset、cache、trace/eval 引用和恢复副本。

多文件 E0/E1 的 canonical dataset digest 算法固定为：把目录内除 manifest 自身外的文件转成 `/` 分隔的 POSIX 相对路径；拒绝 `..`、绝对路径、重复路径和 Unicode/case-fold 冲突；按 UTF-8 字节序排序；逐文件记录原始字节的 SHA-256 与 `size_bytes`（不得先改换行或编码）；把 `{path,sha256,size_bytes}` 列表与 dataset metadata 按 RFC 8785 JCS 规范化后再做 SHA-256。manifest 同时保存生成器版本、Git object format/完整 tree OID；Git OID 与 canonical dataset SHA-256 分字段，Windows/Linux 对同一字节集必须得到相同 test vector。

mandatory suite 必须 100% 通过 `[硬约束]`。覆盖率只是辅助；权限边界、状态转移、崩溃窗口和失败路径必须有显式测试。flaky test 必须立档找根因，不得重跑到绿。

当前 `flutter analyze`/全量测试不是绿基线：陈旧 widget test 静态引用错误已由代码证明，架构审计也记录现有 analyzer 问题。Phase 0 MUST 先生成结构化 baseline，采用 `new_errors = 0` 的 ratchet `[硬约束]` 并批准清零目标；现有问题不能成为新增问题的借口。最终 Release gate 仍要求命令退出码为零 `[硬约束]`。

### 7.3 稳定合同测试 ID

`execplan.md` 的 TASK 与 Phase gate MUST 反向引用下列 ID：

| ID | 合同 |
|---|---|
| `CT-001` | 同 principal/route/key 且同 body 只创建一个 Run，后续回放原结果 |
| `CT-002` | 同 key 不同 body 返回 409 |
| `CT-003` | JWT `alg=none` 被拒绝 |
| `CT-004` | 新系统 JWT HMAC 被拒绝；遗留验证只走隔离受控路径 |
| `CT-005` | Tool reservation 后 kill Worker，恢复不超过物理预算 |
| `CT-006` | Tool result 持久化边界 kill/replay，不重复副作用或扣费 |
| `CT-007` | 跨租户检索/读取结果为空，`acl_leakage_count=0` `[硬约束]` |
| `CT-008` | 未知 Tool 返回安全 JSON 且无 fallback 执行 |
| `CT-009` | negative consent 阻止对应 Memory 写入和重新挖掘 |
| `CT-010` | cancel intent 在下一安全边界停止并收敛到合法终态 |
| `CT-011` | 并行 branch 共用全局预算，原子 reservation 不超上限 |
| `CT-012` | Behavior digest 切换只影响新 Run |
| `CT-013` | deployment pointer 竞态只有一个 generation CAS 成功 |
| `CT-014` | solver 超硬 deadline 被父进程 kill，主服务存活且 Run 收敛 |
| `CT-015` | Memory 删除后，结构数据、vector/cache 与 eval/trace 引用均不可恢复读取 |

Release B 不实现 Memory，故 `CT-009/015` 必须标为 `contract_only:not_in_release_b`，不得用假实现、空断言或 skip 标绿。`CT-014` 在 solver 未启用时标 `not_applicable:solver_disabled`；一旦 Phase 7 启用即成为 mandatory。

### 7.4 证据格式

- `commands.json`、`gate-results.json`、`artifact-hashes.json` MUST 分别符合 `docs/execution/schemas/commands-v1.schema.json`、`gate-results-v1.schema.json`、`artifact-hashes-v1.schema.json`；schema 尚未由 BOOT 工具任务创建时为 `blocked`，不得让每个 Phase 自创格式。
- `commands.json` 至少包含 `schema_version/task_id/phase/executed_at/executor/git_object_format/head_oid`，以及逐步的 `step/description/command/exit_code/stdout_tail/stderr_tail/duration_seconds`。stdout/stderr 只保存脱敏末尾和 hash，默认上限 `200` 字符；含 secret/PII 的输出必须完全省略并记录 redaction reason。
- `gate-results.json` 至少包含 `schema_version/task_id/gate_run_at/git_object_format/head_oid/phase_base_oid/tool_versions/results/overall_status`；每个 result 含稳定 `check_id`、`passed|failed|blocked|not_applicable`、detail、evidence path/hash。overall 只能由生成器按最坏结果计算，人工不得覆写。
- `artifact-hashes.json` 至少包含 `schema_version/task_id/git_object_format/head_oid/artifacts[]`；每项含仓库相对路径或受控对象永久引用、`sha256`、`size_bytes`、MIME/type、`generated_by_step`、生成时间、敏感级别和保留期。路径、hash 或大小不一致即失败。
- `task-status-v1.schema.json` MUST 固定 plan/catalog 版本与 hash、唯一 task/phase、合法状态边、CAS previous hash/sequence、完整 OID、owner/actor、profile-specific acceptance、evidence hash/path、blocker 和永久决策引用；`harness-status-fragment-v1.schema.json` MUST 固定 control/action、exact test path、S/I/D node、collection/JUnit hash、计数与绑定 head。二者同样 `additionalProperties: false`，并以正反 fixture 拒绝陈旧 CAS、非法转移、伪 node、skip/xfail，以及 enterprise 缺独立批准或 personal 缺自动 attestation。
- `task-gate-catalog-v2.schema.json` MUST 固定 Catalog 顶层键、153 个唯一 TASK、23 个 TaskGate mode、11 个 PhaseMerge mode、handler/capability/stage、任务 allowlist/work contract/approval/status/evidence 字段，并拒绝未知 mode、缺 handler、重复 status path、未解析 capability、环境变量 executable 与额外字段。
- 六个 schema 均 MUST `additionalProperties: false`、版本化并有正反 schema tests；时间使用带时区 ISO 8601；`git_object_format` 与完整 Git OID 按 §16.4 记录；artifact SHA-256 使用 64 位小写十六进制。命令中的 secret 必须使用引用，不得把值序列化进证据。
- CI MUST 消费 JUnit、JSON、SARIF 或 YAML 等结构化结果，不得用 `grep` 猜成功。Flutter adapter 尚不存在时必须在对应 Phase 创建并测试，不能手写结论 JSON。
- 证据放在 `docs/execution/evidence/phase-XX/`；只提交命令、退出码、结构化报告路径与 SHA-256、CI URL、commit SHA 和脱敏摘要。大日志、真实数据和 secret 不进 Git。
- 基线与候选必须使用相同 suite、dataset 和 evaluator version。任何 waiver 都要有 owner、到期时间、风险与补跑条件；mandatory gate 无 waiver。
- 完成标准不得写“功能正常”“质量良好”“审查通过”；必须写具体合同、查询、退出码、指标、样本范围与 owner 结论。

### 7.5 通用机械门禁

每个门禁只能产生 `passed`、`failed`、`blocked` 或 `not_applicable`。`passed` 必须有绑定 head Git OID/object format 的机器结果；`failed` 必须保留首个失败证据；`blocked` 表示所需工具、权限或外部事实尚未就绪；`not_applicable` 只表示当前 Release 明确不含该能力，并附合同依据。`skipped`、`waived_pass`、人工改成绿色或只贴终端截图都不是合法结果。

| 门禁 | 机械判定 | 失败动作 |
|---|---|---|
| 范围 | 变更路径逐项属于 TASK allowlist；生成文件可追到生成源；`git diff --check` 成功 | 出现意外文件即 `failed`，先拆分或回滚，不顺手纳入 |
| 构建与类型 | 锁文件未漂移或漂移有依赖审查；格式、静态分析、编译命令退出码为零；报告绑定工具版本 | 不得扩大 ignore；记录首个错误并按 ratchet 修复 |
| 安全与隐私 | secret/PII、JWT、授权、跨租户、RLS、SSRF、SQL、Prompt Injection、Tool/approval 套件全部执行；高危和泄漏为零 `[硬约束]` | 立即阻断、必要时 kill switch；按严重度建安全事件/blocker |
| 数据库 | 空库重建、已有数据升级、RLS/grant diff、锁预算、重复执行、并发、恢复与删除账本重放均有结构化结果 | 不准部署 migration；若生产事实未知则退回只读盘点 |
| 可靠性 | 真实 PG 下的 kill/replay、lease/fencing、cancel、竞态、幂等、deadline 与 reconciler 全部收敛 | 任一重复副作用、双终态或永久卡死均为发布阻断 |
| 兼容 | 普通聊天、导入、Auth、fallback、旧 App/Event/Worker 的明确回归集通过 | 保持旧 flag 路径；不能以强制升级或删兼容层解决 |
| 行为质量 | 相同 dataset/evaluator 上比较基线与候选；每个 hard requirement、关键 slice 和失败类单独报告 | 关键 slice 退化或证据污染即拒绝；不以平均分抵消 |
| 性能与成本 | 用同一负载、重复次数和价格快照报告 p50/p95、队列、Token、Tool、资源和每成功且采用任务成本 | 无真实样本写 `unknown`；超批准预算则降级/停止，不编造收益 |
| 可观测 | 能以脱敏标识关联 Run、Behavior、错误、evidence、usage；SLO、alert、runbook、owner 和 kill switch 可查询 | 缺关键字段或外部平台成为单点即 `failed` |
| 回滚 | 在隔离环境实际执行 flag/route/image/schema/alias 回切；验证旧客户端、旧 Behavior 和已写数据仍可用 | 演练失败不得合并；禁止用删除新数据伪装回滚 |
| 交付审批 | acceptance、artifact hash、blocker、回滚结果齐全；工程与安全 owner 独立签名未过期 | Agent 保持 `ready_for_review` 或 `blocked`，不得自改 accepted |

报告生成器 MUST 从原始结构化结果计算摘要，并保存生成器版本与输入哈希；人工只可追加解释和批准，不得修改计数、退出码或测试状态。若同一命令重复运行结果不同，先按 flaky/环境漂移立档，禁止选择性提交绿色那次。

### 7.6 回滚演练最低协议

每个 Phase 在 `ready_for_review`、适用 profile acceptance 前 MUST 在与生产拓扑和配置语义一致但不含生产 secret/用户数据的隔离环境实际演练。文档推演、只把 flag 值写回、删除新数据或口头说明都不算演练。

1. **静止状态回滚**：没有进行中 Run 时，按 runbook 回切 feature flag、route、image、Behavior pointer、schema 兼容路径或 alias，验证旧关键旅程端到端与全部适用旧 mandatory gate `100%` 通过。
2. **进行中工作回滚**：能力涉及 Run 时，至少启动 `N≥3` 个分别位于不同安全边界的 Run 后回切；已开始 Run 继续固定原 manifest，新 Run 走回退路径，最终全部收敛到 `succeeded|cancelled|failed|blocked` 中合同允许的终态，不能出现 `stuck/unknown` 或重复副作用。不涉及 Run 时必须写明不适用合同，并用至少三个可并发的在途操作演练等价边界。
3. **数据/客户端兼容**：新版本已写的扩展字段、事件和 Candidate 可被旧 Worker/旧 Flutter 安全读取或忽略；旧客户端、旧 Behavior 和正式业务数据仍可用。回滚不得依赖删新数据。
4. **失败信号**：回切后持续 `5` 分钟观察结构日志、安全 canary、error rate、outbox/reconciler 与关键 SLO；新增 error、非法终态、RLS/授权差异、未投递 outbox 或重复账单任一非零即失败。
5. **时限与证据**：记录触发条件、授权者、开始/结束时间、从命令发出到全部验证通过的实际秒数、批准 RTO/RPO 及差值、每条命令/退出码、base/head Git OID/object format 和 artifact hash。RTO/RPO 尚为 `unknown` 时不得声称达标，先由 owner 批准目标。

演练失败时 Phase 保持 `ready_for_review` 或 `blocked`，建立 blocker 并修复后完整重演；不得协商为通过。任何生产演练、真实资源切换或数据库写入仍需要另行显式授权，本协议本身不授予该权限。

## 8. 数据库与迁移合同

本章解决“怎样改变数据库而不靠猜表、不越权、不丢数据且能恢复”的问题。

### 8.1 数据职责与写者

目标数据库边界按用途而不是按框架名称划分：

| 数据域 | 保存的事实 | 允许写者 | 关键不变量 |
|---|---|---|---|
| Business | 正式行程、活动、协作者、游记与显式偏好 | 用户上下文/RLS 下的既有安全路径或 `command-service` | Agent Worker 无正式表写权；版本/CAS、字段权限与 Realtime 兼容 |
| Candidate/Evidence | Agent 草案、验证、证据引用、Command receipt | Worker 只写 Candidate/Evidence；Command 事务写 receipt | Candidate 与正式事实分离；采用失败不丢草案 |
| Runtime control | Thread、Run、Event、Job、Lease、Idempotency、Interrupt、Invocation | `agent-api` 与 `agent-worker` 的最小角色 | 单调序号、唯一键、终态 CAS、fencing、durable recovery |
| Checkpoint | Graph 恢复所需的最小 state 与 pending writes | 受控 checkpointer role | 与业务表隔离；不含 token、secret、完整 Prompt 或大结果 |
| Behavior release | package、certification、release、deployment pointer、kill event | CI/release operator | 内容与证据 append-only；pointer generation CAS；Run 固定 digest |
| Knowledge | source、ACL、version、chunk、派生索引、manifest、deletion | Phase 11 的 ingest/query 最小角色 | 只读已发布版本；ACL pre-filter；实时数据不静态化；全链删除 |
| Evaluation/Audit | dataset manifest、score、review 与最小安全/写入事件 | 评测流水线、人工 reviewer、各服务 append | 去标识、许可/保留、不可篡改；不能成为业务真相 |
| Redis（可选） | cache、wakeup、限流或短期健康提示 | 明确 adapter | 可全丢；不得保存唯一 Run/Job/Event 状态 |

运行角色 MUST 分离：`agent-api` 不调用模型/Tool，`agent-worker` 不写正式业务表，`command-service` 不调用任意模型；Release B 的 `command-service` 是 `agent-api` 内的受限 domain module，并使用独立最小 DB role，不是第三个常驻进程。Candidate adoption 所需的 Domain Command/CAS/outbox 安全写链必须在 Phase 9 接线时存在；Phase 12 的“Domain Command 分点迁移”只指按证据扩大旧业务写入口的命令覆盖，不得把基础采用链推迟到 Phase 12。migration role 只在批准窗口临时启用并在执行后撤销，observability role 只写脱敏信号。任何 service-role/break-glass 访问必须绑定 purpose、ticket、强认证、短有效期和完整审计。

### 8.2 迁移规则

- 生产 schema、extensions、RLS、grants、Storage policy、Realtime publication、索引和函数必须先只读导出并哈希；MUST NOT 根据 Flutter model 或 Dashboard 截图猜测。
- 迁移采用 expand/contract：先加兼容结构，再双读/回填/切换，最后在旧 App 与旧 Worker 兼容窗口结束后清理。旧字段不得在回滚窗口内删除。
- 每个 migration MUST 有 upgrade、可验证 downgrade，或明确的 forward-fix；“DDL 理论可逆”不是回滚证据。
- mandatory 数据库套件必须覆盖空库重建、已有数据升级、重复执行、并发、锁时间、RLS/grant diff、旧 Worker、备份恢复。RLS、租约、事务和 `SKIP LOCKED` 必须用真实 PostgreSQL。
- destructive migration、回填和任何生产写入 MUST 有显式批准、备份、dry-run、批次、限速、停止条件和恢复路径。实施 Agent 无权直接执行。
- PostgreSQL 约束是唯一性、终态、序号、CAS、幂等和租约的最后防线；应用检查不能替代。
- Outbox 与所属业务写在同一事务；relay 失败只重试投递，不否认已经提交的业务事实。消费者按 `consumer + event_id` 去重。
- 跨两个数据库不得伪装单一原子事务；使用明确状态、outbox/receipt 与 reconciler 收敛。
- 删除链必须覆盖主表、Candidate、cache、vector/FTS、对象、eval/trace 引用和恢复后的 deletion ledger 重放，防备份复活。
- Runtime/Business/Knowledge 即使早期共用 PostgreSQL，也必须独立 schema/role。Runtime 写放大、权限域、RPO 或业务 SLO 产生证据后，才以 ADR 决定物理拆库。

数据库工具当前不完整：Supabase CLI 与容器不可用。Phase 0/3 在锁定工具与隔离 PostgreSQL 未就绪时必须 `blocked`，不得改用 mock 或生产实例绕过。

## 9. 可观测性、运行与成本合同

本章解决“上线后怎样定位一次 Run、控制费用、触发降级并可靠回滚”的问题。

- 每条新路径 MUST 有 trace、metric、log 与 audit 的最小字段：时间、service、safe error、trace/run/thread 的脱敏关联、Behavior digest、route reason、evidence 状态、usage；正文默认不记录。
- 每个对外能力 MUST 声明 SLO、alert、owner、runbook、feature flag 与 kill switch。告警必须能指向稳定错误域和处置动作。
- usage ledger 分列模型输入/输出/reasoning/cache、Tool、repair 和 solver 使用；供应商 usage/账单是计费真值，估算需保存 pricing snapshot。
- 失败必须能定位到 Run、Behavior digest、model/tool version、route reason、first-bad-step 与 evidence 状态，不保存隐藏思维链。
- 外部观察平台不可用时业务按设计降级；本地缓冲有界。LangSmith 只 MAY 用于脱敏协作与评测，不能成为运行事实源。
- 没有生产流量时，成功率、p95、Token、人民币成本、采用率和人工节省均写 `unknown`。所有成本/质量/流量阈值除明确安全硬门外均标 `[初始假设，需上线校准]`。
- enterprise profile 的 Behavior 灰度顺序为 `1% → 5% → 20% → 50% → 100%`；current personal profile 改按 §9.2.2 的 C1→C5→owner canary 顺序。两种 profile 都保留同一回滚线：任何 P0、越权/泄漏、结构成功率下降、核心质量下降 `>1pp`，或 p95 成本上升 `>15%` 且没有预注册的质量收益，立即停止新 Run 并回退 pointer；已经开始的 Run 不换版本。
- kill switch、provider outage、Worker kill、Runtime PG 恢复、跨租户事件、secret rotation、RAG rollback 和 Memory deletion 必须各有 runbook；相关能力未启用时写 `not_applicable` 及原因。
- 回滚切 flag、route、image、deployment pointer 或 index alias，不删除新数据；已开始 Run 保持原 manifest，旧 Behavior/Worker 保留到活跃 Run 排空或迁移。

### 9.1 最小结构日志 Schema

Phase 2 起，`contracts/observability/log-event-v1.schema.json` 是新路径日志合同。所有字段都存在；没有值时使用 `null`，不得临时增加字段。以下为最低 JSON Schema，生产实现 MAY 收紧格式但 MUST NOT 放宽 `additionalProperties: false`：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "GoNowSafeLogEventV1",
  "type": "object",
  "required": [
    "schema_version", "ts", "level", "service", "event", "trace_id",
    "run_id", "thread_id", "behavior_digest", "error_code",
    "error_safe_message", "evidence_status", "route_reason", "usage"
  ],
  "properties": {
    "schema_version": {"const": "1.0.0"},
    "ts": {"type": "string", "format": "date-time"},
    "level": {"enum": ["debug", "info", "warn", "error"]},
    "service": {
      "enum": ["agent-api", "agent-worker", "compatibility-gateway", "release-tooling"]
    },
    "event": {"type": "string", "pattern": "^[a-z][a-z0-9_.]{0,127}$"},
    "trace_id": {"type": "string", "pattern": "^[a-f0-9]{32}$"},
    "run_id": {"type": ["string", "null"], "format": "uuid"},
    "thread_id": {"type": ["string", "null"], "format": "uuid"},
    "behavior_digest": {
      "type": ["string", "null"],
      "pattern": "^sha256:[a-f0-9]{64}$"
    },
    "error_code": {
      "type": ["string", "null"],
      "pattern": "^[a-z][a-z0-9_.]{0,127}$"
    },
    "error_safe_message": {"type": ["string", "null"], "maxLength": 256},
    "evidence_status": {
      "type": ["string", "null"],
      "enum": [
        "verified_current", "unverified", "stale", "conflicted", "invalid", null
      ]
    },
    "route_reason": {"type": ["string", "null"], "maxLength": 128},
    "usage": {
      "oneOf": [
        {"type": "null"},
        {
          "type": "object",
          "required": [
            "input_tokens", "output_tokens", "reasoning_tokens",
            "cache_tokens", "tool_calls", "repair_attempts",
            "solver_milliseconds", "cost_minor_units", "currency"
          ],
          "properties": {
            "input_tokens": {"type": "integer", "minimum": 0},
            "output_tokens": {"type": "integer", "minimum": 0},
            "reasoning_tokens": {"type": "integer", "minimum": 0},
            "cache_tokens": {"type": "integer", "minimum": 0},
            "tool_calls": {"type": "integer", "minimum": 0},
            "repair_attempts": {"type": "integer", "minimum": 0},
            "solver_milliseconds": {"type": "integer", "minimum": 0},
            "cost_minor_units": {"type": "integer", "minimum": 0},
            "currency": {"type": "string", "pattern": "^[A-Z]{3}$"}
          },
          "additionalProperties": false
        }
      ]
    }
  },
  "additionalProperties": false
}
```

`additionalProperties: false` 是防止调试字段、Prompt 片段或用户正文意外进入生产的安全门禁。所有日志在 schema 校验前先经 `PIIRedactor`；通过 schema 不代表内容一定安全，synthetic PII/secret canary 仍必须零泄漏。后台任务没有上游 trace 时自行生成有效 trace ID；禁止用空字符串或用户 ID 代替。Audit receipt 使用独立 append-only schema，但至少复用同样的时间、service、trace、run/thread 与 safe error 定义。

Schema validator MUST 显式启用 `date-time/uuid` format checking；仅加载 schema 但忽略 format 不算通过。正反合约用例至少覆盖未知字段、坏时间、坏 trace/UUID/digest、过长 safe message、负 usage、非法 evidence 状态和 synthetic PII。

这里的 `compatibility-gateway` 是 §3 所述 Phase 0 兼容路径标识，`release-tooling` 是非运行时 CI/发布证据标识；二者不新增 Agent 常驻进程。Release B 的 Agent 物理边界仍只有 `agent-api` 与 `agent-worker` 两个进程 `[硬约束]`。

### 9.2 Release B 发布认证 profile

#### 9.2.1 Enterprise 五档灰度分段决策（保留、当前不启用）

每一档的阈值、样本量和观察窗必须在该档开始前写入 rollout manifest 并由对应 owner 批准，MUST NOT 在看到结果后回头定义。下表的质量/性能数字是 `[初始假设，需上线校准]`；§5 的泄漏/越权为零和 §9 的回滚线仍是 `[硬约束]`。

| 档位 | 最低连续观察 | 全部满足才可前进 | 决策 owner | 任一失败 |
|---|---:|---|---|---|
| `1%` | `72h` | P0/P1=0；cancel/replay/idempotency mandatory 100%；Run 成功率 `≥90%` `[初始假设]`；样本达到预批下限 | Engineering | 立即回 `0%`，建 BLK |
| `5%` | `7d` | 继承前档；cross-tenant `leak_count=0`；API p95 `≤800ms`；每成功且采用任务成本 `≤预算×1.2` `[初始假设]` | Engineering + Security | 回 `1%`，72h 内根因方案，重新走完整 1% 窗口 |
| `20%` | `7d` | 继承前档；天数、城市覆盖、时间冲突等预定义关键 slice 相对批准基线不退化 `>1pp` | Engineering + Security + Product | 回 `5%`，重新完成 5% 窗口 |
| `50%` | `7d` | 继承前档；Judge 校准分与 E1 holdout 机械分差 `≤5pp`；p95 成本无统计显著上升 `[初始假设]` | 上述 owner + Release Board | 回 `20%`；若还要继续必须先有 ADR |
| `100%` | `7d` | 继承前档；SLO/error budget 持续满足；kill switch/§7.6 回滚演练、runbook、值班演练与文档完成 | Release Board | 停在 `50%` 或更低；不得宣称 Release B accepted |

低流量未达到预批样本量时延长观察，不得用时间已到替代样本。降档后必须保存原 Run manifest、证据和新旧分配时间；已经开始的 Run 不换版本。任何 P0、跨租户/越权、secret/PII、未批准正式写或关键 slice `>1pp` 退化立即跳过逐级回退，停止所有新 Run 并执行 kill switch。

五档观察窗必须按顺序、互不重叠，当前最低总历时为 `3+7+7+7+7=31` 天；v1.6.1 中“30 天”解释为总下限的概括，不能替代本表任何一档。所谓“等价证据”只 MAY 经 §16 ADR 更换信号来源/采集方式，不得缩短任一档窗口、改变顺序、降低样本或跳过 owner；否则不是等价。

rollout manifest 在每档开始前还 MUST 冻结统计合同：baseline/candidate 时间窗；纳入/排除条件；成功、失败、取消、重试在分子分母和成本中的处理；p95/质量 estimator；置信水平与 `alpha`；非劣/最小实际效应阈值；多 slice 校正；缺失值、异常值和低样本规则；价格快照。`p95 成本无统计显著上升` 只有在同一预注册方法下候选相对基线的置信区间满足批准的非劣阈值时才为真；字段缺失或样本不足只能延长/blocked，不能由人眼看曲线通过。

#### 9.2.2 Personal 高密度压缩发布认证（当前启用）

personal profile 把 31 天等待转化为状态空间、样本、故障、统计和真实依赖工程量。它提供“风险覆盖替代证据”，不提供“已经经历 31 天真实用户/基础设施漂移”的时间事实。C1–C5 使用互不重叠的 corpus/seed/fault-plan shard；独立 shard MAY 并行计算，但 acceptance 必须按 `C1 → C2 → C3 → C4 → C5 → owner_canary` 顺序聚合。预期总 wall-clock 为 `6–12h`、有界上限 `18h`，其中真实资源 soak 最低 `4h`；超时或资源不足为失败/blocked，不能跳过。

| 门禁 | 风险面与最低工程量 | 机械通过条件 | 预计 wall-clock | 失败动作 |
|---|---|---|---:|---|
| `C1 correctness` | 当前完整 Python/unit/contract/Flutter 回归；E0 `≥200`；`≥50,000` 条生成式 Run/state/cancel/replay/idempotency/resume/SSE 序列 | mandatory `100%`；hard invariant `100%`；合成任务成功率单侧 `95%` 下界 `≥90%`；skip/xfail/flaky rerun 全为 `0` | `0.5–1h` | 建根因 BLK；修复后先复现 seed，再跑受影响族 |
| `C2 security/performance/cost` | 锁定 PostgreSQL 的 tenant×principal×resource×action 矩阵；`≥100,000` 生成式 auth/RLS/Tool/SSRF/PII 请求；`≥10,000` 本地完整 Run；每个真实模型 route `≥200` 次调用和 usage receipt | 跨租户/越权/secret/PII/禁止 Tool=`0`；关键安全模块 mutation kill=`100%`、其他受影响模块 `≥90%`；API p95 的 `95%` 上界 `≤800ms`；每成功且采用任务成本上界 `≤预算×1.2`，p95 成本增幅上界 `≤15%` | `1–2h` | allocation 保持 `0`；成本或 live receipt 未知则仅本门 blocked |
| `C3 quality slices` | E1 `≥1,000`；城市、语言、币种、预算、天数、无障碍、时间边界、Tool 故障、弱网、攻击和兼容切片；每个关键 slice `≥200` | baseline/candidate paired comparison；每个 slice 退化单侧 `95%` 上界 `≤1pp`，Holm 多重校正；硬约束/Schema/时间预算冲突 `100%`；变形关系全通过 | `1–3h` | 保存失败 slice/样本；禁止事后改分母/阈值 |
| `C4 recovery/time/soak` | 所有已声明副作用 kill point × success/timeout/reject × `≥20` 独立调度；虚拟时钟推进 `≥90` 日并跨月/年/闰日/DST/NTP 前后跳；`≥100,000` fake-provider 生命周期；真实 wall-clock soak `≥4h`；Judge 固定标注 `≥400` 且主要 slice `≥50` | 旧 Worker 晚写全被 fence；重复正式副作用/重复计费/永久 Run=`0`；TTL/lease/deadline/retention/价格快照符合合同；预热后 RSS/handle/thread/连接/backlog 无持续正斜率且最终回基线容差；Judge 与机械分差 `≤5pp`，否则 Judge 仅 advisory | `4h`，可并行 | kill switch ready；资源斜率或任一未知终态失败即修复 |
| `C5 rollback/operations` | `≥20` 类数据库/provider/Tool/Worker/SSE/outbox/lease/clock/预算/安全故障；静止和在途两类回滚；旧路径、trace、alert、runbook 演练 | 每个故障可由 trace/run/digest 定位；alert/runbook 首动作正确；kill switch `≤30s`；新 Run=`0`；旧路径 `100%`；数据丢失/重复写=`0`；回滚后 `5min` 高密度观察全绿 | `1–2h` | 自动 allocation=`0`；保留证据和 durable data |

所有统计阈值必须在 `certification-manifest.json` 中预注册并绑定 candidate OID：纳入/排除、成功/失败/取消/重试分母、estimator、单侧置信水平、最小实际效应、多 slice 校正、缺失/异常处理、价格快照、平台矩阵和环境 digest。随机关键族在零失败时使用保守 `95%` 上界近似 `3/n`；要声称失败率低于 `0.1%`，该族至少 `3,000` 个独立样本且零失败。baseline/candidate 不可比或真实依赖缺失时写 blocked/unknown，禁止降低阈值。

平台覆盖按实际 Release target 决定：Android MUST 在 minSdk、接近 targetSdk、targetSdk 三档模拟器执行 App background/process-kill/cold-start、网络切换、SSE、active-run、preview/reject/adopt/CAS 和 flag-off 等价；如果 iOS 是本次发布目标，则 macOS/iOS runner 同样 mandatory，Windows 本地结果不得替代。生产模型/地图/天气凭据只能经 Secret Provider 注入，命令和证据不得回显。

C1–C5 全绿后才可执行最终 `owner_canary`：同一 candidate OID/Behavior/构建不得改变，feature allocation 从 `0` 只开放给预注册的 owner canary identity，执行 `10–20` 个成功、取消、断线恢复、拒绝、采用和 CAS 冲突旅程，连续 `30–60min`。canary 必须证明真实生产配置、权限、PostgreSQL、供应商、usage receipt、trace/alert、kill switch 和旧路径接线；它不承担质量/容量统计，也不得扩展到其他用户。任一安全红线、重复副作用、永久 Run、旧路径失败、成本 receipt 缺失或 candidate 漂移立即自动 allocation=`0` 并使 Release acceptance 失败。

最终 `personal-release-certification.json` 至少聚合 `certification-manifest.json`、`regression-report.json`、`state-space-report.json`、`security-matrix.json`、`fault-injection-report.json`、`quality-slice-report.json`、`performance-cost-report.json`、`virtual-time-report.json`、`soak-report.json`、`rollback-operations-report.json`、`owner-canary-report.json` 和 `residual-risk.json` 的 SHA-256。必须记录 `production_observation_required=false`、`automated_gate_acceptance=true`、`evidence_type=personal_compressed_release_certification`、`residual_risk=not_validated_against_31_day_real_user_and_infrastructure_drift`；只有 §0.4.3 与本节全部 predicate 成立时才可自动标记 Release B accepted。

## 10. Phase 0–12 合同索引

本章解决“每个阶段最低做什么、不能顺手做什么、用什么证据退出以及怎样回滚”的问题。

Phase 是长期地图，不是无门禁连续施工清单。每个阶段只有在进入条件、mandatory gate、证据与适用 profile 的 acceptance 成立后才可启动下一阶段；enterprise profile 使用独立 owner，current personal profile 使用 §0.4.3 自动 attestation。详细 TASK、文件 allowlist、依赖和精确命令由 `execplan.md` 定义。

| Phase | 做什么 | 明确不做 | 验收后可直接观察到的状态 | 验收判断基准来源 | 最低 mandatory gate | 回滚 |
|---|---|---|---|---|---|---|
| **0 生产事实发现与安全止血** | 重新确认远程基线；只读导出生产 schema/RLS/extensions；撤销并轮换已暴露模型 secret；删敏感日志；建立 Flutter analyze/test 真实 baseline | 不接 Agent、不改产品语义、不做未批准生产写 | 旧 key 在供应商侧被拒；客户端包、网络和新日志找不到模型 secret；生产数据库事实有只读 hash 清单；旧用户旅程仍按原语义工作 | `origin/main@BASE_SHA` 的 `flutter analyze/test` 原始结构化 baseline、树 hash、供应商撤销 receipt、同一 scanner/version 的 before/after、schema inventory hash | `BASE_SHA`/树可复验；§5.4 事件时钟；全历史 scan 与 revoked registry 精确一致且 `new_history_findings=0`；current/build/CI/network `live_secret_match_count=0`；schema inventory 有 hash；相对 BASE_SHA `new_errors=0` `[硬约束]`；旧路径回归 | 双 key 短窗或配置回切仅安全 owner 批准；新网关可关；绝不恢复泄露 key |
| **1 验证语义与架构基线** | 把 hard conflict、warning、unverified、始终可导入和 fallback 固化为合同/fixture；冻结 Flutter 接线点 | 不实现 Agent，不改变用户数据 | 给同一 fixture 的任何实现都得到同一 hard/warning/unverified 与导入结果；旧聊天/Auth/fallback 画面和数据不变 | 预先编号并由 Product/Engineering 批准的 fixture catalog、BASE_SHA 旧路径输出和同一 comparator；不得在验收时改期望 | 每条语义有 fixture ID；普通聊天、导入、Auth、fallback 回归；降级表获工程/产品 owner 批准 | 仅回滚文档/测试 |
| **2 Agent Service 安全骨架** | 同仓新增锁定 Python/FastAPI/Pydantic 服务；API/Worker 分入口；JWKS、配置、Secret Provider、§9 日志、探针和 CI 安全扫描 | 不调用模型、不运行 Graph、不接 Flutter 流量 | 合法启动后 API/Worker 可分别健康停止；无合法 JWT 的请求稳定返回 `auth.invalid_token`；密钥/JWKS/Runtime 缺失时 readiness=false；Flutter 用户无变化 | 锁文件/SBOM/许可证/CVE 报告、§6.4 Auth cases、§9 schema tests、NTP/clock evidence、OpenAPI contract 与进程启动/停止报告 | Python/依赖版本锁定；鉴权 fail-closed；必需依赖失败 readiness false；HTTP 无 stack；secret/PII scan 为零 `[硬约束]`；可构建、测试、启动、优雅停止 | 不部署或关闭路由，Flutter 不受影响 |
| **3 控制面持久数据** | Thread/Run/Event/Idempotency/Lease/Job/Outbox、Behavior/Prompt 发布数据、RLS、CAS 与 migration | 不修改正式业务语义，不让模型写业务表 | 服务重启后 Run/Event/幂等记录仍在；并发同请求只有一个 Run；跨租户查询由真实 PG 拒绝；事件 seq 可按 Run 重放 | 锁定 PostgreSQL 版本上的 migration matrix、两个 principal×两个 tenant RLS corpus、CT-001/002/012/013、并发/终态 SQL assertions | 空库重建；upgrade 与 downgrade/forward-fix；跨租户泄漏为零 `[硬约束]`；并发幂等唯一胜者；终态不可逆；event seq 稳定；RLS/grant diff 可审计 | 保持向后兼容；停新 Worker 后 forward-fix |
| **4 LangGraph 单 Agent 行为对等** | 仅多日行程规划；一张有界 planning Graph、typed state、Harness、一个主供应商两档认证路由、最多三类只读 Tool `[硬约束]`、Context v0、typed Candidate、Behavior Package | 不做其他 Agent 场景、RAG、隐式 Memory、Multi-Agent、多供应商平台、Redis 或正式直写；普通聊天旁路 | 在 flag/离线入口可得到 typed Candidate 和 evidence；预算/no-progress 可见且有界；未知 Tool 被拒；正式行程表没有模型写入；普通聊天仍旁路 | Graph 开工前批准的 E0（至少 30 主+10 边界）manifest/dataset hash、固定 comparator 与关键字段差异阈值；§6.4 已到期控制与 CT-008/012/013；CT-011 保留给 Phase 8 分支共享预算 | E0 对等金标；未知/禁止 Tool 安全失败；预算/no-progress 生效；Candidate 幂等；Run 版本不漂移；已落地 Harness 均有目录要求的测试 | flag 切旧规划，保留 Candidate |
| **5 Durable Job、Checkpoint 与崩溃恢复** | PostgreSQL jobs、`SKIP LOCKED`、lease/fencing、checkpoint、PhysicalInvocationLedger、reconciler、kill/replay | 不以 Redis 为恢复真相 | 在每个已声明副作用边界 kill Worker 后，新 Worker 可接管；旧 Worker 的晚写被拒；用户不会被重复扣费/调用；无永久 queued/running | 预先冻结的 kill-point matrix、真实 PG invocation/outbox 查询、CT-005/006 与 fencing 竞态报告；副作用计数必须为精确整数 | 每个副作用边界 kill 后收敛；Tool 不重复副作用/扣费；旧 Worker 写被拒；孤儿 lease 被发现；deadline 后无永久卡死 | 停 Worker、关闭 Agent 路由，保留 Run/Event 供恢复/人工 |
| **6 中断、恢复、取消与 SSE** | typed interrupt/resume、cancel intent、一次性 CapabilityToken、§6.5 SSE replay、移动网络恢复 | 不把超时当批准，不用心跳生成业务 event | 断网后从上一业务 seq 继续；重复 resume 不产生第二效果；取消在下一安全边界收敛；心跳不会改变业务事件数；旧客户端可继续使用旧路径 | 版本化 SSE/OpenAPI schema、固定重连 schedule、CT-010、移动网络/慢消费者/410 corpus 和 DB seq assertions | `Last-Event-ID` 无丢失/重复副作用；慢消费者/订阅竞态；resume consume-once；cancel 合法收敛；旧客户端兼容 | 关闭 Run/SSE 新路由，保留旧路径与持久事件 |
| **7 确定性验证与局部修复** | canonical validator；hard/warning/unverified；最多两轮 repair `[硬约束]`；no-progress；必要时独立进程 solver | 不让模型擦硬冲突，不把 failed-to-check 说成 verified | 相同输入得到相同问题分类；无法验证会显示 unverified 而非“通过”；repair 第三轮永不发生；solver 卡死时父进程杀掉而服务仍活 | Phase 1 批准的约束/fixture catalog、validator/repair deterministic vectors、CT-014（solver 启用时）和进程存活/终态 assertions | 批准的约束矩阵；始终可导入不破坏；repair 上限生效；solver 超时可硬 kill；每种失败有稳定降级 | 关 repair，保留验证；必要时旁路 solver |
| **8 单 Agent 稳定与有界分支实验** | 默认单图；最多两个只读 Research Branch `[硬约束]`，只允许 offline/replay/Shadow A/B 且不向 active 用户输出，共享全局预算 | Release B 内不得生产启用 Multi-Agent，不允许分支借预算或产生正式写 | active 用户仍只看到 Phase 7 单图；flag-off 的事件/Candidate 与 Phase 7 等价；实验只产生脱敏证据且两分支总预算不超 | Phase 7 固定 replay hash、预注册 A/B manifest、CT-011、同一 E1 slice/成本/延迟 comparator；质量 `>3pp` 或 p95 时延 `>20%` 且成本合格仅是后续 Phase 12/Release C ADR 触发 `[初始假设]`；未提升的可信负结果同样可验收 | flag-off 与 Phase 7 等价；Research Branch 零 active 输出/正式写；共享预算不超；合并确定性；正负实验结果均按预注册方法完整归档 | flag 回单图并删除实验流量分配，不删除证据 |
| **9 Flutter 最小接线** | OpenAPI→Dart；Run/SSE/resume/cancel；active-run persistence；Candidate preview/adopt；Domain Command/CAS/outbox；双路径 flag | 不删旧路径；不把基础采用链推迟到 Phase 12；无读性能证据不强建 CQRS | 用户可看到进行中状态、断网后恢复并预览 Candidate；只有明确采用才以 expected version 写正式数据；flag-off/旧 App 仍工作 | 同一 OpenAPI→Dart codegen digest、旧/新 App compatibility matrix、Flutter 三路径 E2E、Command receipt/CAS/outbox DB assertions | 普通聊天、导入、Auth、fallback 不变；断网恢复可见；旧 App 兼容；adopt 重新鉴权并 CAS；Flutter E2E 与后台恢复 | 切旧路径；兼容 adapter 按 §3 删除门禁保留 |
| **10 可观测与 Release B 生产门禁** | OTel、SLO/alert、eval、Judge 校准、kill switch、§9.2 profile、成本与 runbook | 未校准 Judge 不阻断；不把 synthetic/staging 写成生产观察；不删除 enterprise 合同 | 值班人员可由 trace/run/digest 定位失败并按 runbook 关闭新路径；current personal profile 的 C1–C5 与最终 owner canary 均有不可变证据 | §9 schema/canary、E1 holdout、价格快照、认证 manifest、互斥 corpus/seed/fault plan、真实 PG/live provider、§7.6 回滚、soak 与 kill-switch timing | 高危为零 `[硬约束]`；kill/replay/cancel/idempotency；关键 slice 非劣；成本在预算；完整顺序执行 §9.2.2 C1–C5；`≥4h` soak；`30–60min` owner-only canary；自动 attestation | kill switch/allocation=`0`，立即回旧路径；旧 Behavior 可运行；保留失败证据 |
| **11 独立 RAG 工作包** | source/ACL/version/delete/outbox；pgvector + PostgreSQL FTS；确定融合、citation、Knowledge Release Package；实时信息仍走 Tool | 不同时启 Memory/Multi-Agent；不摄取无权内容；hard filter 不移到 Python | 仅当选择 RAG 时，Candidate 的稳定知识 claim 带可打开 citation；无 ACL 权限和删除后的内容检索不到；实时事实仍来自 Tool | Release B 失败 ledger 中“缺稳定知识”比例、预注册 RAG dataset/ACL corpus、manifest/alias hash、Recall/citation/p95 阈值与数据权属批准 | 启动前 `>20%` 触发 `[初始假设]` 与 ADR；Recall/citation、`ACL leakage=0` `[硬约束]`、删除、陈旧、p95、alias 回滚达批准值 | 独立 RAG flag 关闭；alias 回旧 manifest；旧 Behavior 不依赖新索引 |
| **12 累计认证三个已完成能力** | 本轮仅累计已进入 landing 的 P12D、P12B、P12A；P12C dormant | 不建设 Multi-Agent，不删除/重写历史，不据此启用生产流量，不为“完整”引入新平台 | Release C 候选包含三个默认关闭/零分配能力；逐能力关闭后旧路径仍可用，产品运行时保持 Single-Agent | 三个能力原始 990/999、完整回归、merge tree、focused smoke、累计拓扑、工程级 089/990/999 | 产物漂移已解释并补受影响验证；全工程回归与安全/RLS/CAS/删除恢复/旧路径兼容全过；生产事实未知不冒充通过 | 分别关闭 Memory read port、Cost Router route、Domain Command flag；必要时通过受保护 PR revert Release C merge |

所有 Phase 共同门禁：范围 allowlist、入口跨阶段回归、兼容、安全、真实数据库可靠性、目标 eval、脱敏观测、依赖供应链、成本、回滚、文档/知识转移、接受报告和 profile-specific acceptance。当前 Release 不涉及的门禁只能标 `not_applicable + reason`；涉及但工具未就绪则 `blocked`，不能标通过。

每个 Phase 合并前还 MUST：

- 更新受影响的 OpenAPI/Dart/Event/State 契约与 `docs/api/` 人类说明；没有接口变化时在 acceptance 明确 `not_applicable` 和 diff 证据。
- 更新 README 的能力/启动边界、`docs/runbooks/` 的启停、降级、告警、恢复/回滚步骤，以及 acceptance 的“变更摘要”，用白话说明本 Phase 前后可直接观察的差异。
- 生成 §15 的 `knowledge-transfer.md`；完成 §7.6 回滚演练；列出本 Phase 所有 BLK 及最终状态。验收后合并按 §2.4 跑五分钟 smoke，并在下一 Phase 入口前完成 retrospective/STAR 与归档。

困难记录是主动义务：同一步骤第二次失败、需要修改最初计划、依赖外部系统、等待 owner 决定，或发现任何未知生产事实时，MUST 在 `24` 小时内按 §12 建 BLK；P0/P1 服从更短的 §5.3 时限。Phase acceptance 必须列出全部 BLK，而不是只列仍未解决者。

Phase 11 与 Phase 12 都以可复验的 Release B 机械证据和各自触发为前提；它们不是自动连续关系。本轮按 §0.4.4 固定走 Phase 12，并累计认证已经依次完成的 P12D、P12B、P12A；这不是并行施工或生产同时分配。未来新增任何第四项能力或启用 P12C/Multi-Agent，仍必须作为新的独立发布重新走 ADR、门禁和回滚。

## 11. Release A/B/C 关系

本章解决“长期阶段如何组成可独立交付的发布，以及何时必须停止扩张”的问题。

| Release | 进入门禁 | 退出门禁 | 明确不做 | 回滚 | 证据 owner |
|---|---|---|---|---|---|
| **A 安全基线** | Phase 0 已授权；生产事实只读访问与 secret owner 到位 | 旧 key 失效；live/current/build/CI/network secret=0；历史 revoked occurrence 与批准 registry 精确相等且新增=0；服务端最小网关、schema/RLS 清单、旧体验与测试 baseline 获独立确认 | Agent 切流、RAG、Memory、Multi-Agent、队列 | 新网关整套关闭；保持安全旧路径，不恢复泄露 key | Engineering + Security + Data |
| **B 可运营单 Agent** | Release A accepted；Phase 1 语义与 Phase 2–9 依次验收；§7.2 数据集与 §9.2 profile manifest 齐全 | current personal profile：跨租户/越权、禁止 Tool、未授权正式写、secret/PII、重复副作用、永久 Run 为零；真实 PG kill/replay/cancel/幂等；C1–C5、成本、`≥4h` soak、`30–60min` owner-only canary 与自动 attestation 全过。enterprise profile 仍保留 §9.2.1 原五档合同 | 多日行程外 Agent、RAG、隐式 Memory、生产 Multi-Agent、多供应商平台、Redis、自动正式写、重型平台 | allocation=`0`/flag 回旧规划；保留 Run/Candidate/新数据；旧 Behavior/客户端可用 | personal 自动 gate；enterprise 为 Engineering + Security 及适用 owner |
| **C 单一证据能力** | Release B 稳定且真实失败数据满足 Phase 11 或 12 的一个触发；专项 ADR/数据/删除/成本批准 | 仅所选工作包的安全、质量、性能、成本、运营和回滚门禁通过 | 不并行 RAG+Memory+Multi-Agent+智能路由，不自动上新平台 | 独立 flag/manifest/alias/route 回切，旧 Behavior 保持运行 | 对应 Engineering/Security/Product/Data owner |

Release A/B/C 都必须有进入、退出和回滚证据，不能因“下一 Phase 已开工”反推前一发布 accepted。当前 Release C 仅允许 §0.4.4 固定的 P12D/P12B/P12A 累计集合；该集合之外仍禁止追加能力，P12C 必须 dormant `[硬约束]`。

## 12. 困难、卡点与逐级升级日志

本章解决“遇到困难怎样留下可复现线索、何时升级、何时停止试错”的问题。

卡点日志 MUST 让不了解 GoNow 术语的工程师也能读懂。每次尝试的“我以为这样做能修好”和“结果发现了什么”都必须用白话写；第一次出现缩写时同时写全称与日常解释。禁止只写“依赖冲突”“环境问题”“已解决”“见上”或用 `CAS/fencing/UNKNOWN_OUTCOME` 等术语代替问题描述；结论没有命令、输出或可复验事实支持时只能写“假设”，不能写“根因”。

凡满足以下任一条件，MUST 在 `24` 小时内建档：同一步骤第二次失败；一次 mandatory gate 失败且无法立即按原计划修正；需要改变原定方案；依赖外部系统/工具/权限；等待 owner 决定；出现未知生产事实。P0/P1 按 §5.3 更短时限立即建档。路径固定为：

`docs/execution/blockers/phase-XX/BLK-PXX-NNN-short-name.md`

顶部前三句不得出现未展开的术语或缩写：

1. 用户或系统看到了什么问题。
2. 它阻止了哪一步。
3. 当前最安全的下一步是什么。

日志模板中的括号是强制写作提示，不得删除后留空：

```text
ID：（这件卡点的稳定编号）
Phase / TASK：（它正在阻止哪张任务卡）
status：（open / mitigated / resolved / accepted_risk / superseded；accepted_risk 只允许 P3 且需 owner/到期日）
severity：（P0/P1/P2/P3；用白话说为什么是这个级别）
owner / reviewer：（谁负责处理、谁独立判断关闭）
first_seen / last_updated / timezone：（精确到分钟并带时区）

期望结果：（原本应该直接看到的输出、数字或状态）
实际结果：（实际看到什么；不要只写“不工作”）
影响：（安全、数据、用户、进度、回滚分别有什么影响；无则写“无+证据”）

最小复现步骤：（从干净状态开始，别人可复制运行）
脱敏证据路径与哈希：（证据放哪里、SHA-256 是什么；不要贴 secret/正文）

已知事实：（每条都引用命令、测试或权威文档）
仍不确定：（还没有证据回答的具体问题）
受影响的不变量：（用“哪条规则为什么受影响”的白话；首次出现再附技术名）

尝试时间线（每次尝试单独一条，以下字段全部必填）：
- 时间：（精确到分钟并带时区）
- 我以为这样能修好：（一句不含未解释术语的话，例如“以为端口号配错了”）
- 为什么先试这个：（说明它风险最低或能区分哪个假设）
- 具体做了什么：（可复制命令或精确文件/行级改动）
- 退出码和实际输出：（数字与关键错误文本；不使用截图替代）
- 这次学到的新事实：（例如“不是端口问题，是认证头格式不对”）
- 有没有回滚：（有/无；有则写恢复到哪个 SHA/配置；无则解释为什么不产生变更）
- 本次升级的具体触发条件：（逐字对应下表一条；禁止写“综合判断”）

最终方案与选择理由：（为什么这条路在安全、数据、兼容、成本、回滚上最好）
被否决方案及理由：（至少说明为什么没选；L3 起至少两个方案）
fix commit/PR：（完整 SHA 或永久链接；尚无则写 pending）
验证命令与回归：（具体命令、退出码、结构化报告和 hash）
最终状态与关闭时间：（resolved 等状态是谁在什么时间确认）
剩余风险、预防措施、待更新文档：（每项有 owner 和到期日）
```

升级阶梯和强制触发固定如下；满足任一触发就必须进入下一层，不得在原层重复没有新信息的尝试：

| 层级 | 本层必须做什么 | 强制进入/升级条件（满足任一） |
|---|---|---|
| `L0 稳定复现` | 从干净状态复现一次，保存最小脱敏证据；不改设计 | 建档条件已触发；稳定复现且不是明显的本地拼写/路径错误后进 L1 |
| `L1 最小修复` | 查代码、配置、锁文件和一手资料；一次只做最小可回滚修复 | 两次最小修复失败；需要改原方案；外部依赖行为与官方文档不符；隔离环境不复现而目标环境稳定复现 |
| `L2 单变量实验` | 在隔离环境一次只改一个变量；增加能区分根因的测试 | 单变量实验仍不能区分两个以上假设；存在至少两种可行解且安全/兼容/成本取舍不同；不同环境表现需要架构解释 |
| `L3 方案比较` | 至少比较两个方案和“不改变”方案，写安全、数据、兼容、成本、回滚；触发 §16 时起草 ADR | 方案会改 AGENTS/公共接口/schema/Phase 范围；需要第三方介入；预计修复超过本 Phase 剩余缓冲 |
| `L4 Owner/供应商决策` | 把复现、实验、方案表和明确问题交给有权 owner；记录响应 SLA | owner 介入 `24h` 无明确结论；方案改变 Release 范围；安全影响继续扩大或授权仍不足 |
| `L5 停止并阻塞` | Phase/TASK 标 `blocked`，停止扩大变更；按授权回到安全 flag/route 或 `phase_base_sha` 语义 | 进入即保持阻塞，直到外部条件改变并由 owner 给出可验证解除决定；恢复后从证据仍有效的最低层继续 |

以下示例只展示写法，不代表真实 GoNow 事实；每例都同时写清“为什么先试”和“学到什么”。

`L0` 示例：

```text
时间：2026-07-31T10:00+08:00
我以为：失败可能只是偶发网络抖动。
为什么先试：只读重跑一次风险最低，能确认是否稳定复现。
做了什么：在干净 worktree 运行同一 readiness 测试。
退出码/结果：1；连续返回“缺少密钥引用”。
学到的新事实：问题稳定存在，且发生在任何外部网络调用之前。
升级触发：稳定复现且不是本地拼写错误，L0→L1。
```

`L1` 示例：

```text
时间：2026-07-31T10:20+08:00
我以为：服务读取了错误的配置名称。
为什么先试：只改一处映射，容易回滚，也直接验证配置假设。
做了什么：对照锁定 schema 修正名称并运行同一测试两次。
退出码/结果：两次均 1；错误改为“引用存在但无读取权限”。
学到的新事实：名称已正确，真正缺的是运行角色权限。
升级触发：两次最小修复失败，L1→L2。
```

`L2` 示例：

```text
时间：2026-07-31T11:10+08:00
我以为：角色权限和密钥服务策略中只有一项有误。
为什么先试：隔离环境一次只替换角色，可区分两个原因。
做了什么：保持策略不变，仅切换为已知可读的测试角色。
退出码/结果：0；恢复原角色后再次为 1。
学到的新事实：失败跟随角色变化，密钥服务本身可用。
升级触发：有“扩大角色权限”和“增加最小代理”两种取舍，L2→L3。
```

`L3` 示例：

```text
时间：2026-07-31T12:00+08:00
我以为：两种方案都能恢复读取，但权限风险不同。
为什么先试：先做书面对比，避免直接扩大生产权限。
做了什么：比较扩大 Worker role、增加 Secret Provider 代理和保持现状。
退出码/结果：无执行；方案表显示代理的权限面最小但多一个依赖。
学到的新事实：选择会改变进程/权限边界，需要 ADR 与 Security 决定。
升级触发：方案修改安全边界，L3→L4。
```

`L4` 示例：

```text
时间：2026-07-31T13:00+08:00
我以为：owner 可依据现有方案表直接选择。
为什么先试：只有 Security/Engineering 有权批准权限边界。
做了什么：提交复现、实验 hash、三方案表和一个明确决策问题。
退出码/结果：不适用；24 小时内没有批准或补充问题。
学到的新事实：当前缺少有权决定者，不是代码继续试错能解决。
升级触发：owner 介入 24 小时无结论，L4→L5。
```

`L5` 示例：

```text
时间：2026-08-01T13:05+08:00
我以为：继续改代码不会增加可用证据。
为什么先试：停止能防止未批准的权限扩大进入 diff。
做了什么：TASK 标 blocked；关闭测试分配；保留 worktree 与证据。
退出码/结果：集成分配为 0；git diff 仅含已批准诊断文件。
学到的新事实：解除条件是 owner 对 ADR 给出书面决定。
升级触发：已到 L5；等待外部条件变化，不再重复尝试。
```

MUST 立即停止而非继续试错的条件包括：可能泄露 secret/PII、可能跨租户或越权、可能产生不可逆生产写、幂等/回滚不明、同一失败无新证据重复出现、mandatory gate 无法运行、需要扩大用户未授权范围、或架构偏离尚未批准。

P0/P1、疑似不可逆写或正在扩大的泄漏可以从任一层直接跳到 L4/L5，但 MUST 在时间线逐项注明跳过层级、原因、已采取隔离和通知时间。紧急跳级不是省略证据的许可。

禁止重复同一命令等待偶然成功；禁止只写“依赖问题”“环境问题”“已解决”；禁止记录 secret、JWT、PII、完整 Prompt/响应或 reasoning；禁止未记录上次结果就升级到更激进方案。阶段无阻塞时在接受报告写“无需要单独立档的 blocker”，不得伪造。

## 13. 阶段接受报告与证据清单

本章解决“reviewer 最终应看到什么，才能独立决定接受或拒绝”的问题。

每个 Phase MUST 生成：

`docs/execution/evidence/phase-XX/acceptance.md`

报告至少包含：

- phase branch、`phase_base_sha`、`candidate_head_oid`、可选 `approval_record_oid`、`git_object_format`、目标与 non-goals。
- §10 对应的“验收后可直接观察到的状态”逐项实测，以及每项“验收判断基准来源”的版本/hash；不得由 reviewer 临时发明通过口径。
- 文件变更清单及其任务 allowlist 对照。
- Phase 入口跨阶段 regression 与上一 merge 的五分钟 integration smoke 结果。
- 每个 mandatory gate 的命令、退出码、结构化报告路径与 SHA-256、结论；mandatory 项不得未运行。
- 非 mandatory 未运行项、原因、风险、owner 和补跑条件。
- 安全、数据库、兼容、可靠性、质量、性能/成本、观测、供应链、文档和回滚逐项结果。
- Harness 状态矩阵、CT ID 结果、blocker 清单与状态。
- 回滚演练步骤、触发条件、耗时和结果；不删除新数据。
- README、OpenAPI/Dart/Event/State 合同、API 说明、runbook、每 Phase 必有的威胁模型 review receipt/hash（无变化写 `model_changed=false`）与 `knowledge-transfer.md` reviewer 结论；文档必须描述实际 head，而不是计划中的能力。
- profile-specific acceptance：enterprise 保存工程/安全及必要产品/数据/隐私 owner 批准、时间与有效期；current personal 保存各证据域结果、自动 attestation、runner digest 和 candidate/hash 绑定。
- 合并目标、PR 和最终 merge commit；未合并时明确写 `pending`。

报告 MUST NOT 包含真实 secret、敏感正文、大日志、完整 Prompt/响应或 reasoning。实施 Agent 只能提交证据；不能替 enterprise owner 写批准结论，也不能手改 personal 自动 attestation。

enterprise 独立 reviewer 或 current personal 自动接受 runner 只要看到以下任一项，MUST 强制 `rejected` 或保持 `ready_for_review/blocked`，不得协商：

1. 任一 mandatory gate 退出码非零、未运行、超时、skip/xfail 或输入版本与批准基准不同。
2. diff 含 TASK allowlist 外文件、生成物不能追到生成源、worktree 不 clean 或 `git diff --check` 失败。
3. P0/P1 未关闭，P2 尚未在验收前关闭，跨租户/secret/PII/未批准正式写计数非零。
4. §7.6 回滚演练没有实际执行、场景不全、依赖删除新数据、在途 Run 未收敛或观察窗出现新错误。
5. profile-specific acceptance 缺字段、SHA 不匹配、条件未关闭或证据已变化；enterprise 还包括超过 `valid_until`/实施者代签，personal 还包括 runner digest/clean-environment/redline 缺失或 attestation 被手改。
6. 任一 BLK 缺 `resolved|accepted_risk|superseded` 等最终状态、缺 owner/关闭证据，或 acceptance 遗漏本阶段 BLK。
7. Phase 入口回归、依赖审计、Harness 到期用例、文档、runbook 或 knowledge transfer 任一适用项缺失。
8. 报告计数由人工填写且无法从原始结构化结果重算，或只保留截图/绿色摘要而丢失首个失败。

验收报告的 merge addendum 由获授权合并操作者在 merge 后补充 merge OID 与 §2.4 smoke；若 smoke 失败，先前 accepted 状态对该集成结果不成立。retrospective 是合并后的义务，按 §15 在下一 Phase 入口前完成。

## 14. `execplan.md` 交接合同

本章解决“下一份执行计划怎样把本宪章变成可施工任务，而不重新解释架构”的问题。

后续 `execplan.md` MUST：

- 精确引用本文件稳定章节号和 v1.6.1 对应章节。
- 把 Phase 0–12 拆成原子 TASK；不得把长期地图变成自动连续开工清单。
- 每个 Phase 开头用不超过 `300` 字的白话说明“现在缺什么 → 本阶段补什么 → 解锁什么 → 用户/运维能观察到什么”，并逐字引用 §10 的可观察终态与判断基准；首次出现的缩写必须解释。
- 每个 TASK 用“具体交付物与通过条件”替代通用占位语，逐项写出完成后新增/变化的精确文件、接口或状态，机械验证命令及期望数字/字符串。只写“exit 0”“功能正常”“安全通过”不合规；exit 0 之外还要断言业务输出、测试数、错误码或 DB 状态。
- 每个 TASK 写明精确允许文件/连接点、依赖、可复制 PowerShell/Python 步骤、任务适用的 CT ID、证据、回滚和 blocker 条件。命令旁边必须写关键期望输出，环境未知时先建供应 TASK，不得猜命令。
- 每个 TASK 增加“安全合规检查项”，从 §5.2 选择适用边界，并按“检查什么 → 怎样机械验证 → 失败动作/严重度”填写。纯只读文档任务也要明确“无额外边界 + 被哪项只读/secret 规则覆盖”，不得留空。
- 每个 TASK 的 DoD 直接列本任务必须通过的具体检查、对应测试 node/CT、期望结果和 evidence path，不能复制四条泛化清单或让执行者猜 `S/I/D` 的含义。
- `docs/execution/commands/TaskGateCatalog.psd1` MUST 为每个 TASK 保存 machine-readable `file_allowlist` 和 gate schema。已知路径精确到文件且不使用 `**`；只有迁移等在计划时无法知道序号的生成文件 MAY 使用经批准的单目录前缀+受限文件名正则，Gate runner 必须拒绝目录外或不匹配项。提交前自动比较 `git diff --name-only $phase_base_sha...HEAD`。
- `TaskGateCatalog.psd1` 顶层 MUST 固定为 `SchemaVersion`、`CatalogVersion`、`SupersedesCatalogSha256`、`BootstrapStage`、`CapabilityResolvers`、`TaskGateModeContracts`、`PhaseMergeModeContracts`、`Tasks`；只能由 `Import-PowerShellDataFile` 读取，不得包含可执行表达式。每个在 `execplan.md` 出现的 mode 必须有唯一 handler、允许 bootstrap stage、required inputs/capabilities、read/write set、output schema、success predicates 和 failure transition；未知 mode、缺 handler、未解析 capability、原始环境变量路径或 registry/invocation 差集非零 MUST fail closed。Catalog 必须先投影为规范化 JSON，再通过版本化 `task-gate-catalog-v2.schema.json` 和正反 fixture。
- 每个 TASK MUST 使用唯一的 `docs/execution/status/TASK-ID.json` 记录状态转移；记录包含上一状态/文件 hash、当前完整 Git OID、owner alias/canonical role、actor、带时区时间、evidence hash、blocker path 和独立批准引用，并以 compare-and-swap 原子替换。执行者不得写 `accepted/rejected`，并行任务不得共享状态文件。
- 任何引入/升级依赖的 TASK 都要把 §4 依赖审计作为显式子步骤和 DoD，并将 SBOM、许可证、CVE、维护/provenance 与 dependency diff 加入 artifact hash。
- 每个 Phase 在验收 TASK 前设置独立 `TASK-PXX-089` 文档/知识转移 TASK（即 `TASK-P00-089` 至 `TASK-P12-089`），只允许更新受影响 README、`contracts/`、`docs/api/`、`docs/architecture/`、`docs/runbooks/` 与本 Phase 文档；另有两个严格受控例外：089 MAY 以旧 hash CAS 原子聚合 `docs/execution/schemas/harness-test-catalog.yaml`，且只能按已接受任务证据升级状态、不得降低或改规范字段；089 MAY 从逐任务 CAS 状态生成 `docs/execution/status/task-board.json` 与 `.md`，但派生看板不得成为第二事实源。由非实施者 reviewer 确认内容与实际代码/配置一致。ID 如已被旧计划占用，先经 ADR 迁移旧含义，不能静默换号。
- 每个 Phase 明示“困难记录义务”：第二次失败、计划改变、外部依赖或 owner 等待在 24 小时内按 §12 建档；验收 TASK 汇总所有 BLK 和最终状态。
- 每个 `PXX-990` 验收 TASK 直接列出 §13 的八项强制拒绝条件、profile-specific acceptance 字段、knowledge transfer 和 §7.6 回滚证据；不能只写“记录验收结果”。
- 每个 `PXX-999` 合并 TASK 在获授权合并后立即运行 §2.4 的五分钟 integration smoke，回填 merge addendum，并按 §15 完成阶段清理/归档；实施 Agent 仍不得自行合并。
- 每个 Phase 指定独立分支、进入门禁、接受门禁、owner 和合并动作。
- 对当前 unavailable/unknown 的 Python、Supabase CLI、容器和数据库隔离环境，先建立工具供应任务；不得编造命令或跳过 mandatory gate。
- Phase 0 的 `TASK-P00-003` 必须继承 §5.4 从 `incident_first_seen` 起算且不可由 Phase 入口重置的 `4h/24h/2h` 时限；Phase 4 必须以 `TASK-P04-000` 先建立并冻结 §7.2 E0 数据集，再实现 Graph；Phase 6 首任务必须固定 §6.5 SSE 合同；Phase 10 必须逐档执行 §9.2；不得把这些合同留给验收时临时定义。
- 所有任务证据遵守 §7.4 schema；所有 Phase 入口执行 §2.3 regression，合并后执行 §2.4 smoke，合并后的 retrospective/STAR 成为下一 Phase 进入门禁。
- 不复制或改写本文件硬约束。若任务需要偏离 v1.6.1、公共合同或安全边界，先提交 ADR 并修订 `AGENTS.md`。

`AGENTS.md` 的冻结候选 MAY 作为只读输入编制 `execplan.md` 冻结候选，以便两份文件做跨文件审阅并形成一次绑定双方最终 hash 的采纳 receipt；这不等于把任一候选设为已采纳。两份文件中任一 bytes/version 变化都会使旧 receipt 失效并要求重新联合审阅。在 `execplan.md §0.3.0` 的联合采纳 receipt 通过 BOOT-001 原生校验前，MUST NOT 把任一文件标记为 `adopted`、执行 BOOT clone 或开始任何 Phase；在 execplan 未获批准前更不得实施。

## 15. 阶段收尾、知识转移与文档归档

本章解决“代码通过后怎样把操作方法、踩坑、量化改进和证据留给下一位维护者，并避免治理文件散落”的问题。

### 15.1 每阶段固定产物与目录

每个 Phase 的治理文件只放在以下稳定位置：

```text
docs/
  api/                              # 面向人的接口说明；事实源链接 contracts/
  architecture/
    adr/                            # §16 ADR
    threat-model/                   # §5.0 威胁模型
  runbooks/                         # 启停、降级、告警、恢复、回滚
  execution/
    blockers/
      phase-XX/                     # §12 BLK
    schemas/                        # §7.4 机器 schema/catalog
    status/                         # TASK-ID.json 为实时 CAS 事实；task-board 为 089 派生快照
    supply-chain/phase-XX/TASK-ID/  # §4 依赖审计
    evidence/
      integration/<merge-oid>/      # §2.4 五分钟 smoke
      phase-XX/
        artifact-manifest-vNN.json
        phase-close-vNN.json
        acceptance.md
        knowledge-transfer.md
        retrospective.md
        cleanup-result.json
        star-records.md
        improvements/
          STAR-<stable-id>.md
```

`artifact-manifest-vNN.json` MUST 列出本 Phase 所有证据/文档的相对路径或不可变外部引用、SHA-256、大小、敏感级别、owner、保留期和生成 TASK，但明确排除该 manifest 自身及随后引用它的 `phase-close-vNN.json`，避免自引用。每个 revision 使用新文件名、含单调 `revision` 与上版 `supersedes_manifest_sha256`，不得覆盖；Gate runner 校验 manifest 与其声明的实际文件一一对应。`phase-close-vNN.json` 保存最终 manifest path/hash、merge/smoke OID、retrospective/STAR 状态和前一 close record hash；该 close 文件的完整性由包含它的 `phase_close_oid` Git tree 证明，不要求自列 hash。

仓库根目录不得出现阶段报告、临时日志、截图、SBOM 或未归类附件。小型脱敏结构化证据 MAY 入 Git；大日志、二进制、生产只读导出或受限数据 MUST 放获批对象存储，只在 manifest 保存不可变版本链接、hash、访问级别、保留/删除日期，不能把临时 URL 当永久证据。

### 15.2 文档与知识转移

合并前，受影响的 README、`contracts/`、`docs/api/`、架构/威胁模型和 runbook MUST 与 candidate head Git OID 一致。runbook 至少写：如何确认能力健康、怎样启停/降级、告警的第一步排查、kill switch/feature flag 的稳定名称和权限、恢复/回滚命令、升级 owner 与安全注意事项；不得包含 secret 值。

`docs/execution/evidence/phase-XX/knowledge-transfer.md` 是验收强制项，由实施者编写、非实施 reviewer 验证可读性，至少包含：

1. **交付了什么**：面向没读过 TASK 的维护者，用白话说明新增目录/文件职责、修改连接点、外部依赖及选择理由。
2. **最难的事项（最多三件）**：按实际发生数量写 `0–3` 件；每件不超过三句描述问题，链接 BLK/ADR，写最终解法以及“重来一次会怎样做”。不足三件不得编造，`0` 件时写 blocker 实际计数和为什么无需单独事项。
3. **运维必知**：正常时看哪些日志/指标/查询；常见失败模式和第一步动作；如何安全关闭与恢复；哪些动作需要 owner 权限。
4. **估算与实际**：计划/实际人天、等待时间与执行时间分开，差异原因只用于改进估算，不用于伪造进度或追责。
5. **交接验证**：至少一名未实施该 Phase 的工程师按受影响能力在隔离环境完成一个等价交接旅程并记录命令、退出码、耗时与问题。服务阶段演示启动/健康/降级或回滚；纯合同/文档阶段执行 schema/fixture/链接/生成或版本回退验证；数据库阶段执行 dry-run/恢复；不允许因“无服务可启动”跳过全部验证。文档作者自测不能替代。

### 15.3 Retrospective 与 STAR 量化记录

每个 Phase accepted 且产生 `merge_oid` 后 `48` 个连续小时内，MUST 完成 `retrospective.md` 并形成 `phase_close_oid`；下一 Phase 的入口回归不得在它缺失时通过。内容至少包括计划/实际人天与差值、本 Phase BLK 数量和最终状态、最耗时 blocker（存在时）及原因、flaky/返工/等待时间、估算或 gate 对下一 Phase 的具体调整、未关闭 P3 及 owner/期限、文档/KT 反馈。没有 blocker 时写精确计数 `0`，不得编造“最耗时问题”。

STAR 的目的不是统计写了多少代码、接入多少框架或跑了多少命令，而是证明“原来哪里不行 → 本次承担什么可验收指标 → 哪些关键设计改变了行为 → 在可比条件下具体改善多少”。凡声称“优化、提速、降本、质量提升、事故减少、恢复更快”或以该结果支持路由/Release 决策，MUST 创建独立 STAR 记录。代码行数、模块数、框架名和测试条数只能作为实施规模或证据覆盖，不能单独作为系统行为改善。

#### 15.3.1 指标选择与基线冻结

在选择指标前，记录者 MUST 先区分 claim 类型，不能把三类证据混成同一个“提升百分比”：

| claim 类型 | 正确证明方式 | 是否进入 STAR 改善表 |
|---|---|---|
| `capability_presence`：能力是否存在，例如 Registry、状态机、migration、ADR、Threat Model | 文件/Schema、能力测试、gate 与 hash；在 change-summary/KT 说明 | 仅“已具备”本身不进入；若进一步证明可追溯率、回滚耗时或复现率改善，才建立 STAR |
| `behavior_improvement`：系统效果、可靠性、成本或工程效率是否改善 | 同口径 baseline/candidate、分子分母、重复与结构化报告 | MUST 进入 STAR |
| `governance_conformance`：是否满足批准、安全或审计要求 | pass/fail gate、owner receipt、红线计数与不可变证据 | 不折算成综合提升分；作为 STAR 护栏或独立治理证据 |

每个 STAR 只选择与该改动存在直接因果关系、在实施前已定义且有可比证据的指标；不要求每个 Phase 同时改善所有维度。默认采用一个 `primary_result`（最终价值）、一个 `diagnostic`（解释机制）和一个 `guardrail`（防止以代价换指标）的结构，通常在 STAR 摘要保留 `2–4` 个数字；适用的安全 `redline` 不受这个数量限制且不得省略。偏离 `1+1+1` 时在 `metric_scope` 写理由。

没有改善、与任务无关或当前不可测的维度无需进入成果表，但 MUST 在 `metric_scope` 中以 `not_applicable | not_measured | guardrail_only` 和一句理由如实登记，不得挑选有利结果后把其他已预注册指标静默删除。完整测量留在结构化评测报告，STAR 只提炼最能解释价值的少数指标，并链接完整报告。

指标分四层选择；实际记录只取适用子集：

| 层 | 角色 | 可选指标 |
|---|---|---|
| 最终任务结果 | 优先作为 `primary_result` | 端到端成功率、必要子任务覆盖率、显式约束遵守率、人工接管率、每成功任务成本、P95 完成延迟 |
| Agent/模块行为 | 优先作为 `diagnostic` | 意图/约束提取、规划覆盖/回溯/重复、Tool 选择/参数/错误传播、输出 Schema/事实、适用的 RAG/Memory/Multi-Agent 专项指标 |
| 系统可靠性与安全 | `primary_result`、`guardrail` 或不可抵消 `redline` | 恢复率/RTO、状态丢失、重复副作用、非法状态转换、取消后写入、越权/跨租户、审批绕过、secret/PII 泄漏、降级成功率 |
| 工程成熟度 | 只有行为可测时作为结果，否则属于 capability evidence | 可重放率、历史版本复现率、回滚/定位/接入/回归耗时、回归缺陷率、同范围覆盖率、交接旅程成功率 |

任何 Hard Constraint 红线一旦失败，STAR 的整体结论 MUST 为 `failed` 或 `blocked`，不得与成功率、成本或其他高分求平均后抵消。至少包括适用的：跨租户访问成功次数 `0`、未经审批的高风险正式写次数 `0`、重复正式副作用次数 `0`、secret 进入 Prompt/日志次数 `0`、已取消 Run 继续正式写入次数 `0`。安全改进同时 SHOULD 报告正常请求误拒绝率，避免以“拒绝一切”伪装安全提升。

任何准备比较的指标 MUST 在候选实现测量前冻结以下内容，并由对应 TASK evidence/manifest 绑定 hash：baseline Git OID 与 candidate base、任务/场景清单及 dataset SHA-256、样本纳入/排除规则、指标名称/公式/单位/改善方向、成功和失败判定、模型/Prompt/Behavior/Tool/数据库版本、temperature/最大步骤/预算等适用参数、随机种子或重复次数、runner/硬件和时间窗，以及不可牺牲的安全、质量、成本或兼容护栏。对延迟、成本或随机模型结果的比较还 MUST 预先规定 estimator、重复次数、缺失值/异常值处理和适用置信范围；确定性穷举测试可写 `deterministic` 并免统计置信区间，但仍须给出精确分子、分母和范围。

常用公式按下列口径执行；任务可以增加更具体的公式，但不得在看到候选结果后改口径：

- `任务成功率 = 完全满足预先验收条件的任务数 / 总任务数`；“产生了回答”不等于成功。
- `子任务覆盖率 = 正确完成的必要子任务数 / 必要子任务总数`。
- `约束遵守率 = 满足的显式约束数 / 显式约束总数`。
- `计划有效率 = 最终实际使用的规划步骤数 / 规划步骤总数`。
- `重复步骤率 = 重复执行步骤数 / 总执行步骤数`。
- `错误传播率 = 未被拦截且进入后续推理的错误 Tool 结果数 / 错误 Tool 结果总数`。
- `无效调用率 = 未对验收结果产生有效贡献的模型或 Tool 调用数 / 总调用数`；“有效贡献”的判定规则必须预注册。
- `每成功任务成本 = 对照集中全部任务的模型费用、Tool 费用和明确纳入的基础设施边际费用之和 / 成功完成任务数`；同时报告成功数/总数和价格快照。成功数为 `0` 时结果为 `undefined_fail_closed`，不得用单次调用成本替代。
- `每成功任务 Token = 对照集中全部任务的输入与输出 Token 总和 / 成功完成任务数`；失败重试消耗必须计入，不能只统计最后一次成功运行。

下表是专项 metric profile，不是新增能力清单；只有对应能力已经进入当前 Phase 范围时才适用：

| 改进类型 | 建议主要结果 | 建议诊断 | 必须关注的护栏/红线 |
|---|---|---|---|
| 动态规划 | 端到端成功率 | 子任务遗漏率或回溯率 | 每成功任务 Token/成本不超预注册阈值 |
| Tool 结果校验 | 错误传播率 | 异常识别率 | 正常结果误拦截率 |
| Checkpoint/恢复 | 崩溃恢复成功率 | RTO/恢复步骤数 | 重复正式副作用次数 `0` |
| 幂等/outbox | 重复副作用率或事件丢失率 | 重复请求一致响应率/同步延迟 | 正常正式写成功率不退化 |
| 权限/HITL/安全 | 越权或未审批正式动作成功次数 `0` | 策略命中/攻击拦截率 | 正常请求误拒绝率、跨租户泄漏 `0` |
| RAG（仅已启用时） | 有证据答案正确率 | Recall@K/nDCG/Citation Accuracy/Faithfulness 中与根因直接相关者 | 无权限/过期内容召回率、P95 检索延迟 |
| Memory（仅已启用时） | 相对无 Memory 的任务成功净增益 | 正确召回/冲突识别率 | 错误记忆注入率、过期使用率、删除传播失败数 |
| Multi-Agent（仅已启用时） | 相对同口径单 Agent 的复杂任务成功净增益 | 路由准确率/重复工作率/结论冲突率 | 每成功任务成本、延迟、跨 Agent 信息泄漏 |
| 可观测性/运维 | 故障可定位率或 MTTR | trace/状态快照覆盖率、MTTD | 敏感字段泄漏 `0`、业务路径不因 exporter 故障失败 |

Multi-Agent 的“净增益”不能只报告质量差值；MUST 同时给出单 Agent 对照的每成功任务成本、P95 延迟和失败分布。若质量变化小于预注册最小实际效应而成本/延迟明显增加，只能写 `no_demonstrated_net_benefit`，不得把“已使用多个 Agent”写成成果。

百分率由 `X%` 变为 `Y%` 时，绝对变化写 `Y-X` 个百分点（`pp`），相对变化另按 `(Y-X)/X` 计算并明确标为 relative；不得把二者混写。计数、时间、Token 和成本必须带单位。baseline 为 `0` 时不得计算无穷或伪造相对改善，只报告绝对变化。

#### 15.3.2 标准 STAR 内容

每个 `improvements/STAR-<stable-id>.md` MUST 使用以下结构，允许增加小节但不得省略或合并 S/T/A/R：

1. **S — Situation（基线问题）**：用最小篇幅写清用户/系统问题、任务规模与工程约束；列出 baseline OID、环境、样本/时间窗和改前数值。没有真实 baseline 时写 `baseline_unavailable + reason`，该记录只能作为观察或后续测量计划，不能声称提升。
2. **T — Task（验收责任）**：写明确负责范围、claim 类型、预注册的 `primary_result + diagnostic + guardrail/redline`、目标方向和不能突破的护栏；禁止只写“负责开发/重构 Agent”。目标阈值属于 Initial Hypothesis 时必须标注，不得冒充已批准 SLO。
3. **A — Action（关键决策）**：只保留对结果贡献最大的 `2–4` 个动作，逐项写“针对哪个根因 → 设计什么机制 → 为什么采用该机制”，并链接 TASK、commit、ADR/blocker 和回滚。不得用 LangGraph、RAG、Redis、MCP 等名词清单替代因果解释。
4. **R — Result（同口径对照）**：先给一句结论，再给量化表、护栏结果、失败切片和证据边界。baseline/candidate MUST 使用相同任务集、模型和参数、Tool/数据库版本、判定规则和统计方法；不能相同时必须列出 confounder，并停止把差异归因于本改动。

R 的最小表格列固定为：

| metric_role | metric_id | 指标层 | 公式/单位 | 改善方向 | Baseline（分子/分母） | Candidate（分子/分母） | 绝对变化 | 相对变化 | 样本/重复/置信 | verdict/evidence |
|---|---|---|---|---|---|---|---|---|---|---|

成果表至少有 `1` 个真实改善指标；默认围绕一个主要结果、一个解释该结果的诊断指标和一个非退化护栏呈现，通常保留 `2–4` 个核心数字，无需为“全方位提升”凑数。适用 redline 和 T 中声明的每个护栏都 MUST 报告 candidate 数值和 `passed|failed|unknown`，即使它没有改善；redline/护栏失败时不得宣称整体成功。工程报告可以测量更多指标，但 STAR 摘要不得把它们无选择地全部复制，也不得隐藏不利的预注册结果。R 还 MUST 给出复现命令、执行 head OID、结构化原始报告路径/SHA-256、运行时间、owner 结论，以及“本结果不证明什么”（例如本地 synthetic 不等于生产流量、VM 不等于真实移动设备）。

#### 15.3.3 运行级采集与失败分类

为避免事后凭印象补数，纳入 STAR 对照的每次任务运行至少保存以下脱敏字段；不适用字段写 `not_applicable`，采集失败写 `unknown + reason`，不得省略后按零处理：

```text
task_id, run_id, baseline_or_candidate, git_oid, agent_version,
behavior_digest, prompt_version, model, model_parameters, dataset_version,
toolset_version, database_version, random_seed, start_time, end_time,
input_tokens, output_tokens, model_call_count, tool_call_count,
failed_tool_calls, retry_count, planned_steps, completed_steps,
duplicate_steps, explicit_constraint_count, constraint_violations,
human_intervention, final_success, failure_category, evaluator_version
```

这些字段遵守 §5/§7/§9 的最小化与脱敏边界，不得保存 secret、Prompt/response 正文、模型 reasoning 或不必要 PII。失败不能只分“成功/失败”；适用时至少从 `requirement_misread | planning_omission | ordering_error | tool_selection_error | tool_argument_error | bad_tool_result_unchecked | context_loss | goal_drift | duplicate_execution | output_schema_error | budget_exceeded | external_dependency_failure | security_or_policy_rejection | unknown` 中选择一个稳定类别。分类规则和 evaluator 版本必须冻结；修改分类法产生新版本，不能覆盖历史数据。

#### 15.3.4 证据诚实、索引与过渡

结果数据不足时写 `unknown` 并停止“已经提升”的表述；相关观察可以作为 `[Initial Hypothesis]`，不能伪造 STAR 的 R。只看到改后结果、仅使用不同数据集/参数、单次非确定性运行、没有分母、只报告最好一次、把 skip/失败移出分母、测试条数增加或代码量增加，都不足以证明行为改善。每个 STAR 使用稳定 ID 存入本 Phase `improvements/`，由 retrospective 和 acceptance/Release 决策链接；不得把多个无共同因果链的优化塞进一个文件。

`TASK-PXX-089` 还 MUST 生成 `docs/execution/evidence/phase-XX/star-records.md` 机器可解析索引，每行沿用 stable ID、独立 STAR 相对路径、SHA-256、对应 TASK/claim 和 `recorded|not_applicable`，不得为本次修订擅自增加破坏现有 runner/schema 的状态值。`recorded` 行的独立 STAR 内必须列出改善 metric_id 与 guardrail metric_id；没有可复验优化时必须有一条 `not_applicable + reason`。baseline 已冻结但候选尚无足够样本时使用 `not_applicable + reason=measurement_pending:<exact_missing_evidence>`，不能虚构 Result。该索引只负责发现性和完整性，MUST NOT 代替独立 S/T/A/R 证据。

`1.7.0` 生效前形成的 STAR 不得为了满足新模板而凭空回填数字。若保留的原始报告能够按同一口径重算，MAY 新建带新 stable ID 或 `supersedes` 引用的 revision，并保留旧文件/hash；否则旧记录标记为 `legacy_format`，所有不满足本节的改善声称降级为历史观察。`1.7.0` 生效后的当前及后续 Phase 必须使用本节格式。

### 15.4 阶段清理与证据封存

合并前的清理只可作用于当前 TASK 创建或跟踪的文件，MUST NOT 删除用户已有 untracked 内容。Gate runner 至少检查：

- `git status --porcelain=v1` 与 diff allowlist；没有 `.tmp/.bak/.swp/.orig`、`temp/` 或无 owner 的生成物进入跟踪。
- diff 新增行中的 `breakpoint()`、`import pdb`、`debugger;`、`TODO: remove`、`FIXME: temp`、未受控 `print/debugPrint/console.log`。确为产品日志的代码必须走 §9 schema；测试 fixture 例外要有 `test-only` 注释和 reviewer 结论。
- 新增硬编码 `localhost/127.0.0.1/0.0.0.0/test@example.com` 只允许在明确测试 fixture/config 中，不能进入生产默认配置；host/port 必须来自 typed config。
- 任务创建的本地临时文件已删除或移入受管证据目录；覆盖率用同一工具/范围与 Phase 入口快照比较，受影响 suite 的边界覆盖不得下降。覆盖率检查不能替代 §7.2 的显式测试。
- 文档链接、manifest hash、外部 artifact 可访问性/保留期、blocker/ADR/STAR/KT/retrospective 索引完整；secret/PII scan 在封存后的最终树上重跑。

清理结果固定写入 `docs/execution/evidence/phase-XX/cleanup-result.json` 并纳入最终 `artifact-manifest-vNN.json`，由 Phase `999`/Release 合并门禁引用。合并后的 smoke 和 retrospective 形成后再生成最终 manifest revision 与 `phase-close-vNN.json`；旧 revision 不覆盖，使用 append-only 文件名和 `supersedes_manifest_sha256` 链。

## 16. ADR 触发、审批与模板

本章解决“什么时候必须先做架构决定、ADR 最少写什么、谁的批准才有效”的问题。

### 16.1 强制触发清单

以下任一情况必须在代码/迁移/Release 分配前建立 ADR：

1. **技术栈/边界**：新增 §3 已批准技术线之外的生产直接依赖、原生组件、常驻进程、外部平台或事实源；改变 API/Worker/Command 的职责。
2. **数据模型**：新增业务/Runtime/Knowledge 表，改变主键、唯一性、RLS/grant、保留/删除、备份恢复、事件或状态 schema。
3. **安全/隐私**：请求放宽 §5.1、改变 §5.2 的失败策略/严重度，新增外部数据用途、跨区域传输、第三方观察或权限边界。
4. **Phase 合同**：新增、删除、重排或实质改变 Phase mandatory gate、non-goal、可观察终态、判断基准或回滚责任。
5. **公共接口**：改变已发布 OpenAPI、SSE、Dart/Pydantic contract、稳定错误码、Behavior/Prompt/Tool manifest 或不兼容 major。
6. **Release 范围**：把能力提前到原本明确不含的 Release、推迟已承诺能力、并行两个 Release C 包或改变灰度/删除前置。
7. **运行时不变量**：改变 §6.1 的状态、预算、幂等、CAS/fencing、事件顺序、Candidate/Domain Command、evidence/reasoning 或时钟不变量。
8. **偏离最终架构**：任何偏离 v1.6.1 或本文件 Hard Constraint 的实施建议，即使短期成本更低。

兼容 patch 升级、只用于测试且不进入产物的工具、文档排版、内部重命名或已批准方案内的局部实现通常无需 ADR，但 TASK 必须写“不触发 §16.1 的哪一条及证据”。新生产依赖即使无需改变进程，也仍执行 §4 审计；若不在批准技术线内则触发第 1 条。

### 16.2 生命周期与批准

ADR 文件名为 `docs/architecture/adr/ADR-NNNN-short-slug.md`，编号不可复用，状态只取 `proposed|accepted|rejected|superseded|deprecated`。`proposed` 期间 MAY 做不触碰生产/公共合同的隔离实验，但不得合并实施。enterprise profile 的 `accepted` 必须绑定批准时的 AGENTS version、v1.6.1、完整 head OID、证据 hash 和适用 owner。current personal profile 中，本轮用户明确授权的 `2.0.0-personal` 治理 ADR可记录为 `accepted_by_owner_directive`；此后计划内、可逆且 mandatory gate 全过的 ADR MAY 由自动 attestation 接受，涉及新产品语义、权限扩大、不可逆数据/外部动作或本合同未列范围时仍须新的明确用户决定。Agent 不得伪造用户决定或测试通过。

若决策改变 Hard Constraint，ADR 本身不构成放宽授权：必须先由用户/有权治理者明确批准并修订本文件的相应 MAJOR/MINOR 版本，再实施。ADR 被新决策替代时，旧文件保持不可变并通过 `superseded_by` 链接新 ADR；不得静默改写“当时为什么这样决定”。

### 16.3 最低模板

```markdown
# ADR-NNNN：<一句话决策>

- status: proposed|accepted|rejected|superseded|deprecated
- created_at / decided_at: <ISO 8601，带时区>
- decision_owner / author / independent_reviewers:
- applies_to: <Phase / Release / services / data>
- agents_version / architecture_version:
- decision_head_oid / git_object_format:
- evidence_manifest_sha256:
- supersedes / superseded_by:

## 白话摘要
<三句话：为什么现在要决定、选了什么、系统会出现什么可观察变化。>

## 背景与决策问题
<当前事实、未知项、触发 §16.1 的具体条目；不把目标写成已实现。>

## 决策驱动与不可违反约束
<安全、数据、兼容、性能、成本、运营、时间、Hard Constraint。>

## 备选方案
<至少两个真实可行方案，另列“不改变现状”；每个都写实施边界。>

| 方案 | 安全/隐私 | 数据/删除 | 兼容/迁移 | 成本/维护 | 发布/观测 | 回滚/RTO | 证据与未知 |
|---|---|---|---|---|---|---|---|
| A | | | | | | | |
| B | | | | | | | |
| 保持现状 | | | | | | | |

## 选定方案及理由
<用上述证据解释选择；列出关键 trade-off，不写“最佳实践所以选”。>

## 被否决方案及理由
<逐项解释为什么没选，包含重新考虑的触发条件。>

## 后果与实施/迁移计划
<正面、负面、风险、TASK、expand/contract、兼容窗、文档/培训。>

## 验证、可观察终态与回滚
<机器 gate、预期数字/错误码、观察窗、kill/flag/route/schema 回切、失败停止线。>

## 批准
<按 §2.4：owner_role/name、完整 approved head OID、approved_at、条件、责任声明、永久引用。>
```

### 16.4 Git OID 与 artifact hash

当前固定基线仓库使用 SHA-1 Git object format，因此本文件中的 commit SHA/approved head 是完整 `40` 位 OID；每个 baseline/acceptance/ADR 还 MUST 保存 `git rev-parse --show-object-format` 的输出。若未来经 ADR 迁移为 Git SHA-256，则改用该仓库返回的完整 OID，不截断为 40 位。Git OID 字段与内容 artifact 的 `sha256` 字段必须分开命名、分别校验；任何时候都不得把 64 位 artifact hash 当 commit OID，或把 Git OID 当文件完整性 hash。
