# Retail Store GitOps

Kubernetes manifests & ArgoCD Application definitions for the **DevSecOps E-commerce** project (NT114 — UIT).

This repo is the **source of truth** for the desired state of every workload running on the EKS cluster `ecommerce-cluster`. ArgoCD watches this repo and automatically syncs changes to the cluster on every new commit.

> **GitOps principle:** if it is not in Git, it is not running on the cluster. Every change must go through a commit.

---

## Table of Contents

- [What GitOps Is and Why We Use It](#what-gitops-is-and-why-we-use-it)
- [Deployment Flow Architecture](#deployment-flow-architecture)
- [Directory Structure](#directory-structure)
- [How the ArgoCD Application Works](#how-the-argocd-application-works)
- [CI/CD Flow with Jenkins](#cicd-flow-with-jenkins)
- [Usage Guide](#usage-guide)
- [Adding a New Service](#adding-a-new-service)
- [Cleanup After Each Lab](#cleanup-after-each-lab)

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
├── apps/                              # Kubernetes manifests for each service
│   ├── ui/
│   │   ├── namespace.yml              #   Namespace: retail-store
│   │   ├── deployment.yml             #   Deployment (image tag updated by Jenkins)
│   │   └── service.yml                #   Service type LoadBalancer
│   ├── catalog/
│   │   ├── deployment.yml
│   │   └── service.yml                #   ClusterIP
│   ├── cart/
│   │   ├── deployment.yml
│   │   └── service.yml                #   ClusterIP
│   ├── orders/
│   │   ├── deployment.yml
│   │   └── service.yml                #   ClusterIP
│   └── checkout/
│       ├── deployment.yml
│       └── service.yml                #   ClusterIP
│
└── argocd/                            # ArgoCD Application definitions
    ├── ui-application.yml
    ├── catalog-application.yml
    ├── cart-application.yml
    ├── orders-application.yml
    └── checkout-application.yml
```

### Current services

| Service | Manifest path | ArgoCD Application | Status |
|---------|---------------|--------------------|--------|
| UI | `apps/ui/` | `retail-store-ui` | Onboarded |
| Catalog | `apps/catalog/` | `retail-store-catalog` | Onboarded |
| Cart | `apps/cart/` | `retail-store-cart` | Onboarded |
| Orders | `apps/orders/` | `retail-store-orders` | Onboarded |
| Checkout | `apps/checkout/` | `retail-store-checkout` | Onboarded |

---

## How the ArgoCD Application Works

Every file under `argocd/` defines an ArgoCD `Application` resource. Example (`argocd/ui-application.yml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-ui
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
    targetRevision: main
    path: apps/ui                    # Folder containing the manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true                    # Remove resources no longer in Git
      selfHeal: true                 # Restore state if someone edits directly on the cluster
    syncOptions:
      - CreateNamespace=true         # Create the namespace if it does not exist
```

### Field reference

| Field | Meaning |
|-------|---------|
| `source.repoURL` | Git repo URL — ArgoCD pulls from here |
| `source.targetRevision` | Branch/tag/commit to track, here `main` |
| `source.path` | Folder in the repo containing manifests (not a specific filename) |
| `destination.server` | `kubernetes.default.svc` = the cluster where ArgoCD itself runs |
| `destination.namespace` | Target namespace for the manifests |
| `syncPolicy.automated.prune` | Delete a K8s resource when its manifest is removed from Git |
| `syncPolicy.automated.selfHeal` | Re-apply manifest if the live state deviates from Git |
| `CreateNamespace=true` | ArgoCD runs `kubectl create ns` automatically if needed |

### First-time apply of ArgoCD Applications

```bash
# Connect kubectl to the EKS cluster
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Apply every Application definition
kubectl apply -f argocd/

# Verify
kubectl get application -n argocd
# NAME                    SYNC STATUS   HEALTH STATUS
# retail-store-ui         Synced        Healthy
# retail-store-catalog    Synced        Healthy
# retail-store-cart       Synced        Healthy
# retail-store-orders     Synced        Healthy
# retail-store-checkout   Synced        Healthy
```

Afterwards ArgoCD polls the repo every 3 minutes (default) and syncs any new changes automatically.

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

                sed -i "s|image:.*retail-store/<service>.*|image: $FULL_IMAGE|" apps/<service>/deployment.yml
                grep -q "$FULL_IMAGE" apps/<service>/deployment.yml || { echo "sed FAILED"; exit 1; }

                git config user.email "jenkins@ci.local"
                git config user.name "Jenkins CI"
                git add apps/<service>/deployment.yml
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
| `sed -i "s\|image:...\|"` | Replace the old image line with the new one (tag = commit SHA) |
| `grep -q "$FULL_IMAGE"` | Verify the replacement actually happened (prevents silent `sed` failures) |
| `git diff --staged --quiet \|\|` | Only commit if something actually changed (idempotent) |
| `git push origin main` | Push to main — ArgoCD will pick it up within minutes |

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
# SSH into the Jenkins Agent (or run locally after update-kubeconfig)
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Apply every Application in one shot
kubectl apply -f argocd/

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

# Edit the image tag in apps/<service>/deployment.yml
vim apps/ui/deployment.yml

git add apps/ui/deployment.yml
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

All 5 services (UI, Catalog, Cart, Orders, Checkout) are currently onboarded. To add a 6th service (e.g., `shipping`):

### Step 1: Create the manifests

```bash
mkdir -p apps/shipping
```

Create two files:

**`apps/shipping/deployment.yml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shipping
  namespace: retail-store
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shipping
  template:
    metadata:
      labels:
        app: shipping
    spec:
      containers:
        - name: shipping
          image: <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/retail-store/shipping:PLACEHOLDER
          ports:
            - containerPort: 8080
          # env, resources, probes...
```

**`apps/shipping/service.yml`** — use `ClusterIP` if it is only called internally:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: shipping
  namespace: retail-store
spec:
  type: ClusterIP
  selector:
    app: shipping
  ports:
    - port: 80
      targetPort: 8080
```

### Step 2: Create the ArgoCD Application

**`argocd/shipping-application.yml`**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-shipping
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
    targetRevision: main
    path: apps/shipping
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Step 3: Create a Jenkinsfile for the service

In `retail-store-microservices/src/shipping/Jenkinsfile`, copy an existing one (e.g. `catalog`) and change:
- `ECR_REPO_NAME` = `retail-store/shipping`
- `sed` target path = `apps/shipping/deployment.yml`
- Regex pattern = `retail-store/shipping`

### Step 4: Apply

```bash
git add apps/shipping/ argocd/shipping-application.yml
git commit -m "feat: onboard shipping service"
git push origin main

# Apply the new ArgoCD Application
kubectl apply -f argocd/shipping-application.yml
```

### (Future) App-of-Apps pattern

Instead of applying every Application manually, create a "root" Application that manages all of them:

```yaml
# argocd/root-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
    path: argocd                     # Folder containing child Applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {}
```

After that, `kubectl apply -f argocd/root-app.yml` only once — every new Application added under `argocd/` is onboarded automatically.

---

## Cleanup After Each Lab

GitOps state itself costs nothing (it is just a Git repo). However, the workloads it manages run on the EKS cluster and consume resources. When you pause the lab, remove the workloads so the LoadBalancers and pods stop consuming AWS resources.

```bash
# 1. Delete all ArgoCD Applications (stops ArgoCD from recreating workloads)
kubectl delete application --all -n argocd

# 2. Delete the workload namespace (removes pods, services, LoadBalancers)
kubectl delete namespace retail-store
```

After that, the cluster only runs `kube-system` + `argocd` + optionally `monitoring`. To go further and destroy the cluster itself, see the teardown section in the `infrastructure/README.md`.

> **Tip:** any `LoadBalancer` service (e.g. the UI) provisions an AWS ELB at ~$18/month. Always delete the namespace before pausing the lab.

---

## Related repos

| Repo | Role |
|------|------|
| [infrastructure](https://github.com/tranduyloc895/infrastructure) | Terraform + Ansible: VPC, EKS, Jenkins, ECR |
| [retail-store-microservices](https://github.com/tranduyloc895/retail-store-microservices) | Source code for the 5 microservices + Jenkinsfile |
| **retail-store-gitops** (this repo) | K8s manifests + ArgoCD Applications |

---

> *NT114 course project — University of Information Technology (UIT)*
