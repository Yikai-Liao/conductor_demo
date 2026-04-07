# 基于Conductor的人机协同异步工作流DEMO搭建

我们要基于 docker compose 模拟一个真实网络环境中的最小化的 Conductor 异步工作流部署。
* 底层使用 nomad 全家桶来做管理（例如使用 consul 做服务发现，vault 做密钥管理）如果需要的话，考虑到目前使用 docker 模拟，可以先不使用 ansible.cfg）reference/nomad-demo
* 在可观测性上，全面使用otel + vector + victoria 的组合，参考 reference/observability-platform-demo
* 工作流调度器使用conductor，纯 postgre 部署方案。 参考.agents/skills/conductor

## 整体架构
我们在模拟中，整体上要切分为两个网络区域，conductor 和 pg 是准备部署在云服务的，所以是一个公网服务，走下面这套连接方式与内网通讯，注意需要处理鉴权问题。公网和内网之间的通信可以添加一些东西去模拟丢包和延迟波动

```
worker (内网)
   -> HTTPS
   -> Nginx / Envoy / API Gateway
   -> Conductor Server (私网)
```

在我们的 demo 中，conductor 和 pg 直接使用单例部署即可。pg的可观测性不用处理，但是 conductor 所在容器的可观测性需要接入到 victoria 体系

## 测试工作流

如果要用 python 代码去描述这个测试用工作流的话，是这样的：

```python
def func1(x, comments:str = ""):
    print(comments)
    return x+1

def review(x)->(bool,str):
    return x>5, "数值不符合，打回"

def func2(x):
    return x*2


x = 1 # workflow start, init with 1

comments=""
while True:
    x = func1(x,comments)
    review_results = review(x)
    if review_results[0]:
        break
    else:
        comments=review_results[1]
        x += random()
        
y = func2(x) # workflow end with output y
```

但是，我在实际的 demo 中，我希望你能够将这两个 worker,func1 在 python， func2 使用 ts。review 节点需要走 Human Task的 manual Approval API，从一个 nodejs 中发起，代码使用 ts。review的步骤你需要一些随机 sleep 不超过 5s，来模拟人工审核延迟。

然后最后还要展示一个 conductor 控制面板内 的 filter 查询能力，比如并发了 1000 个 workflow 后 筛选最终结果 y>10.1 的结果，当然，你可能需要告诉我操作流程，这是一个 ui 界面的操作。所有的 worker 和 review 都要用 otel 埋点，并利用好otel 的跨进程关联。


## 构建中网络问题处理

```bash
# lyk @ asus in ~/qiyin/conductor on git:main x [16:17:02] 
$ docker system info | sed -n '/Proxy/,+8p'
 HTTP Proxy: http://127.0.0.1:7890
 HTTPS Proxy: http://127.0.0.1:7890
 No Proxy: localhost,127.0.0.1,.local
 Experimental: false
 Insecure Registries:
  ::1/128
  127.0.0.0/8
 Live Restore Enabled: false
 Firewall Backend: iptables
```

本机的 docker 已经配置了代理环境变量，但是构建 dockerfile 时构建过程中的代理配置参考reference/annex_demo/docker/annex/Dockerfile
你应该尽可能配置好中国镜像，少走代理

## 设计审查补充（已合并进计划）

这次任务的重点不是单纯把容器跑起来，而是把整条演示链路做成“操作者第一次跑也不会迷路”的状态。当前计划在系统搭建上有方向，但在演示体验上缺了太多关键决策，所以这里直接补齐。

### 1. 演示对象与成功标准

本次 demo 的主要使用者不是终端消费者，而是以下三类人：

- `Demo 操作者`：负责启动环境、触发工作流、展示结果。
- `评审旁观者`：需要在 3 分钟内看懂这个系统到底证明了什么。
- `排障观察者`：需要能快速判断问题卡在 Conductor、worker、review，还是观测链路。

本次 demo 的成功标准不是“容器都 healthy”，而是下面 5 件事都能被看见：

1. 能启动一个单次工作流，并在 `Conductor UI` 里清楚看到 `func1 -> review -> func2` 的执行顺序。
2. `review` 是一个真实的 `Human Task / manual approval` 流程，不是本地函数调用伪装出来的。
3. Python worker、Node review、TS worker 的日志与指标能用统一关联字段串起来，至少能看到 `workflowId`、`taskId`、`trace_id`。
4. 并发 `1000` 个 workflow 后，能在 `Conductor UI` 里完成一次面向观众的筛选演示，目标是筛出 `y > 10.1` 的执行结果。
5. 出问题时有明确的观察入口，而不是靠翻容器日志猜。

### 2. UI / 交互范围

这次任务有交互范围，但不是要做一个新前端。范围要收紧，不然很容易做成“为了 demo 再造一个 demo 门户”。

本次明确纳入范围的交互面：

