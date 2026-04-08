job "review-service" {
  datacenters = ["dc1"]
  type        = "service"

  group "service" {
    count = 1

    restart {
      attempts = 3
      interval = "5m"
      delay    = "10s"
      mode     = "delay"
    }

    task "review" {
      driver = "docker"

      service {
        name         = "review-service"
        provider     = "consul"
        port         = 8090
        address_mode = "driver"
        tags         = ["metrics"]

        check {
          type         = "http"
          path         = "/healthz"
          port         = 8090
          address_mode = "driver"
          interval     = "10s"
          timeout      = "2s"
        }
      }

      vault {
        role         = "nomad-workloads"
        env          = false
        disable_file = true
      }

      template {
        destination = "${NOMAD_SECRETS_DIR}/env"
        env         = true
        change_mode = "restart"
        data = <<EOF
CONDUCTOR_SERVER_URL=http://{{ range service "conductor-api" }}{{ .Address }}:{{ .Port }}{{ end }}/api
OTEL_EXPORTER_OTLP_ENDPOINT=http://{{ range service "otel-collector-otlp-http" }}{{ .Address }}:{{ .Port }}{{ end }}/v1/metrics
OTEL_SERVICE_NAME=review-service
REVIEW_API_TOKEN={{ with secret "secret/data/default/review-service/config" }}{{ .Data.data.api_token }}{{ end }}
REVIEW_APPROVAL_THRESHOLD={{ key "config/conductor-demo/review/approval_threshold" }}
REVIEW_MAX_DELAY_MS={{ key "config/conductor-demo/review/max_delay_ms" }}
REVIEW_REJECT_INCREMENT_MIN={{ key "config/conductor-demo/review/reject_increment_min" }}
REVIEW_REJECT_INCREMENT_MAX={{ key "config/conductor-demo/review/reject_increment_max" }}
REVIEW_SERVICE_PORT=8090
EOF
      }

      config {
        image        = "@@REVIEW_SERVICE_IMAGE@@"
        network_mode = "@@DOCKER_NETWORK@@"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
