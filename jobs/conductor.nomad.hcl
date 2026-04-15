job "conductor" {
  datacenters = ["dc1"]
  type        = "service"

  group "server" {
    count = 1

    restart {
      attempts = 3
      interval = "5m"
      delay    = "10s"
      mode     = "delay"
    }

    task "conductor" {
      driver = "docker"

      service {
        name         = "conductor-api"
        provider     = "consul"
        port         = 8080
        address_mode = "driver"
        tags         = ["metrics"]

        check {
          type         = "http"
          path         = "/actuator/health"
          port         = 8080
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
        destination = "${NOMAD_TASK_DIR}/config-postgres.properties"
        change_mode = "restart"
        data = <<EOF
conductor.db.type=postgres
spring.datasource.url=jdbc:postgresql://{{ range service "postgres" }}{{ .Address }}:{{ .Port }}{{ end }}/@@POSTGRES_DB@@
spring.datasource.username={{ with secret "secret/data/default/conductor/config" }}{{ .Data.data.username }}{{ end }}
spring.datasource.password={{ with secret "secret/data/default/conductor/config" }}{{ .Data.data.password }}{{ end }}
conductor.postgres.schema=public

conductor.queue.type=postgres
conductor.indexing.enabled=true
conductor.indexing.type=opensearch2
conductor.opensearch.version=2
conductor.opensearch.url=http://{{ range service "opensearch" }}{{ .Address }}:{{ .Port }}{{ end }}
conductor.opensearch.indexPrefix=conductor
conductor.opensearch.indexShardCount=1
conductor.opensearch.indexReplicasCount=0
conductor.opensearch.clusterHealthColor=yellow
conductor.opensearch.autoIndexManagementEnabled=true

conductor.app.workflowExecutionLockEnabled=true
conductor.workflow-execution-lock.type=postgres

conductor.postgres.pollDataFlushInterval=5000
conductor.postgres.pollDataCacheValidityPeriod=5000
conductor.postgres.onlyIndexOnStatusChange=true
conductor.postgres.experimentalQueueNotify=true
conductor.postgres.experimentalQueueNotifyStalePeriod=5000

conductor.app.taskIndexingEnabled=true
conductor.app.activeWorkerLastPollTimeout=10000

management.endpoints.web.exposure.include=health,info,prometheus
management.endpoint.health.show-details=always
management.health.elasticsearch.enabled=false
management.prometheus.metrics.export.enabled=true
EOF
      }

      env {
        CONFIG_PROP = "config-postgres.properties"
        JAVA_OPTS   = "-Xms512m -Xmx2048m"
      }

      config {
        image        = "@@CONDUCTOR_IMAGE@@"
        force_pull   = false
        network_mode = "@@DOCKER_NETWORK@@"
        volumes = [
          "local/config-postgres.properties:/app/config/config-postgres.properties"
        ]
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