- `Conductor UI`
  - workflow execution list
  - workflow execution detail
  - filter / search / result drill-down
- `Grafana`
  - 预置 dashboard
  - logs / metrics 联查入口
- `Node.js review service`
  - 提供人工审批相关的 HTTP API
  - 返回结构化 JSON，供操作者和排障使用
- `CLI / 验证脚本`
  - 启动、压测、验收、回放 demo 的固定入口

本次明确不纳入范围的交互面：

- 不做独立的 React / Vue 审批后台。
- 不做独立“总览大盘”把 Conductor、Grafana、审批结果全部重新包装一遍。
- 不做移动端适配。这个 demo 明确按桌面浏览器和终端演示。

### 3. 演示信息架构

操作者必须有一条固定主路径，不能边点边解释。

```text
启动与验收
  -> docker compose up / verify
  -> 打开 Conductor UI，确认服务可用
  -> 启动单个 workflow，打开 execution detail
  -> 观察 review 节点进入 waiting / in_progress
  -> 通过 Node review service 完成 manual approval
  -> 回到 Conductor UI，确认 workflow 完成并得到 y
  -> 并发 1000 个 workflow
  -> 在 Conductor UI 中按结果字段筛选 y > 10.1
  -> 打开 Grafana，验证 worker / review 的关联指标与日志
```

为了让主路径稳定，必须定义每个界面的“唯一职责”：

- `Conductor UI` 只负责解释“工作流有没有跑、卡在哪、结果是什么”。
- `Node review service` 只负责解释“审批动作从哪里发起、何时完成、带了什么 comment / decision”。
- `Grafana` 只负责解释“链路是否有观测数据、跨进程关联是否成立”。

不要把同一件事在三个入口都讲一遍。一个界面只做一件事，观众才不会晕。

### 4. 演示主路径与操作顺序

#### 4.1 Happy Path

1. `docker compose up -d --build` 完成部署。
2. 使用固定脚本注册 workflow 定义、task definition，并启动依赖 worker。
3. 先跑 `1` 个 workflow，输入固定值 `x=1`，让观众看到最小闭环。
4. 在 `Conductor UI` 的 execution detail 中观察：
   - `func1` 已执行
   - `review` 进入人工审批等待
   - 审批 comment 会回写到下一轮 `func1`
5. 由 `Node.js review service` 触发 manual approval，并在 `0-5s` 内随机 sleep，模拟真实人工延迟。
6. `func2` 完成后，在 UI 中看到最终输出 `y`。
7. 再启动 `1000` 个 workflow，准备做筛选与观测演示。

#### 4.2 Bulk Demo Path

批量演示不能只说“跑 1000 个”，必须规定观众看什么：

1. 在脚本层输出提交总数、成功数、失败数、正在等待 review 数。
2. 在 `Conductor UI` 的列表页按 workflow name / time range / status 收敛范围。
3. 再用结果字段筛选出 `y > 10.1` 的执行集合。
4. 从筛选结果里点开 `1-2` 个样本，展示：
   - 输入值
   - review comment
   - 最终输出值
   - 对应 trace / log 关联字段

如果 UI 不支持直接按输出字段筛选，就必须提前准备一个等价的 fallback 路径，并在计划里写清楚。不能演示当天才发现这个过滤条件只能靠后端查库。

### 5. Human Task 审批体验设计

现在的计划只说“从一个 nodejs 中发起 manual Approval API”，这不够。需要明确审批这件事是怎么被人理解的。

#### 5.1 审批入口

推荐方案：本轮只做 `API-first` 审批入口，不额外做页面。

原因：

- 任务本身明确要求 `Node.js + TS + manual Approval API`。
- 额外做 UI 会稀释重点，属于典型的“为了显得完整而多做一层壳”。
- 对 demo 来说，结构化 API 返回 + Conductor UI 状态回流已经足够清楚。

Node review service 至少要提供以下能力：

- `POST /reviews/{taskId}/approve`
- `POST /reviews/{taskId}/reject`
- `POST /reviews/{taskId}/auto-review`

接口返回必须包含：

- `workflowId`
- `taskId`
- `decision`
- `comment`
- `trace_id`
- `processed_at`
- `delay_ms`

#### 5.2 审批文案与状态语义

审批节点不是黑箱。每种状态都要有统一语义：

- `PENDING_REVIEW`：任务已经创建，等待 reviewer service 接手。
- `REVIEWING`：Node service 已经取到任务，正在随机 sleep 模拟人工延迟。
- `APPROVED`：审批通过，进入下一节点。
- `REJECTED_WITH_COMMENT`：审批未通过，comment 会被回写并触发下一轮 `func1`。

无论这些状态最终落在日志、Conductor task output，还是 review service 响应里，都要用一致命名，避免一处写 `approved`，另一处写 `pass`。

### 6. 可观测性与跨进程关联的展示方式

