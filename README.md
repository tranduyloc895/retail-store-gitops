# Retail Store GitOps

Kubernetes manifests & ArgoCD Application definitions for the **DevSecOps E-commerce** project (NT114 — UIT).

This repo is the **source of truth** for the desired state of every workload running on the EKS cluster `ecommerce-cluster`. ArgoCD watches this repo and automatically syncs changes to the cluster on every new commit.

> **GitOps principle:** if it is not in Git, it is not running on the cluster. Every change must go through a commit.

---

## Table of Contents

- [What GitOps Is and Why We Use It](#what-gitops-is-and-why-we-use-it)
- [Deployment Flow Architecture](#deployment-flow-architecture)
- [Directory Structure](#directory-structure)
- [Databases (Persistent Datastores)](#databases-persistent-datastores)
- [Node Autoscaling (Cluster Autoscaler)](#node-autoscaling-cluster-autoscaler)
- [Pod Autoscaling (HPA)](#pod-autoscaling-hpa)
- [Alerting (Alertmanager → Telegram)](#alerting-alertmanager--telegram)
- [How the ArgoCD Application Works](#how-the-argocd-application-works)
- [CI/CD Flow with Jenkins](#cicd-flow-with-jenkins)
- [Usage Guide](#usage-guide)
- [Adding a New Service](#adding-a-new-service)
- [Cleanup After Each Lab](#cleanup-after-each-lab)
- [Related repos](#related-repos)

---

## What GitOps Is and Why We Use It

**GitOps** = operating infrastructure/applications with Git as the single source of truth. Instead of a developer/CI running `kubectl apply` directly against the cluster (push-based), a controller (ArgoCD) **pulls** manifests from Git and applies them to the cluster.

### Push vs Pull

| Aspect | Push (kubectl apply from CI) | Pull (GitOps / ArgoCD) |
|--------|------------------------------|-------------------------|
| Cluster permissions | CI needs admin credentials | Only the in-cluster controller needs them |
| Drift detection | None | Auto-detected + self-heal |
| Rollback | Re-run the pipeline | `git revert` + auto-sync |
| Audit trail | Pipeline logs | Git history |
| Multi-cluster | Configure many credentials | One repo, many clusters pull |

### Concrete benefits for this project

1. **Smaller attack surface:** the Jenkins Agent no longer needs the `AmazonEKSClusterAdminPolicy` — it only needs push access to this Git repo.
2. **Clear deployment history:** every cluster change has a corresponding commit (who, what, when).
3. **Self-healing:** if someone runs `kubectl edit` on the cluster, ArgoCD detects the drift and restores the state from Git.
4. **Rollback via `git revert`:** no image rebuild, no pipeline re-run.

---

## Deployment Flow Architecture

```
Developer          Jenkins            ECR             Git (this repo)      ArgoCD             EKS
   │                 │                 │                    │                │                 │
   │ push code       │                 │                    │                │                 │
   ├────────────────►│                 │                    │                │                 │
   │                 │ build image     │                    │                │                 │
   │                 ├────────────────►│                    │                │                 │
   │                 │ push image      │                    │                │                 │
   │                 ├────────────────►│                    │                │                 │
   │                 │                 │                    │                │                 │
   │                 │ sed update tag  │                    │                │                 │
   │                 │ + git push      │                    │                │                 │
   │                 ├─────────────────────────────────────►│                │                 │
   │                 │                 │                    │ poll / webhook │                 │
   │                 │                 │                    ├───────────────►│                 │
   │                 │                 │                    │                │ kubectl apply   │
   │                 │                 │                    │                ├────────────────►│
   │                 │                 │                    │                │                 │ rolling
   │                 │                 │                    │                │                 │ update
   │                 │                 │                    │                │◄────────────────┤
   │                 │                 │                    │                │ sync status     │
```

**Core principles:**
- Jenkins **never** runs `kubectl apply` — it only commits changes to Git.
- ArgoCD **never** builds images — it only pulls manifests and syncs.
- Image tag = Git commit SHA (1-to-1 traceability between code ↔ image ↔ deployment).

---

## Directory Structure

```
retail-store-gitops/
├── README.md
│
├── charts/                            # Helm chart — single chart shared by all 5 services
│   └── microservice/
│       ├── Chart.yaml
│       ├── values.yaml                #   Default values (baseline for every service)
│       └── templates/
│           ├── _helpers.tpl           #   Shared labels helper
│           ├── deployment.yaml        #   Deployment template (env list; omits replicas when HPA on)
│           ├── service.yaml           #   Service template
│           ├── servicemonitor.yaml    #   ServiceMonitor template (conditional)
│           └── hpa.yaml               #   HorizontalPodAutoscaler (conditional, hpa.enabled)
│
├── apps/                              # Per-service config — only the diff vs chart defaults
│   ├── namespace/
│   │   └── namespace.yml              #   Namespace: retail-store (own Application, wave -10)
│   ├── databases/                     #   4 shared datastores (own Application, wave -5)
│   │   ├── catalog-mysql/             #     MariaDB     — Deployment + Service + PVC + Secret
│   │   ├── cart-dynamodb/             #     DynamoDB-local — Deployment + Service + PVC
│   │   ├── orders-postgres/           #     PostgreSQL  — Deployment + Service + PVC + Secret
│   │   └── checkout-redis/            #     Redis       — Deployment + Service + PVC
│   ├── ui/values.yaml                 #   LoadBalancer + probes/metrics + backend endpoints (env)
│   ├── catalog/values.yaml            #   MySQL persistence (env + secretKeyRef)
│   ├── cart/values.yaml               #   Spring Boot probes/metrics + DynamoDB persistence (env)
│   ├── orders/values.yaml             #   Spring Boot probes/metrics + Postgres persistence (env + secretKeyRef)
│   └── checkout/values.yaml           #   NestJS probes + Redis persistence (env)
│
├── environments/                      # Kustomize overlay (scaffold for future per-env patches)
│   └── dev/
│       └── kustomization.yaml
│
├── platform/                          # Platform-level components (non-app workloads)
│   ├── monitoring/                    #   Observability stack (Prometheus + Grafana + Loki + Promtail)
│   │   ├── README.md                  #   Full monitoring documentation
│   │   ├── namespace.yml              #   Namespace: monitoring
│   │   ├── storageclass-gp3.yaml      #   Default StorageClass (gp3, CSI-backed, encrypted)
│   │   ├── values-kube-prometheus-stack.yaml
│   │   ├── values-loki.yaml
│   │   ├── values-promtail.yaml
│   │   └── dashboards/
│   │       ├── kustomization.yaml     #   Kustomize configMapGenerator for 4 dashboards
│   │       ├── node-exporter-full.json
│   │       ├── k8s-cluster-monitoring.json
│   │       ├── logs-app-loki.json
│   │       └── k8s-views-pods.json
│   ├── cluster-autoscaler/            #   Node autoscaling (scales the EKS node group)
│   │   └── values.yaml                #     Helm values (autoDiscovery + IRSA SA annotation)
│   └── metrics-server/                #   Resource Metrics API (CPU/mem) — required by HPA
│       └── values.yaml                #     Helm values (resources)
│
├── argocd/                            # ArgoCD Application definitions
│   ├── root-application.yml           #   App-of-Apps root (manages all child Applications)
│   ├── retail-store-namespace-application.yml  # wave -10 (creates retail-store ns)
│   ├── retail-store-databases-application.yml  # wave  -5 (4 datastores, directory recurse)
│   ├── ui-application.yml             #   multi-source (chart + values)
│   ├── catalog-application.yml        #   multi-source
│   ├── cart-application.yml           #   multi-source
│   ├── orders-application.yml         #   multi-source
│   ├── checkout-application.yml       #   multi-source
│   ├── platform-namespace-application.yml      # wave -10
│   ├── platform-storageclass-application.yml   # wave -5
│   ├── platform-cluster-autoscaler-application.yml # wave -5  (node autoscaling, kube-system)
│   ├── platform-metrics-server-application.yml    # wave -5  (Resource Metrics API for HPA)
│   ├── platform-kps-application.yml            # wave  0  (multi-source)
│   ├── platform-loki-application.yml           # wave  5  (multi-source)
│   ├── platform-promtail-application.yml       # wave 10  (multi-source)
│   └── platform-dashboards-application.yml     # wave 15  (Kustomize)
│
└── scripts/
    └── bootstrap.sh                   # One-shot setup for a fresh cluster
```

> **Helm refactor (current structure).** The 5 services previously had ~17 duplicated raw YAML files (`deployment.yml` + `service.yml` + `servicemonitor.yml` each). They now share **one Helm chart** (`charts/microservice/`); each service contributes only a small `apps/<svc>/values.yaml` holding the values that differ from the chart defaults. A change to a shared pattern (probe, label, security context) is now a single edit in the chart template instead of five.

### Application inventory

**Service Applications** (namespace: `retail-store`) — each is a **multi-source** Application: the Helm chart from `charts/microservice/` rendered with `apps/<svc>/values.yaml`.

| Service | Values file | ArgoCD Application | Status |
|---------|-------------|--------------------|--------|
| Namespace | `apps/namespace/namespace.yml` | `retail-store-namespace` (wave -10) | Onboarded |
| Databases | `apps/databases/` | `retail-store-databases` (wave -5) | Onboarded |
| UI | `apps/ui/values.yaml` | `retail-store-ui` | Onboarded |
| Catalog | `apps/catalog/values.yaml` | `retail-store-catalog` | Onboarded |
| Cart | `apps/cart/values.yaml` | `retail-store-cart` | Onboarded |
| Orders | `apps/orders/values.yaml` | `retail-store-orders` | Onboarded |
| Checkout | `apps/checkout/values.yaml` | `retail-store-checkout` | Onboarded |

**Platform Applications** — deployed in sync-wave order

| Wave | ArgoCD Application | What it deploys |
|------|--------------------|-----------------|
| `-10` | `platform-namespace` | `monitoring` namespace |
| `-5` | `platform-storageclass` | `gp3` StorageClass (default) |
| `-5` | `platform-cluster-autoscaler` | Cluster Autoscaler — node autoscaling (`kube-system`) |
| `-5` | `platform-metrics-server` | metrics-server — Resource Metrics API for HPA (`kube-system`) |
| `0` | `platform-kube-prometheus-stack` | Prometheus + Grafana + Alertmanager |
| `5` | `platform-loki` | Loki SingleBinary (log aggregation) |
| `10` | `platform-promtail` | Promtail DaemonSet (log shipper) |
| `15` | `platform-dashboards` | 4 Grafana dashboard ConfigMaps (Kustomize) |

---

## Databases (Persistent Datastores)

Four services persist state. With **2 replicas each**, in-memory storage would diverge per pod, so each writing service is wired to a **shared external datastore** running in the cluster. The `retail-store-databases` Application (sync-wave `-5`) brings them up **after** the namespace (`-10`) and **before** the services (default wave `0`), so a datastore is `Healthy` before the service that depends on it syncs.

| Service | Datastore | Image | Service:port | Schema/data setup |
|---------|-----------|-------|--------------|-------------------|
| catalog (Go) | MariaDB | `mariadb:11` | `catalog-mysql:3306` | Service auto-migrates + seeds products/tags on startup |
| cart (Spring) | DynamoDB-local | `amazon/dynamodb-local` | `cart-dynamodb:8000` | Service creates the table (`create-table=true`) |
| orders (Spring) | PostgreSQL | `postgres:16` | `orders-postgres:5432` | Service runs Flyway (`baseline-on-migrate=true`) |
| checkout (NestJS) | Redis | `redis:7` | `checkout-redis:6379` | No schema (key-value session store) |

> **No manual SQL seeding.** Each service builds its own schema and data on first boot — the datastores only need to exist empty with credentials. **No message broker either:** orders defaults `messaging.provider=in-memory` and excludes `RabbitAutoConfiguration`, so the checkout → create-order flow works without RabbitMQ.

### How the wiring works

The shared Helm chart now renders an optional `env` list (`charts/microservice/templates/deployment.yaml`). Each service declares its connection settings in `apps/<svc>/values.yaml`:

```yaml
# apps/orders/values.yaml (excerpt)
env:
  - {name: RETAIL_ORDERS_PERSISTENCE_PROVIDER, value: "postgres"}
  - {name: RETAIL_ORDERS_PERSISTENCE_ENDPOINT, value: "orders-postgres:5432"}
  - {name: RETAIL_ORDERS_PERSISTENCE_NAME,     value: "ordersdb"}
  - {name: RETAIL_ORDERS_PERSISTENCE_USERNAME, value: "orders_user"}
  - name: RETAIL_ORDERS_PERSISTENCE_PASSWORD             # password from a Secret, never in values.yaml
    valueFrom:
      secretKeyRef:
        name: orders-postgres-secret
        key: password
```

The `ui` service receives the four backend endpoints the same way (`RETAIL_UI_ENDPOINTS_CATALOG/CARTS/CHECKOUT/ORDERS` → `http://<svc>:80`).

### Design notes

| Decision | Why |
|----------|-----|
| `strategy: Recreate` on every datastore Deployment | PVCs are `ReadWriteOnce`; Recreate avoids two pods mounting the same EBS volume during a rollout |
| Passwords in a `Secret` (`catalog-mysql-secret`, `orders-postgres-secret`) | Keeps plaintext out of `values.yaml`; encrypted at rest in etcd via the cluster's KMS envelope encryption. External Secrets Operator is a documented next step. |
| PostgreSQL `PGDATA` set to a subdirectory | Avoids the `initdb` "directory not empty" error caused by `lost+found` on a fresh ext4 EBS volume |
| DynamoDB-local pod `securityContext.fsGroup: 1000` | The image runs as a non-root user; fsGroup makes the mounted EBS volume writable |
| `directory.recurse: true` on the databases Application | Manifests live in per-datastore subfolders under `apps/databases/` |

> **Scope note:** DynamoDB-local stands in for AWS DynamoDB so the cart works in a self-contained cluster; the cart pod still needs dummy `AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` values because the AWS SDK requires them even against a local endpoint. Redis runs without auth (demo scope).

---

## Node Autoscaling (Cluster Autoscaler)

The node group is fixed-size by default, but a **Cluster Autoscaler** (CA) is deployed so the node count follows demand. When a pod cannot be scheduled because no node has enough free CPU/memory, CA raises the node group's desired capacity (within `min=2 … max=4`); when nodes sit underutilized, it scales back down.

| Item | Value |
|------|-------|
| Application | `platform-cluster-autoscaler` (sync-wave -5, namespace `kube-system`) |
| Chart | `cluster-autoscaler` (kubernetes.github.io/autoscaler), image pinned to `v1.31.0` (matches EKS 1.31) |
| Values | `platform/cluster-autoscaler/values.yaml` |
| Node discovery | `autoDiscovery.clusterName` — EKS managed node groups auto-tag their ASG with `k8s.io/cluster-autoscaler/<cluster>`, so no manual ASG tagging is needed |
| AWS permissions | IRSA role `ecommerce-cluster-cluster-autoscaler` (Terraform, module `02-cluster-eks`), bound to SA `kube-system:cluster-autoscaler` |

> **Why it exists:** during bring-up the Prometheus pod once stayed `Pending` with `Insufficient cpu` because the two original nodes were full. CA automates the fix (add a node) instead of manually running `aws eks update-nodegroup-config`.

### Databases are protected from scale-down

The four database pods carry the annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`. Without it, CA could drain a node running a database during scale-down and restart the pod (brief downtime). The annotation tells CA to leave those nodes alone, keeping the datastores stable.

> **Note on node sizing:** `node_desired_size` / `node_max_size` live in Terraform (`02-cluster-eks`). The module sets `ignore_changes` on `desired_size` (it expects CA to manage it at runtime), so on an already-running cluster the live node count is owned by CA — `terraform apply` only sets `desired_size` on a fresh cluster. `max_size` is **not** ignored, so raising the ceiling (e.g. 3 → 4) does apply to a running cluster.

---

## Pod Autoscaling (HPA)

Where Cluster Autoscaler scales **nodes**, a **HorizontalPodAutoscaler** (HPA) scales **pods**. The two are complementary: under load HPA adds replicas, and if those replicas no longer fit, CA adds a node.

HPA is built into the shared chart and toggled per service. It is **off by default** and currently enabled for **UI** only (`apps/ui/values.yaml`):

```yaml
hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 60
```

When `hpa.enabled: true`, the chart renders a `HorizontalPodAutoscaler` (`templates/hpa.yaml`) and **omits `spec.replicas`** from the Deployment so HPA fully owns the replica count.

**Prerequisite — metrics-server.** HPA reads CPU/memory from the Resource Metrics API, which kube-prometheus-stack does not provide. It is deployed as `platform-metrics-server` (`platform/metrics-server/values.yaml`, sync-wave -5). Verify with `kubectl top nodes`. If the metrics-server pod crashloops with a TLS scrape error, add `--kubelet-insecure-tls` to its args.

### Avoiding the ArgoCD ↔ HPA replicas fight

When HPA changes a Deployment's replica count at runtime, a GitOps controller with self-heal can try to revert it. This repo guards against that **two ways**:

1. The chart **omits `spec.replicas`** entirely when `hpa.enabled` — nothing for ArgoCD to enforce.
2. The UI Application adds `ignoreDifferences` on `/spec/replicas` (belt-and-suspenders).

### Demonstrating load-based scaling

```bash
hey -z 3m -c 50 http://<ui-loadbalancer>/      # generate load on UI
kubectl get hpa -n retail-store -w             # watch UI replicas climb toward maxReplicas
kubectl get nodes -w                           # if pods don't fit, CA adds a 4th node
```

---

## Alerting (Alertmanager → Telegram)

Beyond collecting metrics and logs, the stack sends **proactive alerts** to Telegram via **Alertmanager** (bundled in `kube-prometheus-stack`). It is configured in `platform/monitoring/values-kube-prometheus-stack.yaml` and managed by GitOps.

- **Alert rules** are declared via `additionalPrometheusRulesMap` (auto-generates a `PrometheusRule`): `UIHighCPULoad`, `UIHpaMaxedOut`, `RetailStorePodPending`, `ClusterNodeScaledUp` — tuned for the load / autoscaling scenario.
- **Routing:** only alerts labelled `channel: telegram` reach the Telegram receiver; all default kube-prometheus-stack alerts go to a `null` receiver to avoid noise.
- **Bot token** lives in a Kubernetes Secret created out-of-band (not committed to Git), mounted into Alertmanager via `alertmanager.alertmanagerSpec.secrets`; the config reads it with `bot_token_file`.

Create the Secret before/alongside the sync, then set the numeric `chat_id` in the values file:

```bash
kubectl create secret generic telegram-alertmanager-secret \
  --namespace monitoring \
  --from-literal=bot-token='<BOT_TOKEN>'
```

When the load scenario runs (`hey`), the CPU-high / HPA-maxed / pod-Pending / node-added conditions fire and post to Telegram.

---

## How the ArgoCD Application Works

Every file under `argocd/` defines an ArgoCD `Application` resource. Each service uses the **multi-source pattern**: one source provides the Helm chart, the other provides the values file (referenced via the `$values` alias). Example (`argocd/ui-application.yml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-ui
  namespace: argocd
spec:
  project: default
  sources:
    # Source 1: the shared Helm chart
    - repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
      targetRevision: main
      path: charts/microservice
      helm:
        releaseName: ui
        valueFiles:
          - $values/apps/ui/values.yaml   # values pulled from the $values source below
    # Source 2: the same repo, exposed as the `values` alias
    - repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true                    # Remove resources no longer in Git
      selfHeal: true                 # Restore state if someone edits directly on the cluster
    syncOptions:
      - CreateNamespace=false         # namespace is owned by retail-store-namespace (wave -10)
```

### Field reference

| Field | Meaning |
|-------|---------|
| `sources[].repoURL` | Git repo URL — ArgoCD pulls from here |
| `sources[].targetRevision` | Branch/tag/commit to track, here `main` |
| `sources[].path` | Source 1: folder holding the Helm chart (`charts/microservice`) |
| `sources[].helm.releaseName` | Helm release name (= the service name) |
| `sources[].helm.valueFiles` | Values file, addressed through the `$values` alias |
| `sources[].ref: values` | Source 2: exposes the repo as the `$values` alias so the chart source can read the values file |
| `destination.server` | `kubernetes.default.svc` = the cluster where ArgoCD itself runs |
| `destination.namespace` | Target namespace for the rendered manifests |
| `syncPolicy.automated.prune` | Delete a K8s resource when its manifest is removed from Git |
| `syncPolicy.automated.selfHeal` | Re-apply manifest if the live state deviates from Git |
| `CreateNamespace=false` | The `retail-store` namespace is created by its own Application (`retail-store-namespace`, sync-wave -10), so service Applications must not race to create it |

> **Why a separate namespace Application?** When 5 service Applications sync in parallel, their order is non-deterministic. If each tried to create the `retail-store` namespace inline, one could fail while another is mid-create. A dedicated `retail-store-namespace` Application at sync-wave `-10` guarantees the namespace exists before any service syncs — the same pattern already used for the `monitoring` namespace.

> **Requirement:** the multi-source pattern needs ArgoCD ≥ 2.6 (already satisfied; the monitoring stack uses it too).

### First-time apply on a fresh cluster

Use the bootstrap script — it handles namespace creation, the Grafana secret, and the root Application in one shot:

```bash
# Connect kubectl to the EKS cluster
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Clone this repo (if not already present)
git clone https://github.com/tranduyloc895/retail-store-gitops.git
cd retail-store-gitops

# Run bootstrap — save the Grafana password it prints
bash scripts/bootstrap.sh
```

Track sync progress:

```bash
kubectl get application -n argocd -w
# NAME                              SYNC STATUS   HEALTH STATUS
# root                              Synced        Healthy
# retail-store-namespace            Synced        Healthy
# retail-store-ui                   Synced        Healthy
# retail-store-catalog              Synced        Healthy
# retail-store-cart                 Synced        Healthy
# retail-store-orders               Synced        Healthy
# retail-store-checkout             Synced        Healthy
# platform-namespace                Synced        Healthy
# platform-storageclass             Synced        Healthy
# platform-kube-prometheus-stack    Synced        Healthy
# platform-loki                     Synced        Healthy
# platform-promtail                 Synced        Healthy
# platform-dashboards               Synced        Healthy
```

Afterwards ArgoCD polls the repo every 3 minutes (default) and syncs any new commits automatically.

---

## CI/CD Flow with Jenkins

### The `Update GitOps` stage in the Jenkinsfile

On every successful build (in the `retail-store-microservices` repo), Jenkins runs this stage to update the image tag:

```groovy
stage('Update GitOps') {
    steps {
        withCredentials([usernamePassword(
            credentialsId: 'github-gitops-token',
            usernameVariable: 'GIT_USER',
            passwordVariable: 'GIT_TOKEN'
        )]) {
            sh '''
                rm -rf gitops-repo
                git clone https://${GIT_USER}:${GIT_TOKEN}@github.com/tranduyloc895/retail-store-gitops.git gitops-repo
                cd gitops-repo

                # Update only the `tag:` line in the service's values.yaml
                sed -i "s|^\([[:space:]]*tag:\s*\).*|\1\"$IMAGE_TAG\"|" apps/<service>/values.yaml
                grep -q "tag: \"$IMAGE_TAG\"" apps/<service>/values.yaml || { echo "sed FAILED"; exit 1; }

                git config user.email "jenkins@ci.local"
                git config user.name "Jenkins CI"
                git add apps/<service>/values.yaml
                git diff --staged --quiet || git commit -m "chore(<service>): update image to $IMAGE_TAG"
                git push origin main
            '''
        }
    }
}
```

### Step-by-step explanation

| Step | Purpose |
|------|---------|
| `rm -rf gitops-repo` | Clean leftover workspace |
| `git clone` with token | Clone via HTTPS using a PAT (no SSH keys needed) |
| `sed -i "s\|...tag:...\|"` | Replace **only the `tag:` value** in `values.yaml` (Helm builds the full image from `repository` + `tag`) |
| `grep -q "tag: \\"$IMAGE_TAG\\""` | Verify the replacement actually happened (prevents silent `sed` failures) |
| `git diff --staged --quiet \|\|` | Only commit if something actually changed (idempotent) |
| `git push origin main` | Push to main — ArgoCD will pick it up within minutes |

> **What changed in the Helm refactor:** Jenkins used to `sed` the full `image:` line in `deployment.yml`. Now it edits a single `tag:` line in `apps/<service>/values.yaml` — a smaller, more deterministic target. The image `repository` is fixed in the values file and never touched by CI.

### Required Jenkins credential

**Credential ID: `github-gitops-token`**
- **Kind:** Username with password
- **Username:** GitHub username (e.g., `tranduyloc895`)
- **Password:** GitHub Fine-grained Personal Access Token

**Token permissions (least-privilege):**

| Permission | Access | Reason |
|-----------|--------|--------|
| Contents | Read and write | `git clone` + `git push` |
| Metadata | Read (auto) | Required by GitHub |
| *All others* | — | **Do not grant** |

Repository selected: **only `retail-store-gitops`** (do not grant access to the whole org).

---

## Usage Guide

### Prerequisites

- EKS cluster `ecommerce-cluster` is running (module `02-cluster-eks` in the `infrastructure` repo)
- ArgoCD is installed via Helm (same module)
- This repo is public, or ArgoCD has been configured with credentials

### Apply the ArgoCD Applications

```bash
# Connect kubectl to the cluster
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Run the bootstrap script (creates Grafana secret + applies root Application)
bash scripts/bootstrap.sh

# Check status
kubectl get application -n argocd
```

### Access the ArgoCD UI

```bash
# Port-forward the ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Retrieve the initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Open `https://localhost:8080` — username `admin`, password from the command above.

### Manual update (bypass Jenkins)

For a hotfix or a manual test:

```bash
git clone https://github.com/tranduyloc895/retail-store-gitops.git
cd retail-store-gitops

# Edit the image.tag value in apps/<service>/values.yaml
vim apps/ui/values.yaml

git add apps/ui/values.yaml
git commit -m "manual: update ui image to <tag>"
git push origin main
```

ArgoCD will sync within 3 minutes, or you can trigger a sync immediately:
```bash
kubectl patch application retail-store-ui -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Rollback

GitOps makes this trivial — revert the commit:

```bash
git revert <commit-hash-of-bad-deploy>
git push origin main
```

ArgoCD will apply the previous version within minutes.

---

## Adding a New Service

All 5 services (UI, Catalog, Cart, Orders, Checkout) are currently onboarded. Thanks to the shared Helm chart, adding a 6th service (e.g., `shipping`) means writing **one values file + one Application file** — no new manifests.

### Step 1: Create the values file

```bash
mkdir -p apps/shipping
```

**`apps/shipping/values.yaml`** — only the fields that differ from `charts/microservice/values.yaml` (the chart defaults: 2 replicas, ClusterIP, port 8080, `/health` probes, `/metrics` ServiceMonitor):

```yaml
name: shipping

image:
  repository: <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/retail-store/shipping
  tag: "bootstrap"          # Jenkins overwrites this line on each build

# Override only if needed, e.g. for a Spring Boot service:
# probes:
#   readiness: { path: /actuator/health/readiness }
#   liveness:  { path: /actuator/health/liveness }
# monitoring:
#   path: /actuator/prometheus
# service:
#   type: LoadBalancer       # only if it must be exposed externally
```

> If the service matches the defaults (Go/NestJS-style: `/health` probes, `/metrics` endpoint, ClusterIP), the file is just `name` + `image`.

### Step 2: Create the ArgoCD Application

**`argocd/shipping-application.yml`** — copy an existing one (e.g. `catalog-application.yml`) and change `name`, `releaseName`, and the `valueFiles` path:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-shipping
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
      targetRevision: main
      path: charts/microservice
      helm:
        releaseName: shipping
        valueFiles:
          - $values/apps/shipping/values.yaml
    - repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

### Step 3: Create a Jenkinsfile for the service

In `retail-store-microservices/src/shipping/Jenkinsfile`, copy an existing one (e.g. `catalog`) and change:
- `ECR_REPO_NAME` = `retail-store/shipping`
- `SERVICE_NAME` / `SERVICE_DIR` accordingly
- `sed` / `git add` target = `apps/shipping/values.yaml` (the `tag:` line)

### Step 4: Apply

```bash
git add apps/shipping/ argocd/shipping-application.yml
git commit -m "feat: onboard shipping service"
git push origin main

# Apply the new ArgoCD Application (or let the root App-of-Apps pick it up)
kubectl apply -f argocd/shipping-application.yml
```

### App-of-Apps pattern (implemented)

`argocd/root-application.yml` is an ArgoCD Application that watches the entire `argocd/` folder. When ArgoCD syncs the root Application, it discovers and syncs every child Application file in that folder automatically.

This means **you only need one `kubectl apply`** per fresh cluster:

```bash
# bootstrap.sh does this for you, but you can also run it manually:
kubectl apply -f argocd/root-application.yml
```

After that, every new Application file added under `argocd/` is onboarded automatically on the next sync — no more `kubectl apply -f argocd/<new-file>.yml`.

---

## Cleanup After Each Lab

GitOps state itself costs nothing (it is just a Git repo). However, the workloads it manages run on the EKS cluster and consume resources. When you pause the lab, remove the workloads so LoadBalancers, EBS volumes, and pods stop consuming AWS resources.

```bash
# 1. Delete the root Application — ArgoCD cascades and deletes all child Applications
kubectl delete application root -n argocd

# 2. Delete workload and monitoring namespaces
#    - retail-store: removes pods, LoadBalancers (stops ~$18/month ELB charge)
#                    + the 4 database PVCs → EBS volumes auto-deleted (reclaimPolicy=Delete)
#    - monitoring: removes pods + PVCs → EBS volumes auto-deleted (reclaimPolicy=Delete)
kubectl delete namespace retail-store monitoring
```

After that, the cluster only runs `kube-system` + `argocd`. To destroy the cluster itself, see the teardown section in `infrastructure/README.md`.

> **Tip:** Any `LoadBalancer` service (e.g. the UI) provisions an AWS ELB at ~$18/month. Always delete the namespace before pausing the lab.
>
> **Tip:** The monitoring stack uses ~37 GiB EBS gp3 (~$3/month). Deleting the `monitoring` namespace releases those volumes automatically.

---

## Related repos

| Repo | Role |
|------|------|
| [infrastructure](https://github.com/tranduyloc895/infrastructure) | Terraform + Ansible: VPC, EKS, Jenkins, ECR |
| [retail-store-microservices](https://github.com/tranduyloc895/retail-store-microservices) | Source code for the 5 microservices + Jenkinsfile |
| **retail-store-gitops** (this repo) | K8s manifests + ArgoCD Applications |

---

> *NT114 course project — University of Information Technology (UIT)*
