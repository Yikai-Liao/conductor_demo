# conductor-demo

`conductor-demo` 是一个本地可运行的人机协同异步工作流 demo。它用 `docker compose` 只拉起基础设施，用宿主机 `Consul` / `Nomad` 做服务发现与作业调度，用 `Vault` 分发密钥，并通过 `Conductor OSS + PostgreSQL` 跑通一条 `func1 -> HUMAN review -> func2` 的最小闭环。

这个仓库的目标不是“把容器都拉起来”，而是给 demo 操作者一条固定、可重复的演示路径：启动环境、提交 Nomad jobs、跑单条工作流、做人工审批、批量触发工作流、查看执行结果和观测数据。

实现细节、踩坑记录和设计取舍见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 特性

- `docker compose` 只负责基础设施和网络分区模拟；业务组件通过 `Nomad jobs` 运行。
- 服务发现走 `Consul`，配置分发走 `Nomad template + Consul KV`，密钥分发走 `Vault`。
- 工作流由 Python `func1`、TypeScript `func2`、Node.js/TypeScript `review-service` 组成。
- 默认只暴露操作者需要的宿主机入口；`PostgreSQL`、worker、`review-service` 容器端口、OTel、Victoria 组件都保持内部可见。
- `workflowId`、`taskId`、`trace_id` 贯穿 worker、review、Conductor 输出、日志和指标。
- 内置启动、注册、单跑、批量、验收脚本，适合做固定流程演示。

## 安装

前置要求：

- Docker 与 Docker Compose
- 宿主机已安装 `consul`
- 宿主机已安装 `nomad`
- `curl`
- `jq`

首次启动：

```sh
cp .env.example .env
./scripts/bootstrap.sh
```

如果你要分步执行：

```sh
./scripts/up.sh
./scripts/seed.sh
```

默认宿主机入口：

- `http://localhost:18080`：Gateway、Conductor UI、Conductor API、Review API
- `http://localhost:13000`：Grafana
- `http://localhost:18200`：Vault dev API
- `http://127.0.0.1:4646`：Nomad UI / API
- `http://127.0.0.1:8500`：Consul UI / API

默认不直接暴露到宿主机的组件：

- `PostgreSQL`
- `func1-python`
- `func2-ts`
- `review-service` 容器端口
- `otel-collector`
- `vmagent`
- `victoria-metrics`
- `victoria-logs`
- `vector`

如果构建阶段需要代理，填写 `.env` 里的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 即可。

## 使用

下面这组命令对应一条真实的手工审批演示路径：拉起环境，提交一个 workflow，在 review service 里拿到待审批任务，完成审批，然后回查最终输出。

```sh
cp .env.example .env
./scripts/bootstrap.sh

export REVIEW_API_TOKEN="$(grep '^REVIEW_API_TOKEN=' .env | cut -d= -f2-)"
workflow_id="$(./scripts/run-one.sh --x 1 | jq -r '.workflowId')"

pending="$(curl -s \
  -H "Authorization: Bearer ${REVIEW_API_TOKEN}" \
  "http://localhost:18080/review/reviews/pending?workflowId=${workflow_id}&limit=10")"
task_id="$(echo "${pending}" | jq -r '.items[0].taskId')"

curl -s \
  -X POST \
  -H "Authorization: Bearer ${REVIEW_API_TOKEN}" \
  "http://localhost:18080/review/reviews/${task_id}/approve" | jq

curl -s "http://localhost:18080/api/workflow/${workflow_id}" | jq '{workflowId,status,output}'
```

演示时建议同时打开这几个页面：

- `http://localhost:18080/executions`
- `http://localhost:18080/swagger-ui/index.html`
- `http://localhost:13000`

如果你只想先验证 happy path：

```sh
./scripts/run-one.sh --x 1 --auto-review --wait
```

## Workflow 编排

推荐使用 Orkes Developer Edition 的 workflow editor 做 definition 编排和结构检查：

- 入口：`https://developer.orkescloud.com/workflowDef`
- 本地运行时单一真相源：[workflows/human-review-demo.json](workflows/human-review-demo.json)
- 注册脚本：[scripts/register-defs.sh](scripts/register-defs.sh)

推荐工作方式：

1. 先在 `https://developer.orkescloud.com/workflowDef` 里调整 workflow 结构。
2. 把最终结果回写到 [workflows/human-review-demo.json](workflows/human-review-demo.json)。
3. 运行 `./scripts/register-defs.sh`，或直接重新执行 `./scripts/seed.sh`。

本地 demo 的实际运行面仍然是这套自建的 `Nomad + Consul + Vault + Conductor OSS`。Orkes Developer Edition 只用来编排 definition，不作为本地运行时。

## 运行拓扑

运行面分三层：

