# Read-only access to exactly one secret path. One role per app, one path,
# no wildcards — the least-privilege shape from the Block 6 checklist.
#
# Note the "/data/" segment: with the KV v2 engine mounted at "secret", the
# secret written to "secret/dev/db" is actually read at "secret/data/dev/db".
path "secret/data/dev/db" {
  capabilities = ["read"]
}
