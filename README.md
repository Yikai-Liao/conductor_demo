# conductor-demo

`conductor-demo` 是一个本地可运行的人机协同异步工作流 demo。它用 `docker compose` 只拉起基础设施，用宿主机 `Consul` / `Nomad` 做服务发现与作业调度，用 `Vault` 分发密钥，并通过 `Conductor OSS + PostgreSQL + OpenSearch` 跑通一条 `func1 -> HUMAN review -> func2` 的最小闭环。

这个仓库的目标不是“把容器都拉起来”，而是给 demo 操作者一条固定、可重复的演示路径：启动环境、提交 Nomad jobs、跑单条工作流、做人工审批、批量触发工作流、查看执行结果和观测数据。

实现细节、踩坑记录和设计取舍见 [ARCHITECTURE.md](ARCHITECTURE.md)。

如果要把链接直接发给只做平台测试的同事，看 [COLLEAGUE_QUICKSTART.md](COLLEAGUE_QUICKSTART.md)。

## 特性

- `docker compose` 只负责基础设施和网络分区模拟；业务组件通过 `Nomad jobs` 运行。
- 服务发现走 `Consul`，配置分发走 `Nomad template + Consul KV`，密钥分发走 `Vault`。
- 工作流由 Python `func1`、TypeScript `func2`、Node.js/TypeScript `review-service` 组成。
- Conductor 内置 UI 和 `/workflow/search` 直接支持中文关键词检索，索引由仓库内的 OpenSearch bootstrap 层预建。
- 默认只暴露操作者需要的宿主机入口；`PostgreSQL`、worker、`review-service` 容器端口、OTel、Victoria 组件都保持内部可见。
- `workflowId`、`taskId`、`trace_id` 贯穿 worker、review、Conductor 输出、日志和指标。
- 内置启动、注册、单跑、批量、验收脚本，适合做固定流程演示。

## 安装

前置要求：

- Docker 与 Docker Compose
- 宿主机已安装 `consul`
- 宿主机已安装 `nomad`
- 宿主机已安装 `socat`
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

如果你希望改成 `user systemd` 托管，并且开机自启、异常重拉：

```sh
./scripts/install-user-systemd.sh
systemctl --user enable --now conductor-demo.target
```

如果要实现“开机后无登录也自动拉起”，还需要额外执行一次：

```sh
loginctl enable-linger "$USER"
```

默认宿主机入口：

- `http://localhost:18080`：Gateway、Conductor UI、Conductor API、Review API
- `http://localhost:13000`：Grafana
- `http://localhost:8428`：VictoriaMetrics HTTP API
- `http://localhost:9428`：VictoriaLogs HTTP API
- `http://localhost:4317`：OTel Collector OTLP/gRPC
- `http://localhost:4318`：OTel Collector OTLP/HTTP
- `http://localhost:8889/metrics`：OTel Collector Prometheus exporter
- `http://localhost:8686`：Vector API
- `http://localhost:18200`：Vault API，仅本机访问
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

默认网络边界：

- `Gateway`、`Grafana`、`VictoriaMetrics`、`VictoriaLogs`、`OTel Collector`、`Vector API` 绑定在 `${PUBLIC_BIND_ADDR:-0.0.0.0}`，可用于局域网访问
- `Vault`、`Nomad`、`Consul` 仅绑定本机回环地址；容器侧通过 Docker host-gateway 代理访问，不直接暴露到局域网

补充说明：

- [scripts/start-host-proxies.sh](scripts/start-host-proxies.sh) 会在宿主机用 `socat` 打开到 Docker bridge gateway 的 `4646/8500` 代理
- 这样 `Vault`、`Gateway` 和 `toolbox` 容器能访问宿主机上的 `Nomad` / `Consul`，但宿主机进程本身仍然只监听 `127.0.0.1`

可观测系统直接访问方式：

- VictoriaMetrics:
  `http://localhost:8428`
  示例:
  `http://localhost:8428/vmui/`
  `http://localhost:8428/api/v1/query?query=up`
- VictoriaLogs:
  `http://localhost:9428`
  这套 demo 默认还是建议通过 Grafana 看日志；直接端口主要用于 API 调试和连通性验证
- OTel Collector:
  `4317` 用于 OTLP/gRPC
  `4318` 用于 OTLP/HTTP
  `http://localhost:8889/metrics` 可直接查看 Collector 自身导出的 Prometheus 指标
- Vector:
  `http://localhost:8686`
  用于查看 Vector API 和健康状态

默认 Docker 基础镜像改成 `docker.io`。Python / Node / Alpine / Debian 的现有包仓库设置保持不变。

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

如果不显式传 `--x`，默认会在 `1` / `2` 之间交替选取初始值，并把这个值编码进 `correlation_id`：