“用了 OTel” 不是演示结果，能不能被看明白才是。

当前任务没有引入独立 trace backend，所以跨进程关联不能停留在 SDK 层，要落到可观察的字段上。

最小要求：

- Python worker、Node review、TS worker 的结构化日志全部带：
  - `workflowId`
  - `taskId`
  - `taskType`
  - `trace_id`
  - `span_id`
  - `decision`（review 节点）
  - `attempt`
- 关键业务指标至少区分：
  - workflow 启动数
  - workflow 完成数
  - review 等待时长
  - review 处理时长
  - worker 执行失败数
- Grafana 入口要预置至少一个 dashboard，能回答三个问题：
  - 现在一共有多少 workflow 在跑、成功、失败、等待 review？
  - review 延迟分布如何？
  - 某个 `workflowId` 或 `trace_id` 能否在日志里追到完整链路？

如果不引入 trace store，就不要假装有“分布式 trace UI”。本轮目标是把跨进程关联字段打通，并在日志 / 指标里查得出来。

### 7. 交互状态覆盖

这部分是当前计划最大的缺口之一。没有状态设计，最终演示只会剩下“好了”和“坏了”两种口头描述。

| 功能面 | LOADING | EMPTY | ERROR | SUCCESS | PARTIAL |
|--------|---------|-------|-------|---------|---------|
| 环境启动 | `docker compose ps` 显示服务逐步就绪，`verify` 输出当前等待项 | 首次启动前没有 workflow 数据，脚本提示先注册定义并启动 worker | 镜像拉取失败、Conductor/PG 未就绪、Grafana 数据源未连通时给出明确组件名 | 所有核心服务健康，给出访问入口列表 | 组件部分可用，例如 UI 能打开但 worker 未注册，必须明确提示“不可演示” |
| 单次 workflow 运行 | 列表页能看到执行刚创建，detail 页能看到当前节点 | 执行列表为空时，UI 操作说明引导先运行单条 happy path | workflow 卡死、review 超时、worker 未消费任务时给出具体卡点 | `func1 -> review -> func2` 闭环完成并返回 `y` | workflow 已完成但日志或指标缺字段，判定为“功能成功，观测失败” |
| 人工审批 | review 节点处于等待，review service 返回“已接单，处理中” | 没有待审批任务时，接口返回空集并提示当前无需操作 | approval API 调用失败、comment 回写失败、Conductor 鉴权失败时明确错误源 | approval/reject 生效，Conductor UI 状态更新，comment 可回查 | 审批完成但 Conductor UI 未及时刷新，需要说明刷新或轮询策略 |
| 1000 并发与筛选 | 批量提交脚本输出进度，UI 按时间窗口能看到执行逐步增多 | 如果没有满足 `y > 10.1` 的结果，必须说明这是数据分布问题，不是筛选坏了 | UI 无法按结果字段过滤、查询超时、列表页卡死时要有 fallback | 成功筛出满足条件的执行集合，并能 drill-down 到样本详情 | 筛选命中但无法联动到日志 / trace 字段，视为“结果可见，解释不完整” |
| 观测与关联 | dashboard 初始加载时能看到面板骨架和数据刷新提示 | 指标尚未采集到时，面板提示“等待首批样本”而不是空白 | otel collector、vector、victoria 任一链路断裂时能指向故障层 | 能按 `workflowId` / `trace_id` 查到 worker 与 review 的关联数据 | 只能看到 metrics 看不到 logs，或者反之，必须当场标明链路未完全打通 |

### 8. 用户旅程与情绪曲线

这不是消费级产品，但依然有情绪曲线。一个好的 demo，会让观众从“这堆组件好复杂”变成“原来链路这么清楚”。

| 步骤 | 操作者在做什么 | 旁观者感受 | 计划里必须提供什么支撑 |
|------|----------------|------------|------------------------|
| 1 | 启动环境 | 不确定，怕环境起不来 | 一键启动命令、健康检查脚本、入口 URL 列表 |
| 2 | 跑单条 workflow | 开始理解链路 | execution detail 页面路径、样例输入、预期节点顺序 |
| 3 | 等待人工审批 | 有一点悬念，想看“人”在哪里介入 | review 节点状态、随机延迟说明、审批接口返回示例 |
| 4 | 查看 approval / reject 结果 | 建立对 Human Task 真实性的信任 | comment 回写规则、拒绝后回路重试说明 |
| 5 | 跑 1000 条并做筛选 | 产生规模感，想知道系统有没有乱 | 批量脚本输出、列表过滤步骤、样本 drill-down |
| 6 | 打开 Grafana / logs | 想知道这不是“看起来能跑” | dashboard、日志查询样例、关联字段说明 |
| 7 | 故障演示或排障 | 希望快速定位，不想看漫无目的翻日志 | 常见故障入口、组件级错误提示、fallback 命令 |

### 9. 反 AI Slop 约束

