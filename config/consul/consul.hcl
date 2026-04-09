datacenter     = "dc1"
data_dir       = "@@ROOT_DIR@@/runtime/host-consul"
bind_addr      = "127.0.0.1"
client_addr    = "127.0.0.1"
advertise_addr = "127.0.0.1"
server         = true
bootstrap_expect = 1
log_level      = "INFO"

ui_config {
  enabled = true
}
