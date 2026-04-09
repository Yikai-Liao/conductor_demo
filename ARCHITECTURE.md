# 架构与实现说明

这份文档不重复 README 的操作手册。README 负责让操作者 3 分钟内跑起来，这里负责说明这套 demo 实际怎么搭、为什么这么搭、踩过哪些坑。

## 当前实现总览

当前仓库的运行面分成三层：

- `docker compose` 只起基础设施：`vault`、`postgres`、`gateway`、`otel-collector`、`vector`、`victoria-metrics`、`victoria-logs`、`grafana`、`toolbox`
- 宿主机控制面跑 `consul` 和 `nomad`
- 业务组件全部作为 `Nomad jobs` 运行：`conductor`、`conductor-ui`、`func1-python`、`review-service`、`func2-ts`

这是这次实现里最关键的边界。业务组件不再依赖写死的 compose service name，也不再靠把内部端口全部暴露到宿主机来“跑通”。

## 组件边界

### 1. Gateway

唯一默认对外的业务入口是 Gateway，也就是 `http://localhost:18080`。

它负责四件事：

- `/` 代理到 `conductor-ui`
- `/api/` 代理到 `conductor-api`
- `/swagger-ui/` 代理到 Conductor server 的 Swagger
- `/review/` 代理到 `review-service`

Gateway 本身不写死上游地址。它会定时查询 `Consul` 健康服务列表，然后动态重渲染 Nginx 配置。实现见 [gateway/entrypoint.sh](gateway/entrypoint.sh)。

### 2. Conductor 运行时

Conductor server 和 UI 都是 `Nomad jobs`，不是 compose service：

- [jobs/conductor.nomad.hcl](jobs/conductor.nomad.hcl)
- [jobs/conductor-ui.nomad.hcl](jobs/conductor-ui.nomad.hcl)

Conductor server 通过 Nomad template 在启动时渲染 PostgreSQL 配置，其中：

- PostgreSQL 地址来自 `Consul` 服务发现
- 数据库用户名和密码来自 `Vault`

这条链路是这次实现里专门保住的，不再退化成把账号密码直接写进 compose env。

### 3. Worker 与审批服务

工作流链路固定是：

```text
func1-python -> HUMAN review -> func2-ts
```

对应文件：

- workflow definition: [workflows/human-review-demo.json](workflows/human-review-demo.json)
- task definitions: [taskdefs/func1-python.json](taskdefs/func1-python.json)、[taskdefs/func2-ts.json](taskdefs/func2-ts.json)
- Python worker: [workers/func1-python](workers/func1-python)
- TypeScript worker: [workers/func2-ts](workers/func2-ts)
- review service: [services/review-service](services/review-service)

`review-service` 对外只通过 Gateway 暴露 `/review/*`，容器自身端口不直接暴露到宿主机。

## 服务发现、配置分发、密钥分发

这三个要求在这次实现里是硬约束，不是可选优化。

### 服务发现, `Consul`

来源有两类：

- 基础设施服务由 [scripts/register-infra-services.sh](scripts/register-infra-services.sh) 注册
- Nomad job 里的业务服务由 `service` stanza 自动注册

当前会被 Consul 看到的关键服务包括：

- `postgres`
- `otel-collector-otlp-http`
- `conductor-api`
- `conductor-ui`
- `review-service`
- `func1-python`
- `func2-ts`

### 配置分发, `Nomad template + Consul KV`

[scripts/init-control-plane.sh](scripts/init-control-plane.sh) 会把 demo 运行参数写进 `Consul KV`，例如：

- `config/conductor-demo/func1/worker_concurrency`
- `config/conductor-demo/func2/idle_sleep_ms`
- `config/conductor-demo/review/approval_threshold`
- `config/conductor-demo/review/max_delay_ms`

随后 `jobs/*.nomad.hcl` 通过 template 把这些值渲染成环境变量。也就是说，worker 和 review service 看到的是渲染后的运行配置，不是手写死的 compose env。

### 密钥分发, `Vault`

当前使用的是 compose 内的单节点 `Vault`。服务端数据走 Docker named volume，`root-token` / `unseal-key` 落在 `runtime/vault-state/`，原因很直接：

- 宿主机现成有 `consul` 和 `nomad`
- 宿主机没有 `vault` 二进制
- 这次 demo 需要的是“密钥分发路径被体现出来”，同时又不能每次重启都重新初始化

[scripts/init-control-plane.sh](scripts/init-control-plane.sh) 会完成：

- 开启 `jwt-nomad` auth
- 配置 `nomad-workloads` role
- 写入 Conductor 数据库凭据
- 写入 review API token

对应 job 再通过 `vault` stanza + template 取出 secret。当前这条路径足以证明“密钥来自 Vault”，同时避免了每次重启都重新 seed Vault。

## 端口与网络边界

默认暴露到宿主机的只有这些入口：

- `http://localhost:18080`，Gateway / Conductor UI / API / Review API
- `http://localhost:13000`，Grafana
- `http://localhost:8428`，VictoriaMetrics HTTP API
- `http://localhost:9428`，VictoriaLogs HTTP API
- `http://localhost:4317`，OTel Collector OTLP/gRPC
- `http://localhost:4318`，OTel Collector OTLP/HTTP
- `http://localhost:8889/metrics`，OTel Collector Prometheus exporter
- `http://localhost:8686`，Vector API
- `http://localhost:18200`，Vault API，仅本机访问
- `http://127.0.0.1:4646`，Nomad UI / API
- `http://127.0.0.1:8500`，Consul UI / API

默认不暴露：