这个任务的“AI slop”不体现在网页卡片，而体现在 demo 叙事。最容易做烂的方式，是堆很多组件，但没有一个主镜头。

本次必须遵守下面的约束：

- 不新做一个“统一大屏”去复制 Conductor 和 Grafana 已有能力。
- 不把审批、筛选、观测三件事塞到一个入口里讲。
- 不使用模糊词，例如“看一下监控”“演示筛选能力”。每个动作都要写成能执行的步骤。
- 不让观众自己脑补字段含义。`workflowId`、`trace_id`、`decision`、`comment` 的出现位置要固定。
- 不让颜色成为唯一信号。筛选结果、审批结果、链路关联都必须能通过文本字段确认。

### 10. 响应式与可访问性约束

本轮没有自定义前端，所以不追求移动端设计，但仍然需要可操作性约束：

- 所有演示步骤按桌面浏览器定义，优先在 `1280px+` 视口验证。
- 每个浏览器步骤都要提供对应 URL，避免现场点丢了之后找不到入口。
- 每个 UI 操作都应该有一个命令行或 API fallback，防止现场 UI 抽风时完全失去演示能力。
- Dashboard 和日志查询不能只靠颜色区分状态，必须有文本标签、数值或筛选字段。
- 如果后续补最小审批页面，再补键盘可达、焦点顺序、最小点击区域要求；本轮先不扩 scope。

### 11. 复用现有资产

本次任务不应该从零发明操作手册，现有仓库已经有可直接复用的模式：

- `reference/observability-platform-demo/README.md`
  - 复用其 `快速开始 / 验证 / 访问入口 / 手工验证` 结构
  - 复用其 Grafana 预置数据源、dashboard、构建代理与国内镜像策略
- `reference/nomad-demo/README.md`
  - 复用其 UI 入口说明和“如果 UI 不稳定，给出 API / SSH tunnel fallback”的写法
- `.agents/skills/conductor/SKILL.md`
  - 复用其 workflow 定义、task definition、worker 注册与运行检查流程

### 12. 明确不在本次范围

- 不做 PostgreSQL 观测。原任务已明确排除。
- 不做 Conductor / PostgreSQL 高可用。
- 不做额外的审批 Web UI。
- 不做移动端演示。
- 不做独立 trace backend；本轮只要求把跨进程关联字段打通并能在现有观测面里查到。

### 13. 需要在实现前锁定的设计决策

以下决策如果不提前写死，实施时一定会反复返工：

1. `审批入口采用 API-first`，不新增页面。
2. `Conductor UI` 是工作流真相源，`Grafana` 是观测真相源，不新增统一总览页。
3. `1000` 并发后的筛选演示以 `Conductor UI` 为主，必须准备一个命令行 fallback。
4. 跨进程关联以 `workflowId + taskId + trace_id` 作为统一检索键。
5. 所有 demo 步骤先走单条 happy path，再走批量路径，不允许一上来直接压 `1000` 条。

## 工程审查补充（已合并进计划）

这份计划现在不缺“想做什么”，缺的是“怎么用最少的系统把它稳定做出来”。工程审查的目标不是继续加组件，而是把可落地路径钉死，避免实现阶段边做边改。

### 1. Step 0 结论：先缩 scope，再把闭环做实

#### 1.1 现在就应该锁死的 scope

保留：

- `docker compose` 本地编排
- `Conductor + PostgreSQL`
- `Python func1 worker`
- `Node.js review service + HUMAN task completion`
- `TypeScript func2 worker`
- `OTel metrics + Vector logs + Victoria + Grafana`
- `CLI bootstrap / verify / bulk / fallback`

移出本轮：

- `Nomad / Consul / Vault`
- `Nginx / Envoy / API Gateway` 三选一以外的网关实验
- 通用“丢包 / 抖动 / chaos”注入层
- 容器镜像发布、CI/CD、远端部署

理由很简单：真正证明价值的是 `func1 -> HUMAN review -> func2`、跨语言链路、批量运行与可观测性，不是额外多挂几个基础设施名词。这个 repo 现在还没有实现代码，继续把演示目标和基础设施目标绑在一起，只会把第一版拖死。

#### 1.2 What already exists

- `reference/observability-platform-demo/docker-compose.yml`
  - 已经给了代理透传、共享日志 volume、Grafana 预置数据源、Collector / Vector / Victoria 最小链路。
- `reference/observability-platform-demo/verify.sh`
  - 已经给了“等待服务就绪 -> 造流量 -> 校验 metrics / logs / dashboard”的验收节奏。
- `reference/nomad-demo/README.md`
  - 已经给了“UI 如果不稳，要给 API / tunnel / CLI fallback”的写法。
- `.agents/skills/conductor/SKILL.md`
  - 已经给了 workflow / task definition 注册和 worker 检查流程。

