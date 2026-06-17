#!/usr/bin/env bash
# Configures an already-installed, unsealed Vault for the lab:
#   - enables the KV v2 engine at "secret"
#   - writes the demo secret at secret/dev/db
#   - enables Kubernetes auth
#   - loads the read-only policy and a role bound to app-sa in namespace "demo"
#
# Runs the vault CLI INSIDE the vault-0 pod, so you don't need vault installed
# locally. Assumes the Vault Helm release is in namespace "vault".
#
# Usage:
#   ROOT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
#   VAULT_TOKEN="$ROOT_TOKEN" ./scripts/configure-vault.sh
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"
POD="${POD:-vault-0}"
APP_NS="${APP_NS:-demo}"

: "${VAULT_TOKEN:?Set VAULT_TOKEN (e.g. the root token) before running}"

# Run a vault command inside the pod, authenticated with VAULT_TOKEN.
kx() { kubectl exec -n "${VAULT_NS}" "${POD}" -- sh -c "export VAULT_TOKEN='${VAULT_TOKEN}'; $1"; }

echo "==> 1. Enable the KV v2 engine at path 'secret' (ignore error if already enabled)"
kx "vault secrets enable -path=secret kv-v2" || true

echo "==> 2. Write the demo secret (the ONLY place the real value is ever typed)"
kx "vault kv put secret/dev/db DB_PASSWORD='S3cr3t-from-vault'"

echo "==> 3. Enable Kubernetes auth (ignore error if already enabled)"
kx "vault auth enable kubernetes" || true

echo "==> 4. Point Vault at the in-cluster token reviewer"
kx 'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

echo "==> 5. Load the read-only policy"
kubectl exec -i -n "${VAULT_NS}" "${POD}" -- sh -c \
  "export VAULT_TOKEN='${VAULT_TOKEN}'; cat > /tmp/app-read-db.hcl && vault policy write app-read-db /tmp/app-read-db.hcl" \
  < "$(dirname "$0")/../policies/app-read-db.hcl"

echo "==> 6. Bind a role to the app-sa service account in the '${APP_NS}' namespace"
kx "vault write auth/kubernetes/role/app \
      bound_service_account_names=app-sa \
      bound_service_account_namespaces=${APP_NS} \
      policy=app-read-db \
      ttl=1h"

echo "==> Done. Vault is configured: secret/dev/db is readable by app-sa in '${APP_NS}'."
