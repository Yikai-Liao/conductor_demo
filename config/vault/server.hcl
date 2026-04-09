disable_mlock = true
ui            = true

storage "file" {
  path = "/vault/file/data"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

