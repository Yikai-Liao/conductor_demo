path "secret/data/conductor-demo/*" {
  capabilities = ["read"]
}

path "secret/metadata/conductor-demo/*" {
  capabilities = ["list", "read"]
}
