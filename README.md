# Vault Lab: Secrets end-to-end with Vault + External Secrets (Lab 4)

Stand up [HashiCorp Vault](https://developer.hashicorp.com/vault) in your
cluster and get a real secret into a running workload **without the value ever
touching Git, a config file, or a chat message**. The plumbing is the
[External Secrets Operator](https://external-secrets.io/) (ESO), which reads
Vault and writes a native Kubernetes Secret.

## What you'll do in this lab

A quick map before the details:

1. **Install Vault** in your cluster, then initialize and unseal it, to hold
   your secrets.
2. **Add a secret** to Vault: the one and only place the real value is ever
   typed.
3. **Wire up Kubernetes auth** so only the right workload can read it, with a
   least-privilege policy and a role bound to a specific service account.
4. **Install the External Secrets Operator** and point it at Vault, so it
   resolves the secret into a native Kubernetes Secret.
5. **Deploy a workload** that consumes the secret, and confirm the value lives
   nowhere in your manifests or in Git.
6. **(Stretch) Rotate** the secret in Vault and watch the Kubernetes Secret
   update on its own.

> **Secrets & Vault.** If a human sees the value, it's not a secret. The secret
> lives in exactly one place (Vault); every consumer fetches it at runtime
> through an authenticated, audited path.

## The mental model: two control planes, kept distinct

```
   Vault            K8s auth           External Secrets        Workload
 ───────►  ───────────────────►  ────────────────────►  ─────────────────►
 stores the      Vault trusts the     reads Vault, writes      mounts the
 real value      cluster's SA tokens  a native K8s Secret      Secret as env var
```

- **Vault** answers *"what is the value, and who may read it?"*
- **ESO** answers *"get that value into the cluster as a Secret."*

Rotation happens in Vault; ESO re-syncs on an interval. No redeploy, no human
touching values.

## What's in this repo, and why

| Path | What it is / why it exists |
|------|----------------------------|
| `vault/vault-values.yaml` | Helm values for a **dev** Vault: one standalone instance, UI on, ESO injector off. The commented block at the bottom shows the production shape (HA + Raft + auto-unseal). |
| `vault/vault-ui-ingress.yaml` | *Optional.* Exposes the Vault UI via Traefik at `ec-0X-vault.ff26.it` so you don't have to port-forward. |
| `policies/app-read-db.hcl` | The Vault **policy**: read-only, **one** secret path, no wildcards, the least-privilege shape. This is *who may read what*. |
| `k8s/app-serviceaccount.yaml` | The **identity** the workload runs as (`app-sa`). Vault's role is bound to this SA, so only pods running as it can authenticate. |
| `k8s/secret-store.yaml` | ESO `SecretStore`: **how** to reach Vault and **how** to authenticate (using the Kubernetes-auth role). Contains no secret value, just pure wiring. |
| `k8s/external-secret.yaml` | ESO `ExternalSecret`: **which** value to fetch and **what** K8s Secret to create from it (`db-credentials`). |
| `k8s/deployment.yaml` | A trivial demo workload that consumes the secret as an env var and logs it, proving the value arrives without ever appearing in a manifest. |
| `scripts/configure-vault.sh` | One-shot helper: enables the KV engine, writes the secret, enables Kubernetes auth, loads the policy and the role. Runs `vault` inside the pod. |

## Your environment (already provided)

- A **personal cluster**: you have a kubeconfig. Point `kubectl` at it with
  `export KUBECONFIG=/path/to/your-kubeconfig` and confirm `kubectl get ns`.
- **Traefik** is the ingress controller; **external-dns** + a Cloudflare tunnel
  publish any Ingress carrying the shared
  `external-dns.alpha.kubernetes.io/target` annotation (used by the optional
  UI ingress).
- Argo CD is installed too (see "How this fits GitOps" at the end).

## Prerequisites on your laptop

- [`kubectl`](https://kubernetes.io/docs/tasks/tools/),
  [Helm 3](https://helm.sh/docs/intro/install/), and `jq`.
- You do **not** need the `vault` CLI locally; we run it inside the Vault pod.

## Step 0: Get it on GitHub (optional but recommended)

```bash
git init
git add .
git commit -m "Vault lab: Vault values, policy, ESO manifests, demo workload"
git branch -M main
git remote add origin git@github.com:<you>/workshop-vault.git
git push -u origin main
```

Everything in this repo is wiring and configuration; there are no secret
*values* anywhere, which is exactly the point.

---

# The lab

## Step 1: Install Vault via Helm; init and unseal

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault

# dev single instance (see vault/vault-values.yaml)
helm install vault hashicorp/vault -n vault -f vault/vault-values.yaml

kubectl -n vault get pods   # vault-0 will be Running but NOT ready until unsealed
```

> If `vault-0` stays **Pending** because the cluster can't provision a
> PersistentVolume, set `server.dataStorage.enabled=false` in
> `vault/vault-values.yaml` and reinstall for an in-memory dev Vault. Its data is
> lost on restart, which is fine for this lab.

Initialize Vault. **This prints the unseal keys and root token exactly once**,
so capture them somewhere safe:

```bash
kubectl exec -n vault vault-0 -- \
  vault operator init -key-shares=5 -key-threshold=3 -format=json \
  > cluster-keys.json    # gitignored; keep it out of version control

# Unseal with any 3 of the 5 keys:
for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" cluster-keys.json)
  kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
done

kubectl -n vault get pods   # vault-0 should now be 1/1 Ready
```

> Ideally the unseal keys and root token would live in a password manager (or
> another safe place). For this lab you'll just keep `cluster-keys.json`
> unversioned in your repo. It's gitignored, but the discipline is on you: never
> commit it.

Reach the UI either by port-forward:

```bash
kubectl -n vault port-forward svc/vault 8200:8200   # http://localhost:8200
```

…or apply the optional Traefik ingress (edit `0X` first):

```bash
kubectl apply -f vault/vault-ui-ingress.yaml         # https://ec-0X-vault.ff26.it
```

> In production you'd replace manual unseal with **auto-unseal** (KMS/HSM) so a
> pod restart needs no human. See the commented block in `vault/vault-values.yaml`.

## Step 2: Enable the KV engine; write one secret

Log in inside the pod with the root token (lab only; never use root in prod),
then enable KV v2 and write the secret:

```bash
ROOT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='$ROOT_TOKEN'
  vault secrets enable -path=secret kv-v2
  vault kv put secret/dev/db DB_PASSWORD='S3cr3t-from-vault'
  vault kv get secret/dev/db
"
```

From here on, **nothing else contains the literal value**: not the app, not
Git, not a config file. The secret exists in exactly one place: Vault.

## Step 3: Enable Kubernetes auth; read-only policy and role bound to app-sa

First create the namespace and service account the workload will run as:

```bash
kubectl create namespace demo
kubectl apply -f k8s/app-serviceaccount.yaml
```

Now configure Vault to trust this cluster's service-account tokens, load the
least-privilege policy (`policies/app-read-db.hcl`), and bind a role to
`app-sa`. The helper script does all of it inside the pod:

```bash
export ROOT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
VAULT_TOKEN="$ROOT_TOKEN" ./scripts/configure-vault.sh
```

It execs into `vault-0` and logs in with the root token you pass via
`VAULT_TOKEN`. What it sets up:

- `vault auth enable kubernetes` and points Vault at the in-cluster token reviewer.
- `vault policy write app-read-db`: read-only, **one path**, no wildcards.
- `vault write auth/kubernetes/role/app` bound to `app-sa` in `demo`, `ttl=1h`.

### Prefer to run it by hand?

If you'd rather not run the script, here are the same commands. They continue
from Step 2 (the KV engine and the secret are already in place). Open a shell in
the Vault pod and run them there: working *inside* the pod keeps the commands
free of any laptop-side quoting.

```bash
# On your laptop: read the root token (copy it), then open a shell in the pod.
jq -r '.root_token' cluster-keys.json
kubectl exec -it -n vault vault-0 -- sh
```

```sh
# --- inside the vault-0 pod ---
export VAULT_TOKEN=<paste the root token>

# Enable Kubernetes auth (ignore the error if it's already enabled):
vault auth enable kubernetes

# Point Vault at the in-cluster token reviewer:
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"

# Load the read-only policy (one path, no wildcards):
vault policy write app-read-db - <<'EOF'
path "secret/data/dev/db" {
  capabilities = ["read"]
}
EOF

# Bind a role to the app-sa service account in the demo namespace:
vault write auth/kubernetes/role/app \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces=demo \
  policy=app-read-db \
  ttl=1h

exit
```

The trust handshake: a pod presents its SA token → Vault asks Kubernetes "is it
real?" → SA + namespace match the role → Vault issues a short-lived,
policy-scoped token. No static Vault credential ever lives in the cluster.

## Step 4: Install ESO; create a SecretStore and an ExternalSecret

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
kubectl -n external-secrets rollout status deployment/external-secrets --timeout=120s
```

Apply the wiring. The `SecretStore` says *how to reach Vault*; the
`ExternalSecret` says *which value to fetch and what K8s Secret to create*:

```bash
kubectl apply -f k8s/secret-store.yaml
kubectl apply -f k8s/external-secret.yaml

# ESO should report the ExternalSecret as SecretSynced:
kubectl get externalsecret -n demo
kubectl get secret db-credentials -n demo   # created by ESO, not by you
```

## Step 5: Deploy a service that reads it; confirm it's in no manifest

```bash
kubectl apply -f k8s/deployment.yaml
kubectl -n demo rollout status deployment/secret-consumer
```

The app reads `DB_PASSWORD` from its environment and logs it every 30s:

```bash
kubectl logs -n demo deploy/secret-consumer --tail=5
# DB_PASSWORD=S3cr3t-from-vault
```

Now prove the value is **nowhere in your config**:

```bash
grep -r "S3cr3t-from-vault" k8s/ vault/ policies/ ; echo "exit: $?"
# no matches; the value lives only in Vault
```

The manifests reference the Secret by *name*; the value was injected at runtime
through the Vault → ESO → Secret chain.

## Step 6 (stretch): rotate in Vault, watch the K8s Secret update

Change the value in Vault, and only in Vault:

```bash
ROOT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='$ROOT_TOKEN'
  vault kv put secret/dev/db DB_PASSWORD='rotated-please-change-me'
"
```

ESO re-syncs within the `refreshInterval` (set to `1m` in
`k8s/external-secret.yaml`). Watch the K8s Secret pick up the new value:

```bash
watch -n 5 'kubectl get secret db-credentials -n demo \
  -o jsonpath="{.data.DB_PASSWORD}" | base64 -d; echo'
```

> The running pod's env var only changes on restart (env vars are injected at
> start). To see the new value in the app log without a redeploy, you'd add a
> reloader (e.g. stakater/Reloader); that's the "no redeploy" story. For now,
> `kubectl rollout restart deploy/secret-consumer -n demo` makes the pod pick up
> the rotated value.

---

## Project layout

```
workshop-vault/
├─ vault/
│  ├─ vault-values.yaml          # dev Vault Helm values (+ commented HA shape)
│  └─ vault-ui-ingress.yaml      # optional: UI via Traefik at ec-0X-vault.ff26.it
├─ policies/
│  └─ app-read-db.hcl            # read-only, one path, no wildcards
├─ k8s/
│  ├─ app-serviceaccount.yaml    # app-sa, the workload identity
│  ├─ secret-store.yaml          # ESO → Vault (how to reach/authenticate)
│  ├─ external-secret.yaml       # which value to fetch → db-credentials Secret
│  └─ deployment.yaml            # demo app reading DB_PASSWORD (value not here)
└─ scripts/
   └─ configure-vault.sh         # KV engine, secret, k8s auth, policy, role
```

## How this fits GitOps

Every object in `k8s/` is plain YAML that Argo CD can reconcile (Lab 3): the
SecretStore, ExternalSecret, Deployment, and ServiceAccount are all just
manifests. Git describes *which* secrets a workload needs and *where* to fetch
them, never the secrets themselves. A reviewer can approve a deploy that uses a
new secret without ever seeing the secret. To wire this into your Lab 3 config
repo, drop these manifests under `deploy/chart/templates/` (or a sibling app)
and let Argo CD sync them.