这意味着本轮不应该再发明新的启动协议或观测说明文档，应该复用已有结构，只把任务特有的 workflow / review / bulk 逻辑补上。

#### 1.3 Search check 后的工程结论

- `HUMAN` task 本身就是“等待外部信号”的官方模型，完成方式是 `POST api/tasks`，不需要额外伪造 review worker。
- `Conductor UI` 对 workflow input / output 的自由查询能力依赖 indexing；如果 indexing 关掉，UI 搜索能力会直接失效。
- 最新官方文档显示 PostgreSQL 可以承担 indexing，但要显式打开 `conductor.indexing.enabled=true` 和 `conductor.indexing.type=postgres`。
- `DO_WHILE + SET_VARIABLE` 正好能表达“反复 func1 -> review，直到 approve”为止的流程，不需要自定义调度逻辑。
- OTel 对非 OTLP 文本 / JSON 日志要求把 `trace_id`、`span_id` 放在顶层字段，不能藏在 message 里。

这几条意味着：本轮可以保持“纯 PostgreSQL”方向，但不能只配 `db.type=postgres` 就指望 UI 搜索自己工作，必须把 indexing 和 fallback 一并写进计划。

工程依据：

- `HUMAN` task 与 `POST api/tasks`：https://conductor-oss.github.io/conductor/documentation/configuration/workflowdef/systemtasks/human-task.html
- workflow 搜索与 indexing 依赖：https://conductor-oss.github.io/conductor/devguide/how-tos/Workflows/searching-workflows.html
- PostgreSQL indexing 配置：https://conductor-oss.github.io/conductor/documentation/advanced/postgresql.html
- Docker 部署里 UI 搜索对 indexing 的依赖：https://conductor-oss.github.io/conductor/devguide/running/docker.html
- `DO_WHILE` / `SET_VARIABLE`：https://conductor-oss.github.io/conductor/documentation/configuration/workflowdef/operators/do-while-task.html
- `SET_VARIABLE`：https://conductor-oss.github.io/conductor/documentation/configuration/workflowdef/operators/set-variable-task.html
- OTel log correlation 与顶层字段：https://opentelemetry.io/docs/specs/otel/logs/ 、https://opentelemetry.io/docs/specs/otel/compatibility/logging_trace_context/

### 2. 锁定的最小实现架构

#### 2.1 组件边界

```text
Demo Operator
  -> scripts/bootstrap.sh
  -> scripts/register-defs.sh
  -> scripts/run-one.sh / scripts/run-bulk.sh
  -> scripts/verify.sh
  -> scripts/search-output.sh

Conductor UI / API
  <- workflow start / state / search
  <- HUMAN task waiting

Python worker (func1)
  <- poll SIMPLE task: func1_python
  -> output: candidate_x, attempt, comment_in

Node review service
  -> list pending HUMAN tasks
  -> approve / reject / auto-review via Conductor Task API
  -> output: decision, comment, delay_ms, next_x, review_trace_id

TS worker (func2)
  <- poll SIMPLE task: func2_ts
  -> output: y

Python / Node / TS
  -> JSON logs with top-level trace fields -> Vector -> VictoriaLogs
  -> OTel metrics -> OTel Collector -> vmagent -> VictoriaMetrics -> Grafana
```

#### 2.2 Workflow 定义必须长这样

本轮不要只停留在伪代码，直接按下面这个状态机设计 workflow definition：

```text
workflow input
  x
  correlation_id
  auto_review
  review_mode
  bulk_seed
    |
    v
SET_VARIABLE init_state
  current_x = x
  last_comment = ""
  last_decision = "PENDING_REVIEW"
  approved = false
    |
    v
DO_WHILE review_loop (maxAttempts = 8, keepLastN = 5)
  |
  +--> SIMPLE func1_python
  |      input: current_x, last_comment, attempt
  |      output: candidate_x
  |
  +--> HUMAN review_gate
  |      input: candidate_x, attempt, correlation_id, traceparent
  |      output: decision, comment, delay_ms, next_x
  |
  +--> SET_VARIABLE update_state
         current_x = review_gate.output.next_x
         last_comment = review_gate.output.comment
         last_decision = review_gate.output.decision
         approved = (decision == "APPROVED")
    |
    v
SWITCH last_decision
  APPROVED -> SIMPLE func2_ts -> workflow output { y, decision, comment, trace_id }
  default  -> TERMINATE with explicit reason
```

这里有三个硬约束：

- `func1` 和 `func2` 是唯一的业务 worker，review 不是第三个 worker，而是 `HUMAN` task + 外部 API 完成。
- `review_loop` 必须有 `maxAttempts`，否则 reject 路径可以无限循环。
- `DO_WHILE` 要显式设置 `keepLastN`，即使这不是长循环，也要避免批量跑时把历史 iteration 全留在库里。

#### 2.3 Review service 的 API 不能只有 approve / reject

