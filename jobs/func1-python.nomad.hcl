job "func1-python" {
  datacenters = ["dc1"]
  type        = "service"

  group "worker" {
    count = 1

    restart {
      attempts = 3
      interval = "5m"
      delay    = "10s"
      mode     = "delay"
    }

    task "worker" {
      driver = "docker"

      service {
        name         = "func1-python"
        provider     = "consul"
        port         = 8091
        address_mode = "driver"
        tags         = ["metrics"]

        check {
          type         = "http"
          path         = "/healthz"
          port         = 8091
          address_mode = "driver"
          interval     = "10s"
          timeout      = "2s"
        }
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/env"
        env         = true
        change_mode = "restart"
        data = <<EOF
CONDUCTOR_SERVER_URL=http://{{ range service "conductor-api" }}{{ .Address }}:{{ .Port }}{{ end }}/api
OTEL_EXPORTER_OTLP_ENDPOINT=http://{{ range service "otel-collector-otlp-http" }}{{ .Address }}:{{ .Port }}{{ end }}/v1/metrics
OTEL_SERVICE_NAME=func1-python
WORKER_CONCURRENCY={{ key "config/conductor-demo/func1/worker_concurrency" }}
WORKER_IDLE_SLEEP_SECONDS={{ key "config/conductor-demo/func1/idle_sleep_seconds" }}
WORKER_ID=func1-python
WORKER_PORT=8091
EOF
      }

      config {
        image        = "@@FUNC1_IMAGE@@"
        network_mode = "@@DOCKER_NETWORK@@"
      }

      resources {
        cpu    = 300
        memory = 256
      }
    }
  }
}
