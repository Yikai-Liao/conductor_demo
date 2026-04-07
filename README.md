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
./scripts/bootstrap.sh
```

脚本会自动：

- 准备 `.env`
- 下载 Grafana 的 VictoriaLogs 插件包
- `docker compose up -d --build`
- 等待 Conductor / workers / review service / Victoria / Grafana 就绪
- 注册 task definitions 和 workflow definition

## 常用命令

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
- Conductor UI: `http://localhost:18127`
- Review service: `http://localhost:18090`
- Grafana: `http://localhost:13000`
- VictoriaMetrics: `http://localhost:18428`
- VictoriaLogs: `http://localhost:19428`

Grafana 默认账号密码：

- 用户名：`admin`
- 密码：`admin`

## 搜索说明

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
