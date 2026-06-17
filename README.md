# Vault Lab — Secrets end-to-end with Vault + External Secrets (Lab 4)

Stand up [HashiCorp Vault](https://developer.hashicorp.com/vault) in your
cluster and get a real secret into a running workload **without the value ever
touching Git, a config file, or a chat message**. The plumbing is the
[External Secrets Operator](https://external-secrets.io/) (ESO), which reads
Vault and writes a native Kubernetes Secret.

> **Block 6 — Secrets & Vault.** If a human sees the value, it's not a secret.
> The secret lives in exactly one place (Vault); every consumer fetches it at
> runtime through an authenticated, audited path.

## The mental model — two control planes, kept distinct

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

## What's in this repo — and why

| Path | What it is / why it exists |
|------|----------------------------|
| `vault/vault-values.yaml` | Helm values for a **dev/learning** Vault — one standalone instance, UI on, ESO injector off. The commented block at the bottom shows the production shape (HA + Raft + auto-unseal). |
| `vault/vault-ui-ingress.yaml` | *Optional.* Exposes the Vault UI via Traefik at `ecXY-vault.ff26.it` so you don't have to port-forward. |
| `policies/app-read-db.hcl` | The Vault **policy**: read-only, **one** secret path, no wildcards — least privilege. This is *who may read what*. |
| `k8s/app-serviceaccount.yaml` | The **identity** the workload runs as (`app-sa`). Vault's role is bound to this SA, so only pods running as it can authenticate. |
| `k8s/secret-store.yaml` | ESO `SecretStore`: **how** to reach Vault and **how** to authenticate (using the Kubernetes-auth role). Contains no secret value — pure wiring. |
| `k8s/external-secret.yaml` | ESO `ExternalSecret`: **which** value to fetch and **what** K8s Secret to create from it (`db-credentials`). |
| `k8s/deployment.yaml` | A trivial demo workload that consumes the secret as an env var and logs it — proof the value arrives without ever appearing in a manifest. |
| `scripts/configure-vault.sh` | One-shot helper: enables the KV engine, writes the secret, enables Kubernetes auth, loads the policy and the role. Runs `vault` inside the pod. |

## Your environment (already provided)

- A **personal cluster** — you have a kubeconfig. Point `kubectl` at it:
  `export KUBECONFIG=/path/to/your-kubeconfig` and confirm `kubectl get ns`.
- **Traefik** is the ingress controller; **external-dns** + a Cloudflare tunnel
  publish any Ingress carrying the shared
  `external-dns.alpha.kubernetes.io/target` annotation (used by the optional
  UI ingress).
- Argo CD is installed too (see "How this fits GitOps" at the end).

## Prerequisites on your laptop

- [`kubectl`](https://kubernetes.io/docs/tasks/tools/),
  [Helm 3](https://helm.sh/docs/intro/install/), and `jq`.
- A password manager (or any safe place) to hold the Vault unseal keys + root
  token. **Never** put them in Git — the `.gitignore` here blocks the obvious
  filenames, but the discipline is on you.
- You do **not** need the `vault` CLI locally; we run it inside the Vault pod.

## Step 0 — Get it on GitHub (optional but recommended)

```bash
git init
git add .
git commit -m "Vault lab: Vault values, policy, ESO manifests, demo workload"
git branch -M main
git remote add origin git@github.com:<you>/workshop-vault.git
git push -u origin main
```

Everything in this repo is wiring and configuration — there are no secret
*values* anywhere, which is exactly the point.

---

# The lab

## Step 1 — Install Vault via Helm; init & unseal

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault

# dev/learning single instance (see vault/vault-values.yaml)
helm install vault hashicorp/vault -n vault -f vault/vault-values.yaml

kubectl -n vault get pods   # vault-0 will be Running but NOT ready until unsealed
```

Initialize Vault. **This prints the unseal keys and root token exactly once** —
capture them safely:

```bash
kubectl exec -n vault vault-0 -- \
  vault operator init -key-shares=5 -key-threshold=3 -format=json \
  > cluster-keys.json    # gitignored; move these into your password manager

# Unseal with any 3 of the 5 keys:
for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" cluster-keys.json)
  kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
done

kubectl -n vault get pods   # vault-0 should now be 1/1 Ready
```

Reach the UI either by port-forward:

```bash
kubectl -n vault port-forward svc/vault 8200:8200   # http://localhost:8200
```

…or apply the optional Traefik ingress (edit `XY` first):

```bash
kubectl apply -f vault/vault-ui-ingress.yaml         # https://ecXY-vault.ff26.it
```

> In production you'd replace manual unseal with **auto-unseal** (KMS/HSM) so a
> pod restart needs no human. See the commented block in `vault/vault-values.yaml`.

## Step 2 — Enable the KV engine; write one secret

Log in inside the pod with the root token (lab only — never use root in prod),
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

From here on, **nothing else contains the literal value** — not the app, not
Git, not a config file. The secret exists in exactly one place: Vault.

## Step 3 — Enable Kubernetes auth; read-only policy + role bound to app-sa

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

> The script execs into `vault-0` and logs in with the root token you pass via
> `VAULT_TOKEN`. If you'd rather do it by hand, read the script — each command
> mirrors a slide.

What that sets up:

- `vault auth enable kubernetes` and points Vault at the in-cluster token reviewer.
- `vault policy write app-read-db` — read-only, **one path**, no wildcards.
- `vault write auth/kubernetes/role/app` bound to `app-sa` in `demo`, `ttl=1h`.

The trust handshake: a pod presents its SA token → Vault asks Kubernetes "is it
real?" → SA + namespace match the role → Vault issues a short-lived,
policy-scoped token. No static Vault credential ever lives in the cluster.

## Step 4 — Install ESO; create a SecretStore and an ExternalSecret

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

## Step 5 — Deploy a service that reads it; confirm it's in no manifest

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
# no matches — the value lives only in Vault
```

The manifests reference the Secret by *name*; the value was injected at runtime
through the Vault → ESO → Secret chain.

## Step 6 — Stretch: rotate in Vault, watch the K8s Secret update

Change the value in Vault — and only in Vault:

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
> reloader (e.g. stakater/Reloader) — that's the "no redeploy" story from the
> slides. For the lab, `kubectl rollout restart deploy/secret-consumer -n demo`
> demonstrates the pod picking up the rotated value.

---

## Project layout

```
workshop-vault/
├─ vault/
│  ├─ vault-values.yaml          # dev Vault Helm values (+ commented HA shape)
│  └─ vault-ui-ingress.yaml      # optional: UI via Traefik at ecXY-vault.ff26.it
├─ policies/
│  └─ app-read-db.hcl            # read-only, one path, no wildcards
├─ k8s/
│  ├─ app-serviceaccount.yaml    # app-sa — the workload identity
│  ├─ secret-store.yaml          # ESO → Vault (how to reach/authenticate)
│  ├─ external-secret.yaml       # which value to fetch → db-credentials Secret
│  └─ deployment.yaml            # demo app reading DB_PASSWORD (value not here)
└─ scripts/
   └─ configure-vault.sh         # KV engine, secret, k8s auth, policy, role
```

## How this fits GitOps

Every object in `k8s/` is plain YAML that Argo CD can reconcile (Lab 3) — the
SecretStore, ExternalSecret, Deployment, and ServiceAccount are all just
manifests. Git describes *which* secrets a workload needs and *where* to fetch
them — never the secrets themselves. A reviewer can approve a deploy that uses a
new secret without ever seeing the secret. To wire this into your Lab 3 config
repo, drop these manifests under `deploy/chart/templates/` (or a sibling app)
and let Argo CD sync them.

## Notes for instructors

- **Root token / unseal keys:** for the lab we use the root token for
  configuration. Stress that this is a learning shortcut — production uses
  scoped tokens, auto-unseal, and the keys split across people.
- **`refreshInterval: 1m`** is deliberately short so Step 6 is observable in
  class. Real deployments use minutes-to-hours.
- **Before you trust this in production** (Block 6 checklist): auto-unseal,
  encrypt K8s Secrets at rest (KMS provider), `vault audit enable`, narrow
  policies (already done here), short TTLs, and `gitleaks` over history to
  rotate anything ever committed.
- **Dynamic secrets** (Vault's database engine issuing short-lived per-instance
  DB credentials) are the real prize — mention them as the next step beyond
  static KV + ESO.
- If Vault can't schedule because of PVC provisioning on the cluster, set
  `server.dataStorage.enabled=false` in `vault-values.yaml` for an in-memory
  dev Vault (data is lost on restart — fine for the lab).
