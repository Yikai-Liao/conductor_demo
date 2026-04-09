# 同事测试上手文档

这份文档面向“只需要在平台上做功能测试”的同事。

你不需要了解 `Nomad`、`Consul`、`Vault`，也不需要 SSH 到机器。

## 访问地址

- Conductor 平台: `http://10.0.0.202:18080`
- Swagger: `http://10.0.0.202:18080/swagger-ui/index.html`
- Grafana: `http://10.0.0.202:13000`

说明：

- 当前只对局域网暴露了 `Conductor/Gateway` 和 `Grafana`
- `Nomad`、`Consul`、`Vault` 没有对外开放

## 测试账号和凭据

- Grafana 用户名: `admin`
- Grafana 密码: `admin`
- Review API Token: `review-demo-token`

## 最短测试路径

如果你只想确认平台能正常工作，按下面 4 步走：

1. 打开 `http://10.0.0.202:18080/executions`
2. 再打开 `http://10.0.0.202:18080/swagger-ui/index.html`
3. 用 Swagger 发起一个 `human_review_demo`
4. 回到 `executions` 页面观察执行结果

## 用 Swagger 发起一个 workflow

Swagger 地址：

- `http://10.0.0.202:18080/swagger-ui/index.html`

建议直接调用创建 workflow 的接口，body 用下面这份最小 payload：

```json
{
  "name": "human_review_demo",
  "version": 1,
  "correlationId": "teammate-demo-001",
  "input": {
    "x": 1,
    "correlation_id": "teammate-demo-001",
    "initial_x_tag": "initial_x_1",
    "auto_review": false,
    "review_mode": "manual",
    "bulk_seed": "",
    "approval_threshold": 5
  }
}
```

预期现象：

- workflow 会先跑到人工审批节点
- 在 `executions` 页面里可以看到 execution 进入运行中

## 手工审批测试

### 1. 先查待审批任务

```bash
curl -s \
  -H "Authorization: Bearer review-demo-token" \
  "http://10.0.0.202:18080/review/reviews/pending?limit=20"
```

如果你只想看某个 workflow：

```bash
curl -s \
  -H "Authorization: Bearer review-demo-token" \
  "http://10.0.0.202:18080/review/reviews/pending?workflowId=<workflowId>&limit=20"
```

返回里重点看：

- `workflowId`
- `taskId`
- `candidate_x`
- `attempt`

### 2. 审批通过

```bash
curl -s \
  -X POST \
  -H "Authorization: Bearer review-demo-token" \
  "http://10.0.0.202:18080/review/reviews/<taskId>/approve"
```

### 3. 或者打回

```bash
curl -s \
  -X POST \
  -H "Authorization: Bearer review-demo-token" \
  "http://10.0.0.202:18080/review/reviews/<taskId>/reject"
```

### 4. 再回到执行详情确认结果

执行完成后，在 `executions` 里点开详情，重点看：

- `decision`
- `comment`
- `final_x`
- `y`
- `trace_id`

## 自动审批测试

如果你不想手工点，可以直接用 auto-review：

```bash
curl -s \
  -X POST \
  -H "Authorization: Bearer review-demo-token" \
  "http://10.0.0.202:18080/review/reviews/auto-review?limit=1000&concurrency=32"
```

或者在创建 workflow 时直接把 `auto_review` 设成 `true`。

## 推荐观察页面

### Conductor

- `http://10.0.0.202:18080/executions`
- `http://10.0.0.202:18080/swagger-ui/index.html`

推荐筛选条件：

- `workflowType = human_review_demo`
- 按时间范围看最近执行

### Grafana

- `http://10.0.0.202:13000`

建议重点观察：

- review-service 日志
- worker 指标
- workflow 相关日志链路
- `workflowId` / `taskId` / `trace_id`

## 常见现象

### 页面刚打开偶发 502

这是网关刷新上游时的短暂窗口，刷新一次即可。

### 能打开 UI，但看不到待审批

先确认刚创建的 workflow 还在运行中，再用带 `workflowId` 的 pending 查询缩小范围。

### Grafana 能登录但图表暂时没数据

新执行一两条 workflow，等几秒再刷新。

## 不在测试范围内的东西

这套给同事开放的入口不包含：

- `Nomad UI`
- `Consul UI`
- `Vault API`
- 宿主机 shell

如果你需要看这些控制面，联系维护人，不要自己猜地址。
