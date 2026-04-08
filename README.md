# conductor_demo

一个基于 `docker compose` 的最小 Conductor 人机协同异步工作流 DEMO：

- `Conductor + PostgreSQL` 纯 PG 存储与索引
- `func1` 使用 Python worker
- `review` 使用 Conductor `HUMAN` task，由 Node.js review service 通过 API 完成
- `func2` 使用 TypeScript worker
- `OTel metrics + Vector logs + VictoriaMetrics/VictoriaLogs + Grafana`

## 工作流

业务路径固定为：

```text
SET_VARIABLE init_state
  -> DO_WHILE review_loop
     -> SIMPLE func1_python
     -> HUMAN review_gate
     -> SET_VARIABLE update_state
  -> SWITCH last_decision
     -> APPROVED -> SIMPLE func2_ts
     -> default  -> TERMINATE
```

默认自动审批规则：

- `candidate_x > 5` 时审批通过
- 否则打回，并给 `x` 增加一个 `0.10 ~ 1.00` 的随机增量
- review service 会在 `0 ~ 5000ms` 内随机 sleep，模拟人工审核延迟

## Workflow 编排方式

推荐使用 Orkes Developer Edition 的可视化 workflow editor 编排工作流：

- 入口：`https://developer.orkescloud.com/workflowDef`
- 用途：可视化查看、编辑、调试 workflow definition
- 本地仓库仍以 [workflows/human-review-demo.json](/home/lyk/qiyin/conductor/workflows/human-review-demo.json) 作为单一真相源

这套 demo 的运行面仍然是本仓库自建的 `Nomad + Consul + Vault + Conductor OSS`。Orkes Developer Edition 只作为 workflow 编排工具使用，不作为本地 demo 的运行时依赖。

推荐工作方式：

1. 先在 `https://developer.orkescloud.com/workflowDef` 里做 workflow 编排和结构验证。
2. 把最终 definition 回写到 [workflows/human-review-demo.json](/home/lyk/qiyin/conductor/workflows/human-review-demo.json)。
3. 通过 [scripts/register-defs.sh](/home/lyk/qiyin/conductor/scripts/register-defs.sh) / [scripts/seed.sh](/home/lyk/qiyin/conductor/scripts/seed.sh) 注册到本地自建 Conductor。

不要把只存在于 Orkes 页面里的临时修改当成最终交付；没有回写到仓库 JSON 的改动，不会进入这套 demo 的实际运行环境。

## 目录

```text
.
├── config/                     # Conductor / OTel / Vector / Grafana / vmagent 配置
├── docker/                     # Python / TS / review-service / Grafana Dockerfile
├── scripts/                    # 启动、注册、单跑、批量、搜索、验证脚本
├── services/review-service/    # Node.js + TypeScript review service
├── taskdefs/                   # func1 / func2 task definitions
├── tests/e2e/                  # e2e 壳脚本
├── workers/func1-python/       # Python worker
├── workers/func2-ts/           # TypeScript worker
└── workflows/                  # workflow definition
```

## 快速开始

前置要求：

- Docker / Docker Compose
- `curl`
- `jq`

首次启动：

```bash
cp .env.example .env
./scripts/up.sh
./scripts/seed.sh
```

如果你就想一条命令跑完，也可以：

```bash
./scripts/bootstrap.sh
```

分层脚本职责：

- `scripts/up.sh`
  - 准备 `.env`
  - 启动宿主机 `Consul`
  - `docker compose up -d --build` 拉起基础设施
  - 注册基础设施到 `Consul`
  - 启动宿主机 `Nomad`
- `scripts/seed.sh`
  - 构建业务镜像
  - 初始化 `Vault` / `Consul KV`
  - 提交 `Nomad jobs`
  - 注册 task definitions 和 workflow definition

## 常用命令

基础设施启动：

```bash
./scripts/up.sh
```

控制面初始化与 job 提交：

```bash
./scripts/seed.sh
```

单条 happy path：

```bash
./scripts/run-one.sh --x 1 --auto-review --wait
```

单条手工 review：

```bash
./scripts/run-one.sh --x 1
curl "http://localhost:8090/reviews/pending?limit=10"
curl -X POST "http://localhost:8090/reviews/<taskId>/approve"
```

单条 reject 回路：

```bash
./tests/e2e/reject-loop.sh
```

批量跑：

```bash
./scripts/run-bulk.sh --count 1000 --concurrency 32
```

搜索最终结果：

```bash
./scripts/search-output.sh --threshold 10.1
```

验证整条链路：

```bash
./scripts/verify.sh
```

## Review Service API

待审批列表：

```bash
curl "${REVIEW_SERVICE_URL}/reviews/pending?limit=20"
curl "${REVIEW_SERVICE_URL}/reviews/pending?workflowId=<workflowId>&limit=20"
```

审批动作：

```bash
curl -X POST "${REVIEW_SERVICE_URL}/reviews/<taskId>/approve"
curl -X POST "${REVIEW_SERVICE_URL}/reviews/<taskId>/reject"
curl -X POST "${REVIEW_SERVICE_URL}/reviews/<taskId>/auto-review"
curl -X POST "${REVIEW_SERVICE_URL}/reviews/auto-review?limit=1000&concurrency=32"
```

返回字段统一包含：

- `workflowId`
- `taskId`
- `decision`
- `comment`
- `delay_ms`
- `next_x`
- `trace_id`
- `processed_at`

## 演示入口

- Conductor API: `http://localhost:18080/api`
- Conductor UI: `http://localhost:18080`
- Swagger UI: `http://localhost:18080/swagger-ui/index.html`
- Review service: `http://localhost:18080/review`
- Grafana: `http://localhost:13000`

Grafana 默认账号密码：

- 用户名：`admin`
- 密码：`admin`

## 搜索说明

Conductor UI 的真正控制面已经挂在 `http://localhost:18080`。如果你打开根路径只看到 `Swagger Documentation / User Guide`，说明网关没有连到独立的 `conductor-ui` Nomad job，而是误连到了 server 根页。

如果你要修改 workflow definition，优先使用 `https://developer.orkescloud.com/workflowDef` 做编排，再把结果同步回 [workflows/human-review-demo.json](/home/lyk/qiyin/conductor/workflows/human-review-demo.json)。本地 OSS UI 更适合查看和小幅 JSON 调整，不要把它当成主要编排入口。

仓库同时提供两条结果筛选路径：

1. `scripts/prove-search.sh`
   作用：尝试验证 Conductor search API 的 `freeText` 查询是否能直接命中 `output.y`
2. `scripts/search-output.sh`
   作用：固定 fallback，先按 `workflowType + status` 拉执行，再本地过滤 `output.y > threshold`

如果 UI / API 对 `output.y` 的自由文本索引表现不稳定，演示口径应切换为：

- `Conductor UI` 负责按 workflow/status/time range 收敛范围
- `CLI fallback` 负责精确结果筛选

## 测试

Python worker：

```bash
python3 -m pytest workers/func1-python/tests/test_func1_worker.py
```

TypeScript worker：

```bash
cd workers/func2-ts
npm install
npm test
```

Review service：

```bash
cd services/review-service
npm install
npm test
```

E2E：

```bash
./tests/e2e/happy-path.sh
./tests/e2e/reject-loop.sh
./tests/e2e/bulk-search.sh
./tests/e2e/observability.sh
./tests/e2e/failure-surface.sh
```