```json
{
  "workflowId": "...",
  "x": 1,
  "cn_case_title": "仓库巡检",
  "cn_keywords": "仓库巡检 入库托盘 破损照片 temperature log",
  "correlation_id": "run-one-x1-...",
  "review_mode": "auto"
}
```

`run-one.sh` 会根据初始值在两组中文样例之间切换：

- `x=1` 默认写入 `仓库巡检`
- `x=2` 默认写入 `合同复核`

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

- `docker compose`：`vault`、`postgres`、`opensearch`、`gateway`、`otel-collector`、`vector`、`victoria-metrics`、`victoria-logs`、`grafana`、`toolbox`
- 宿主机控制面：`consul`、`nomad`
- `Nomad jobs`：`conductor`、`conductor-ui`、`func1-python`、`review-service`、`func2-ts`

配置和密钥分发方式是固定的：

- `scripts/register-infra-services.sh` 把基础设施注册进 `Consul`
- `scripts/bootstrap-opensearch.sh` 在 Conductor 启动前预建中文 analyzer、index template 和 workflow/task index
- `scripts/init-control-plane.sh` 把运行参数写入 `Consul KV`，把数据库凭据和 review token 写入 `Vault`
- `jobs/*.nomad.hcl` 通过 `service`、`key`、`secret` 在运行时解析依赖、配置和密钥

这意味着业务组件不依赖写死的 compose service name，也不依赖为每个内部服务额外开宿主机端口。

补充说明：

- `Vault` 数据现在走 Docker named volume 持久化
- `Vault` 的 `root-token` / `unseal-key` 落在 `runtime/vault-state/`
- `scripts/reconcile.sh` 会在启动时只补齐缺失状态，不会每次重建整套环境

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
- `correlation_id`
- `initial_x`
- `initial_x_tag`
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

当前 workflow 最终 output 还会带上这些辅助检索字段：

- `cn_case_title`
- `cn_keywords`
- `cn_review_comment`
- `cn_final_summary`
- `correlation_id`
- `initial_x`
- `initial_x_tag`
- `y_tag`

批量演示常用命令：

```sh
./scripts/run-bulk.sh --count 1000 --concurrency 32
./scripts/search-output.sh --threshold 10.1
```

仓库同时保留一个搜索能力自检脚本：

```sh
./scripts/prove-search.sh
```

它会轮询 Conductor 自带的 `/workflow/search`，确认默认中文关键词 `仓库巡检` 已经能直接命中 demo workflow。稳定演示路径现在是：先在 `Conductor UI` 里输入中文关键词，再结合输出详情或 `search-output.sh` 做阈值核对。

如果你要证明“中文分词已经启用”，不要只搜完整短语。更好的演示是：

- 搜 `巡检`，应命中仓库类 workflow
- 搜 `付款`，应命中合同类 workflow
- 用 `toolbox` 对 `conductor_workflow` 执行 `_analyze`，检查 `icu_analyzer` 和 `conductor_cjk_recall` 的 token 输出

## 可观测性

观测入口是 `http://localhost:13000`。仓库已经预置 Grafana 数据源和 dashboard，用来把 worker、review、Conductor 的指标和日志串起来。

Grafana 默认账号密码：

- 用户名：`admin`
- 密码：`admin`

重点看这些关联字段：

- `workflowId`
- `taskId`
- `trace_id`
- `correlation_id`
- `initial_x_tag`
- `y_tag`

当前链路里有两个不同用途的数据面：

- `VictoriaLogs`：保留逐条日志事件，适合按 `workflowId`、`trace_id`、`correlation_id`、`y` 直接检索具体 workflow。
- `VictoriaMetrics`：保留聚合后的指标时间序列，适合看趋势、分组和 cohort，不适合反查一批具体 workflow id。

Grafana Explore 里常用的 `VictoriaLogs` 查询示例：

```text
workflowId:97c44341-fe32-4a9d-becb-0e8cd4e5584b
service:func2-ts message:"func2 task completed" y:<10.4
service:func2-ts message:"func2 task completed" y:<10.4 | stats by (workflowId) count()
service:func2-ts message:"func2 task completed" y:>=10.5 | stats by (workflowId) count()
```

也就是说，`y < 10.4`、`y < 10.3` 这类自由数值筛选，放在 `VictoriaLogs` / Grafana Explore 里是能直接做的，不必依赖 `Conductor` 的 runtime variable tag。

Grafana dashboard 上的指标查询建议看这些维度：

```promql
sum by (exported_service, initial_x_tag, y_tag) (conductor_demo_final_outputs_total)
sum by (exported_service, initial_x_tag, y_tag) (conductor_demo_final_y_count)
```

注意这里的 `exported_service` 是实际业务服务名；`service` 标签会被 scrape target 占用，所以 dashboard 里应优先按 `exported_service` 分组。

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