当前计划只有：

- `POST /reviews/{taskId}/approve`
- `POST /reviews/{taskId}/reject`
- `POST /reviews/{taskId}/auto-review`

这不够，因为操作者还需要“找到待审批任务”。本轮 API 最少应扩成：

- `GET /reviews/pending?workflowId=&limit=`
- `POST /reviews/{taskId}/approve`
- `POST /reviews/{taskId}/reject`
- `POST /reviews/{taskId}/auto-review`

`GET /reviews/pending` 返回字段至少包括：

- `workflowId`
- `taskId`
- `taskRefName`
- `candidate_x`
- `attempt`
- `created_at`
- `trace_id`

`approve / reject / auto-review` 返回字段至少包括：

- `workflowId`
- `taskId`
- `decision`
- `comment`
- `delay_ms`
- `next_x`
- `trace_id`
- `processed_at`

没有 `GET /reviews/pending`，这个 API-first 审批入口实际上不可用，只是把 taskId 这个内部实现细节甩给了操作者。

#### 2.4 搜索与筛选的正式方案

本轮保留“纯 PostgreSQL”目标，但必须把搜索方案写死：

```text
Phase A: 基础状态筛选
  Conductor UI
    -> workflow name
    -> time range
    -> status

Phase B: 结果值筛选 proof
  优先验证 UI free-text / search API 是否能稳定命中 output.y

Phase C: fallback
  scripts/search-output.sh
    -> 调 workflow search API 拉近时段执行
    -> 本地过滤 output.y > 10.1
    -> 输出 workflowId / y / comment / trace_id
```

需要补两条明确规则：

- `docker compose` 配置里必须显式开启 PostgreSQL indexing。
- `scripts/prove-search.sh` 要在实现最早阶段就验证 `output.y` 是否真能被 UI / API 稳定检索，而不是等 1000 并发后才发现这个字段查不出来。

如果最终 UI 只能稳定按 `workflow name + status + time range` 收敛，而不能可靠做 `output.y > 10.1` 的数值筛选，那么 bulk demo 的口径必须调整成：

- `Conductor UI` 负责缩小样本集
- `CLI fallback` 负责精确结果筛选

这不是降级，这是把演示建立在可验证能力之上。

### 3. 代码组织与配置约束

#### 3.1 最小目录建议

```text
.
├── docker-compose.yml
├── .env.example
├── config/
│   ├── conductor/
│   ├── grafana/
│   ├── otel-collector/
│   └── vector/
├── workflows/
│   └── human-review-demo.json
├── taskdefs/
│   ├── func1-python.json
│   └── func2-ts.json
├── workers/
│   ├── func1-python/
│   └── func2-ts/
├── services/
│   └── review-service/
├── scripts/
│   ├── bootstrap.sh
│   ├── register-defs.sh
│   ├── run-one.sh
│   ├── run-bulk.sh
│   ├── search-output.sh
│   └── verify.sh
└── tests/
    └── e2e/
```

这已经是能完成目标的最小骨架了。不要再拆更多顶层目录，不要搞共享 SDK 包，不要为了“以后可能扩展”先做 monorepo 工具层。

#### 3.2 共享契约必须单点定义

跨语言项目最容易烂在字段漂移。下面这些字段必须在计划里就定义成共享契约，并且所有 worker / service / 脚本 / tests 都按同一命名：

- review 状态：`PENDING_REVIEW`、`REVIEWING`、`APPROVED`、`REJECTED_WITH_COMMENT`
- workflow 关联：`workflowId`、`taskId`、`taskType`
- trace 关联：`trace_id`、`span_id`、`trace_flags`
- review 结果：`decision`、`comment`、`delay_ms`、`next_x`

不要一边写 `processedAt`，另一边写 `processed_at`。这类问题实现时看起来小，联调和演示时最烦。

#### 3.3 配置规则

- 所有入口地址、Conductor 鉴权、Grafana 账号、代理变量都放 `.env.example`。
- `scripts/*` 只读环境变量，不在脚本里写死 host / port / token。
- 需要公网 / 内网“味道”时，本轮最多加一个反向代理层；没必要同时摆 `Nginx / Envoy / API Gateway` 三个候选。

### 4. 测试审查

当前仓库没有可复用的现成测试框架，所以本轮直接锁定：

- Python worker：`pytest`
- TypeScript worker / review service：`node:test` + `tsx`
- 端到端验收：`bash + curl + jq`

理由：

- 这三个入口都很 boring，没有额外脚手架债。
- 这个 repo 是 compose-first demo，不值得为了测试再引入一层复杂 runner。

#### 4.1 CODE PATH COVERAGE