- `docker compose`：`vault`、`postgres`、`gateway`、`otel-collector`、`vector`、`victoria-metrics`、`victoria-logs`、`grafana`、`toolbox`
- 宿主机控制面：`consul`、`nomad`
- `Nomad jobs`：`conductor`、`conductor-ui`、`func1-python`、`review-service`、`func2-ts`

配置和密钥分发方式是固定的：

- `scripts/register-infra-services.sh` 把基础设施注册进 `Consul`
- `scripts/init-control-plane.sh` 把运行参数写入 `Consul KV`，把数据库凭据和 review token 写入 `Vault`
- `jobs/*.nomad.hcl` 通过 `service`、`key`、`secret` 在运行时解析依赖、配置和密钥

这意味着业务组件不依赖写死的 compose service name，也不依赖为每个内部服务额外开宿主机端口。

## 人工审批 API

`review-service` 通过 Gateway 暴露在 `http://localhost:18080/review`，需要带 `Authorization: Bearer ${REVIEW_API_TOKEN}`。

常用接口：

- `GET /review/reviews/pending?limit=20`
- `GET /review/reviews/pending?workflowId=<workflowId>&limit=20`
- `POST /review/reviews/<taskId>/approve`
- `POST /review/reviews/<taskId>/reject`
- `POST /review/reviews/<taskId>/auto-review`
- `POST /review/reviews/auto-review?limit=1000&concurrency=32`

审批返回会包含这些核心字段：

- `workflowId`
- `taskId`
- `decision`
- `comment`
- `delay_ms`
- `next_x`
- `trace_id`
- `processed_at`

这条链路对应的代码位置：

- review service：[services/review-service](services/review-service)
- task definitions：[taskdefs/func1-python.json](taskdefs/func1-python.json)、[taskdefs/func2-ts.json](taskdefs/func2-ts.json)
- workflow definition：[workflows/human-review-demo.json](workflows/human-review-demo.json)

## 结果观察

单条执行推荐直接看 `Conductor UI`：

1. 打开 `http://localhost:18080/executions`
2. 按 `workflowType=human_review_demo`、`status`、时间范围收敛列表
3. 点开 execution detail，查看 `func1_python -> review_gate -> func2_ts` 的执行顺序
4. 在 output 里查看 `decision`、`comment`、`final_x`、`y`

批量演示常用命令：

```sh
./scripts/run-bulk.sh --count 1000 --concurrency 32
./scripts/search-output.sh --threshold 10.1
```

仓库同时保留一个搜索能力自检脚本：

```sh
./scripts/prove-search.sh
```

它只用来检查当前 Conductor search backend 是否已经能直接命中 `output.y` 这类结果字段。稳定演示路径仍然应该是：先在 `Conductor UI` 里按 workflow、状态、时间范围收敛，再结合输出详情或 `search-output.sh` 做阈值核对。

## 可观测性

观测入口是 `http://localhost:13000`。仓库已经预置 Grafana 数据源和 dashboard，用来把 worker、review、Conductor 的指标和日志串起来。

Grafana 默认账号密码：

- 用户名：`admin`
- 密码：`admin`

重点看这些关联字段：

- `workflowId`
- `taskId`
- `trace_id`

常用验收命令：

```sh
./scripts/verify.sh
./tests/e2e/control-plane.sh
./tests/e2e/happy-path.sh
./tests/e2e/reject-loop.sh
./tests/e2e/bulk-search.sh
./tests/e2e/observability.sh
./tests/e2e/failure-surface.sh
```

## 仓库结构

```text
.
├── config/
│   ├── conductor/
│   ├── consul/
│   ├── grafana/
│   ├── nomad/
│   ├── otel-collector/
│   ├── vault/
│   ├── vector/
│   └── vmagent/
├── docker/
├── gateway/
├── jobs/
├── scripts/
├── services/review-service/
├── taskdefs/
├── tests/e2e/
├── toolbox/
├── workers/
│   ├── func1-python/
│   └── func2-ts/
└── workflows/
```

## 相关组件

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [workflows/human-review-demo.json](workflows/human-review-demo.json)
- [taskdefs/func1-python.json](taskdefs/func1-python.json)
- [taskdefs/func2-ts.json](taskdefs/func2-ts.json)
- [jobs](jobs)
- [services/review-service](services/review-service)
- [workers/func1-python](workers/func1-python)
- [workers/func2-ts](workers/func2-ts)
- [scripts](scripts)

## 相关参考

- [Orkes Developer Edition Workflow Editor](https://developer.orkescloud.com/workflowDef)
- [reference/nomad-demo](reference/nomad-demo/README.md)
- [reference/observability-platform-demo](reference/observability-platform-demo/README.md)
- [.agents/skills/conductor/SKILL.md](.agents/skills/conductor/SKILL.md)

## 许可

当前仓库没有单独提供 `LICENSE` 文件。对外分发或复用前，请先补齐授权声明。
