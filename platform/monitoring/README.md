# platform/monitoring — Observability Stack (GitOps)

ArgoCD-managed monitoring stack for the EKS cluster: **Prometheus + Grafana + Loki + Promtail**.

Deployed via the **App-of-Apps** pattern — a single `bootstrap.sh` script brings the entire stack up on a fresh cluster. ArgoCD keeps it in sync thereafter.

---

## Table of Contents

- [Stack Overview](#stack-overview)
- [Directory Structure](#directory-structure)
- [ArgoCD Applications & Sync Order](#argocd-applications--sync-order)
- [Bootstrap on a Fresh Cluster](#bootstrap-on-a-fresh-cluster)
- [Access Grafana](#access-grafana)
- [Dashboards](#dashboards)
- [Cleanup After Each Lab](#cleanup-after-each-lab)
- [Chart Versions](#chart-versions)

---

## Stack Overview

| Component | Chart | Mode | Storage |
|-----------|-------|------|---------|
| **kube-prometheus-stack** | `prometheus-community/kube-prometheus-stack` | Prometheus + Grafana + Alertmanager | 20 Gi (Prometheus), 5 Gi (Grafana), 2 Gi (Alertmanager) |
| **Loki** | `grafana/loki` | SingleBinary | 10 Gi, 7-day retention, filesystem |
| **Promtail** | `grafana/promtail` | DaemonSet | No persistent storage |

All PVCs use the `gp3` StorageClass (CSI-backed, encrypted at-rest).

### What is monitored

| Layer | What is collected |
|-------|-------------------|
| System (node-exporter) | CPU / RAM / Disk / Network per EKS node |
| Platform (kube-state-metrics + kubelet) | Pod/Deployment/PVC state, restarts, OOMKill |
| Control plane (EKS API server) | Request rate, latency per verb |
| Logs (Promtail → Loki) | Stdout/stderr of ALL pods in every namespace |
| Application metrics | Planned (Phase 3.3) — ServiceMonitor per microservice |

---

## Directory Structure

```
platform/monitoring/
├── README.md                             # This file
├── namespace.yml                         # Namespace: monitoring (wave -10)
├── storageclass-gp3.yaml                 # StorageClass gp3 (wave -5)
├── values-kube-prometheus-stack.yaml     # kps Helm values (wave 0)
├── values-loki.yaml                      # Loki Helm values (wave 5)
├── values-promtail.yaml                  # Promtail Helm values (wave 10)
└── dashboards/
    ├── kustomization.yaml                # Kustomize configMapGenerator (wave 15)
    ├── node-exporter-full.json           # Dashboard 1860
    ├── k8s-cluster-monitoring.json       # Dashboard 315
    ├── logs-app-loki.json                # Dashboard 13639
    └── k8s-views-pods.json               # Dashboard 15760
```

---

## ArgoCD Applications & Sync Order

Six ArgoCD Applications are defined in `argocd/platform-*.yml`. They deploy in order using `sync-wave` annotations:

| Wave | Application file | What it creates |
|------|-----------------|-----------------|
| `-10` | `platform-namespace-application.yml` | `monitoring` namespace |
| `-5` | `platform-storageclass-application.yml` | `gp3` StorageClass (default) |
| `0` | `platform-kps-application.yml` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| `5` | `platform-loki-application.yml` | Loki SingleBinary |
| `10` | `platform-promtail-application.yml` | Promtail DaemonSet |
| `15` | `platform-dashboards-application.yml` | 4 dashboard ConfigMaps (via Kustomize) |

**Multi-source pattern:** The kps, Loki, and Promtail Applications reference the upstream Helm chart directly plus the `values-*.yaml` file from this Git repo. This means values are version-controlled in Git without needing to repackage the chart.

**Grafana password:** Managed out-of-band as a Kubernetes Secret `grafana-admin` in the `monitoring` namespace. The kps chart reads it via `grafana.admin.existingSecret`. The secret is created by `bootstrap.sh` (never committed to Git).

---

## Bootstrap on a Fresh Cluster

After `terraform apply` on `02-cluster-eks` (which installs ArgoCD), run once:

```bash
# 1. Point kubectl at the cluster
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# 2. Clone the gitops repo (if not already present)
git clone https://github.com/tranduyloc895/retail-store-gitops.git
cd retail-store-gitops

# 3. Run the bootstrap script — it creates the Grafana secret and applies the root Application
bash scripts/bootstrap.sh
```

The script does the following automatically:
1. Waits for ArgoCD CRDs + server to be ready.
2. Creates the `monitoring` namespace (idempotent).
3. Creates the `grafana-admin` Kubernetes Secret with a random 24-char password (only if the secret does not already exist).
4. Applies `argocd/root-application.yml` — the App-of-Apps root that manages all child Applications.

> **Important:** The script prints the Grafana password to stdout when it creates the secret. **Save it immediately** — it cannot be recovered from the script after the terminal is closed. If lost, see [Recover the Grafana password](#recover-the-grafana-password) below.

After `bootstrap.sh` completes, ArgoCD syncs all Applications automatically. Track progress:

```bash
# Watch all Applications sync
kubectl get applications -n argocd -w

# Expected final state (all 11 Applications):
# NAME                         SYNC STATUS   HEALTH STATUS
# root                         Synced        Healthy
# retail-store-ui              Synced        Healthy
# retail-store-catalog         Synced        Healthy
# retail-store-cart            Synced        Healthy
# retail-store-orders          Synced        Healthy
# retail-store-checkout        Synced        Healthy
# platform-namespace           Synced        Healthy
# platform-storageclass        Synced        Healthy
# platform-kube-prometheus-stack Synced      Healthy
# platform-loki                Synced        Healthy
# platform-promtail            Synced        Healthy
# platform-dashboards          Synced        Healthy
```

---

## Access Grafana

### Port-forward (development)

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
```

Open `http://localhost:3000` — username `admin`, password from `bootstrap.sh`.

### Recover the Grafana password

If the password was not saved when `bootstrap.sh` ran:

```bash
kubectl -n monitoring get secret grafana-admin \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

### Expose publicly (demo only)

Edit `values-kube-prometheus-stack.yaml`:
```yaml
grafana:
  service:
    type: LoadBalancer   # Change from ClusterIP
```

Commit + push — ArgoCD will apply within 3 minutes. **Revert to `ClusterIP` immediately after the demo** to stop the ~$18/month ELB charge.

---

## Dashboards

4 community dashboards are automatically provisioned via Kustomize `configMapGenerator`:

| ID | Name | Purpose |
|----|------|---------|
| **1860** | Node Exporter Full | CPU / RAM / Disk / Network per EKS node |
| **315** | Kubernetes Cluster Monitoring | Pod count, namespace resource usage |
| **13639** | Logs / App (Loki) | Real-time log viewer by namespace/pod |
| **15760** | Kubernetes Views / Pods | Per-pod CPU / RAM / restart drill-down |

Dashboards are discovered by the Grafana sidecar using the label `grafana_dashboard=1` on their ConfigMaps.

To add a new dashboard:
1. Download the JSON from https://grafana.com/grafana/dashboards/
2. Save it to `platform/monitoring/dashboards/<name>.json`
3. Add an entry to `platform/monitoring/dashboards/kustomization.yaml`
4. Commit + push — ArgoCD handles the rest.

---

## Cleanup After Each Lab

Because ArgoCD manages the monitoring stack, cleanup is done by deleting the Applications (not by running `helm uninstall`):

```bash
# Delete monitoring-related ArgoCD Applications
kubectl delete application \
  platform-dashboards \
  platform-promtail \
  platform-loki \
  platform-kube-prometheus-stack \
  platform-storageclass \
  platform-namespace \
  -n argocd

# Delete the monitoring namespace (releases PVCs → EBS volumes auto-deleted)
kubectl delete namespace monitoring
```

Or, if you want to wipe everything (including app workloads) at once:

```bash
# Delete the root Application — this deletes all child Applications and their resources
kubectl delete application root -n argocd
kubectl delete namespace retail-store monitoring
```

After that, proceed with `terraform destroy` on `02-cluster-eks` as usual.

> **Note on EBS volumes:** PVCs in the `monitoring` namespace are backed by EBS volumes with `reclaimPolicy: Delete`. Deleting the namespace triggers automatic deletion of the PVCs and their backing volumes. If you skip namespace deletion and go straight to `terraform destroy`, check **AWS Console > EC2 > Volumes** for any orphaned `available` volumes.

---

## Chart Versions

| Chart | Version | Repository |
|-------|---------|------------|
| `kube-prometheus-stack` | `58.0.0` | `https://prometheus-community.github.io/helm-charts` |
| `loki` | `6.6.0` | `https://grafana.github.io/helm-charts` |
| `promtail` | `6.16.0` | `https://grafana.github.io/helm-charts` |

To upgrade a chart: bump the `targetRevision` in the corresponding `argocd/platform-*.yml` Application file, commit, and push. ArgoCD will run `helm upgrade` automatically.

---

> *NT114 course project — University of Information Technology (UIT)*