```text
CODE PATH COVERAGE
===========================
[+] scripts/register-defs.sh
    ├── [GAP] 注册 task definitions
    ├── [GAP] 注册 workflow definition
    └── [GAP] 检查 worker queue / task definition 是否齐全

[+] workers/func1-python
    ├── [GAP] comments 为空的首轮输入
    ├── [GAP] reject 后 comments 回流
    └── [GAP] 非法输入 / attempt 超限

[+] services/review-service
    ├── [GAP] GET /reviews/pending 空结果
    ├── [GAP] approve happy path
    ├── [GAP] reject happy path
    ├── [GAP] auto-review 批量处理
    ├── [GAP] taskId 不存在 / 已终态
    └── [GAP] Conductor 鉴权失败

[+] workflow orchestration
    ├── [GAP] DO_WHILE 在 APPROVED 时退出
    ├── [GAP] reject 后继续下一轮
    └── [GAP] maxAttempts 触发 TERMINATE

[+] workers/func2-ts
    ├── [GAP] approved 路径计算 y
    └── [GAP] 输入缺字段时失败并返回明确错误

[+] observability
    ├── [GAP] logs 带顶层 trace_id / span_id
    ├── [GAP] review decision / delay_ms 被记录
    ├── [GAP] metrics 已上报到 Grafana
    └── [GAP] metrics 未使用 workflowId / trace_id 作为 label

[+] bulk / search
    ├── [GAP] 1000 workflow 提交汇总
    ├── [GAP] output.y > 10.1 查询 proof
    └── [GAP] UI 不可用时 CLI fallback
```

#### 4.2 USER FLOW COVERAGE

```text
USER FLOW COVERAGE
===========================
[+] 单条 happy path
    ├── [GAP] [→E2E] start workflow -> wait HUMAN -> approve -> func2 -> completed
    └── [GAP] [→E2E] detail 页面与 API 返回字段一致

[+] reject 回路
    ├── [GAP] [→E2E] reject 一次后 comments 回写并再次进入 func1
    └── [GAP] [→E2E] 多次 reject 后命中 maxAttempts 终止

[+] 批量路径
    ├── [GAP] [→E2E] 1000 条批量启动进度输出
    ├── [GAP] [→E2E] UI status/time range 收敛
    └── [GAP] [→E2E] CLI fallback 输出样本 drill-down

[+] 错误恢复
    ├── [GAP] review service 无待处理任务
    ├── [GAP] worker 未注册
    ├── [GAP] Grafana datasource 未就绪
    └── [GAP] search proof 失败时给出 fallback 提示

─────────────────────────────────
COVERAGE: 0/23 paths tested (0%)
  Code paths: 0/16
  User flows: 0/7
GAPS: 23 条路径全部需要补测试
─────────────────────────────────
```

#### 4.3 必须写进计划的测试文件

- `workers/func1-python/tests/test_func1_worker.py`
  - 断言首轮输入、reject comment 回流、非法输入报错。
- `workers/func2-ts/test/func2-worker.test.ts`
  - 断言 `y` 计算、缺失输入时报错。
- `services/review-service/test/pending.test.ts`
  - 断言无待审批、按 workflowId 过滤、字段完整性。
- `services/review-service/test/decision.test.ts`
  - 断言 approve / reject / task 终态冲突 / 鉴权失败。
- `services/review-service/test/auto-review.test.ts`
  - 断言并发处理上限、随机 delay 范围、汇总统计。
- `tests/e2e/happy-path.sh`
  - 跑通单条 approve 闭环。
- `tests/e2e/reject-loop.sh`
  - 验证 reject -> func1 回路 -> 最终 approve。
- `tests/e2e/bulk-search.sh`
  - 验证批量启动、UI/API 搜索、CLI fallback。
- `tests/e2e/observability.sh`
  - 验证 Grafana datasource、metrics、logs、trace fields。
- `tests/e2e/failure-surface.sh`
  - 验证 worker 缺席、search proof 失败、review 无待处理任务时的报错文本。

### 5. Failure modes

| Codepath | 真实故障模式 | 测试是否覆盖 | 是否有错误处理 | 用户感知 | 结论 |
|----------|--------------|--------------|----------------|----------|------|
| workflow 注册 | task definition 没注册，执行卡在 `SCHEDULED` | 计划要求覆盖 | `register-defs.sh` 必须检查 | 可见，但容易误判为 worker 挂了 | 必须在 verify 中显式拦截 |
| pending review 获取 | API 无法列出 HUMAN task，操作者拿不到 taskId | 计划要求覆盖 | 需补 `GET /reviews/pending` | 否则近似静默失败 | 现已补为必做项 |
| HUMAN completion | taskId 已终态或过期，approve/reject 失败 | 计划要求覆盖 | review service 返回 4xx/5xx + 原因 | 明确可见 | 必做 |
| reject 回路 | 没有 `maxAttempts`，workflow 无限循环 | 计划要求覆盖 | workflow definition 里硬性限制 | 不可接受 | 必做 |
| bulk 搜索 | `output.y` 无法被 UI / API 稳定检索 | 计划要求覆盖 | `prove-search.sh + search-output.sh` fallback | 可见，但需提前化解 | 必做 |
| trace 关联 | HUMAN 边界丢失 trace context，logs 断链 | 计划要求覆盖 | 明确 `traceparent` 传递与顶层日志字段 | 否则是静默失败 | 必做 |
| metrics 设计 | 把 `workflowId` 当 label，Victoria / Grafana 基数爆炸 | 计划要求覆盖 | 计划中禁止高基数 label | 前期不明显，后期慢 | 必做 |