- `PostgreSQL`
- `func1-python`
- `func2-ts`
- `review-service` 容器端口
- `vmagent`

这不是洁癖，是为了保证 demo 的网络边界和讲述口径一致。否则一边说“通过网关和服务发现访问”，一边又把所有内部端口摊平到宿主机，观众一眼就会看出是假的。

## 启动流程为什么拆成三段

当前脚本拆成：

- [scripts/up.sh](scripts/up.sh)，起基础设施和宿主机控制面
- [scripts/seed.sh](scripts/seed.sh)，构建业务镜像、初始化控制面、提交 Nomad jobs、注册 definitions
- [scripts/bootstrap.sh](scripts/bootstrap.sh)，串联 `up.sh + seed.sh`
- [scripts/reconcile.sh](scripts/reconcile.sh)，只补齐缺失状态，适合 `systemd` 日常拉起

这样拆的原因很朴素：

- `up.sh` 失败时，问题通常在基础设施层
- `seed.sh` 失败时，问题通常在镜像、Vault、Consul KV、Nomad submit 或 Conductor metadata
- 演示时可以一键跑，排障时又不用每次把整套环境全砸一遍
- `systemd` 场景下不应该每次执行完整 bootstrap，而应该走 `reconcile.sh`

## 构建、代理和镜像源

这是这次实现里最容易浪费时间的一块。

当前处理方式：

- [scripts/build-images.sh](scripts/build-images.sh) 统一用 `docker build --network host`
- Docker 基础镜像和运行时镜像统一走 `docker.randallanjie.com`
- Python 依赖使用阿里云 PyPI 镜像
- Node 依赖使用 `npmmirror`
- Alpine 构建阶段切到阿里云 Alpine 镜像
- Conductor UI 的 Debian 包切到阿里云 Debian 镜像
- Grafana 的 VictoriaLogs 插件先在宿主机下载，再 `COPY` 进镜像

最后这条很重要。Docker build 期间最烦的不是“没代理”，而是“代理看起来有，实际上下载插件时就是不走”。把插件预下载到仓库固定路径，问题立刻少一半。

## Workflow 编排与运行时的分工

workflow 编排推荐用 `https://developer.orkescloud.com/workflowDef`，但本地真正执行的单一真相源仍然是：

- [workflows/human-review-demo.json](workflows/human-review-demo.json)

推荐流程：

1. 在 Orkes 页面里调结构
2. 把最终 JSON 回写仓库
3. 用 [scripts/register-defs.sh](scripts/register-defs.sh) 或 [scripts/seed.sh](scripts/seed.sh) 注册

原因很简单。Orkes 页面适合编排和看图，本地自建 OSS 栈才是这次 demo 的实际运行环境。两者不要混成一件事。

## 结果筛选这件事，当前真实情况

这部分必须写实，不然演示时会翻车。

当前稳定成立的能力是：

- `Conductor UI` 能做 `workflowType / status / time range` 收敛
- execution detail 能稳定查看 `decision`、`comment`、`final_x`、`y`
- [scripts/search-output.sh](scripts/search-output.sh) 能对批量执行结果做阈值核对

当前需要显式验证的能力是：

- `output.y > 10.1` 这种数值条件，能不能完全依赖当前 Conductor search backend 在 UI 或 API 中直接命中

所以仓库保留了两个脚本：

- [scripts/prove-search.sh](scripts/prove-search.sh)，检查当前 search backend 是否已经能命中 `output.y`
- [scripts/search-output.sh](scripts/search-output.sh)，对已完成执行做结果阈值核对

别把这两件事混了。一个是“搜索能力是否存在”，一个是“演示结果如何稳定核对”。

## 当前已知取舍

### 1. `Consul` / `Nomad` 在宿主机，`Vault` 在容器里

这是基于当前机器现状做的选择，不是理想化统一。

好处：

- 少掉一层二进制安装问题
- 直接复用宿主机现有 `consul` / `nomad`

代价：

- 控制面分布在宿主机与 compose 两侧，排障时要清楚自己在看哪一层

### 2. `Vault` 是单节点持久化，不是生产高可用

这套配置解决的是“重启后状态不丢”的问题，不解决生产级别的 HA、KMS auto-unseal、审计与访问隔离。

### 3. Gateway 动态刷新有时间窗

Gateway 默认每 `5s` 从 `Consul` 刷新一次上游。也就是说，Nomad job 刚起来的一瞬间，Gateway 视图可能会短暂滞后。这是预期行为，不是玄学故障。

### 4. `output.y` 数值筛选依赖索引表现

这件事不是代码写不写的问题，而是当前 Conductor OSS 搜索链路对输出字段的索引表现问题。文档和演示都要把这件事说清楚，别假装 stock UI 一定能完成所有数值筛选。

## 给后来维护者的排障入口

排障时先问自己卡在哪一层：

1. 基础设施层
   - `docker compose ps`
   - `./scripts/up.sh`
2. 控制面层
   - `http://127.0.0.1:8500`
   - `http://127.0.0.1:4646`
   - `http://localhost:18200`
3. 运行时层
   - `./scripts/seed.sh`
   - `nomad job status`
   - `consul catalog services`
4. 业务链路
   - `./scripts/run-one.sh --x 1`
   - `curl -H "Authorization: Bearer ..." http://localhost:18080/review/reviews/pending?limit=10`
5. 观测层
   - `http://localhost:13000`
   - `./tests/e2e/observability.sh`

先分层，再动手。别一上来就翻全量日志。那种排障方式唯一稳定的产出是浪费时间。
