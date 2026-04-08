datacenter = "dc1"
data_dir   = "@@ROOT_DIR@@/runtime/host-nomad"
bind_addr  = "0.0.0.0"
log_level  = "INFO"

advertise {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

ui {
  enabled = true
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled    = true
  node_class = "linux"

  options = {
    "docker.cleanup.image" = "false"
  }
}

consul {
  address = "127.0.0.1:8500"
}

vault {
  enabled          = true
  address          = "http://127.0.0.1:18200"
  token            = "root"
  create_from_role = "nomad-cluster"

  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}

plugin "docker" {
  config {
    allow_privileged = true
  }
}