上表里原本最危险的三个 silent failure 是：

1. 没法拿 pending review。
2. HUMAN 边界 trace 断链。
3. `output.y` 查询能力假设过头。

这三个现在都已经被收敛成明确实现项和测试项，不再允许“实现时再看”。

### 6. 性能与容量审查

#### 6.1 1000 并发不能靠默认值硬冲

Conductor 官方文档已经给了 `concurrentExecLimit`、`responseTimeoutSeconds`、`timeoutSeconds` 这些 boring 控制项。本轮必须在 task definition 里显式配出来，不能全部吃默认值。

建议：

- `func1_python.concurrentExecLimit = 32`
- `func2_ts.concurrentExecLimit = 32`
- `responseTimeoutSeconds = 30`
- `timeoutSeconds = 60`
- `retryCount = 2`
- `retryDelaySeconds = 5`

对这个 demo 来说，这已经足够保守，也足够稳定。

#### 6.2 bulk auto-review 必须限并发

`0-5s` 随机延迟如果串行处理，`1000` 个任务平均要跑四十多分钟，演示直接报废。`auto-review` 必须支持受控并发，例如：

- `POST /reviews/auto-review?limit=1000&concurrency=32`

并返回：

- 提交数
- 已完成数
- 失败数
- 正在处理中数量
- 平均 delay

#### 6.3 PostgreSQL indexing 的保守优化

既然本轮坚持纯 PostgreSQL，就顺手把文档里最值的那个优化写进计划：

- `conductor.postgres.onlyIndexOnStatusChange=true`

理由很直接：这次 workflow 有 loop，有 1000 并发，不需要每个 task 完成就全量重索引一次。

#### 6.4 观测性能约束

- `workflowId`、`taskId`、`trace_id` 只进 logs，不进 metrics label。
- metrics label 只允许低基数字段，例如 `service`、`task_type`、`decision`、`result`。
- 每个 task 最多记录“开始 / 结束 / 决策”三类业务日志，避免 bulk demo 把日志量自己打爆。

### 7. NOT in scope

在原计划基础上，再明确下面这些不做：

- 不做 Nomad / Consul / Vault，本轮只保留 docker compose 语义上的最小网络隔离。
- 不做额外的 API Gateway 选型对比，本轮至多一个反向代理层。
- 不做 Elasticsearch / OpenSearch 兜底集成，除非后续明确放弃“纯 PostgreSQL”目标。
- 不做容器镜像发布、CI workflow、GitHub Releases。
- 不做 trace backend、trace UI、tempo / jaeger / zipkin。
- 不做性能极限压测报告；`1000` 并发仅服务于演示验收，不做 benchmark 宣传。

### 8. Worktree 并行实现策略

| Step | Modules touched | Depends on |
|------|----------------|------------|
| 基础编排与配置 | `config/`, `docker-compose.yml`, `scripts/` | — |
| Workflow 与 review 契约 | `workflows/`, `taskdefs/`, `services/review-service/` | 基础编排与配置 |
| Worker 实现 | `workers/func1-python/`, `workers/func2-ts/` | Workflow 与 review 契约 |
| 验收与 bulk/fallback | `tests/e2e/`, `scripts/` | 基础编排与配置, Workflow 与 review 契约, Worker 实现 |

并行 lane：

- Lane A: 基础编排与配置 -> 验收与 bulk/fallback
- Lane B: Workflow 与 review 契约 -> Worker 实现

执行顺序：

- 先开 `Lane A + Lane B` 两个 worktree 并行。
- `Lane A` 先把 compose / Grafana / verify 框架搭起来。
- `Lane B` 在契约锁定后实现 workflow JSON、review API、两个 worker。
- 两条线合并后，再统一跑 `tests/e2e/*`。

冲突提示：

- `scripts/` 会被 `Lane A` 和最终验收阶段同时改，属于轻度冲突区。
- `config/` 只让 `Lane A` 负责，别让 worker 线顺手改 collector / vector 配置。

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 21 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | issues_open | score: 3/10 -> 8/10, 5 decisions |

**UNRESOLVED:** 0 个待用户回答的问题。
**VERDICT:** ENG CLEARED，可以开始按“最小闭环 -> bulk -> fallback -> observability”顺序实现；最先要验证的是 PostgreSQL indexing 下 `output.y` 的搜索 proof。
