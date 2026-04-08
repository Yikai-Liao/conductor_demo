job "conductor-ui" {
  datacenters = ["dc1"]
  type        = "service"

  group "ui" {
    count = 1

    restart {
      attempts = 3
      interval = "5m"
      delay    = "10s"
      mode     = "delay"
    }

    task "conductor-ui" {
      driver = "docker"

      service {
        name         = "conductor-ui"
        provider     = "consul"
        port         = 5000
        address_mode = "driver"

        check {
          type         = "http"
          path         = "/"
          port         = 5000
          address_mode = "driver"
          interval     = "10s"
          timeout      = "2s"
        }
      }

      config {
        image        = "@@CONDUCTOR_UI_IMAGE@@"
        network_mode = "@@DOCKER_NETWORK@@"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
