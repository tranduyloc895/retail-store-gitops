# Retail Store GitOps

Kubernetes manifests & ArgoCD Application definitions cho dự án **DevSecOps E-commerce** (NT114 - UIT).

Đây là **source of truth** cho trạng thái mong muốn (desired state) của toàn bộ workload chạy trên EKS cluster `ecommerce-cluster`. ArgoCD theo dõi repo này và tự động đồng bộ lên cluster mỗi khi có commit mới.

> **GitOps principle:** Nếu nó không có trong Git, nó không được chạy trên cluster. Mọi thay đổi đều phải đi qua commit.

---

## Mục lục

- [GitOps là gì và tại sao dùng](#gitops-là-gì-và-tại-sao-dùng)
- [Kiến trúc luồng triển khai](#kiến-trúc-luồng-triển-khai)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)
- [Hoạt động của ArgoCD Application](#hoạt-động-của-argocd-application)
- [Luồng CI/CD với Jenkins](#luồng-cicd-với-jenkins)
- [Hướng dẫn sử dụng](#hướng-dẫn-sử-dụng)
- [Thêm service mới](#thêm-service-mới)
- [Troubleshooting](#troubleshooting)

---

## GitOps là gì và tại sao dùng

**GitOps** = vận hành infrastructure/application bằng Git làm nguồn sự thật duy nhất. Thay vì developer/CI chạy `kubectl apply` thẳng vào cluster (push-based), có một controller (ArgoCD) **pull** manifests từ Git và apply vào cluster.

### So sánh Push vs Pull

| Aspect | Push (kubectl apply từ CI) | Pull (GitOps/ArgoCD) |
|--------|---------------------------|----------------------|
| Quyền vào cluster | CI cần credential admin | Chỉ controller trong cluster cần |
| Drift detection | Không có | Tự phát hiện & self-heal |
| Rollback | Phải chạy lại pipeline | `git revert` + auto-sync |
| Audit trail | Log pipeline | Git history |
| Multi-cluster | Cấu hình nhiều credential | Một repo, nhiều cluster pull |

### Lợi ích cụ thể cho dự án

1. **Giảm bề mặt tấn công**: Jenkins Agent **không còn cần quyền `AmazonEKSClusterAdminPolicy`** — chỉ cần quyền push lên Git repo này.
2. **Lịch sử deploy rõ ràng**: Mọi thay đổi trên cluster đều có commit tương ứng, ai đổi, đổi gì, khi nào.
3. **Self-healing**: Nếu ai đó `kubectl edit` trực tiếp trên cluster, ArgoCD phát hiện drift và khôi phục về trạng thái trong Git.
4. **Rollback bằng `git revert`**: Không cần rebuild image, không cần chạy lại pipeline.

---

## Kiến trúc luồng triển khai

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

**Điểm cốt lõi**:
- Jenkins **không bao giờ** chạy `kubectl apply` — chỉ commit thay đổi vào Git.
- ArgoCD **không bao giờ** build image — chỉ pull manifest và đồng bộ.
- Image tag = Git commit SHA (truy vết 1-1 giữa code ↔ image ↔ deployment).

---

## Cấu trúc thư mục

```
retail-store-gitops/
├── README.md
│
├── apps/                           # Kubernetes manifests của từng service
│   └── ui/
│       ├── namespace.yml           #   Namespace: retail-store
│       ├── deployment.yml          #   Deployment (image tag được Jenkins cập nhật tự động)
│       └── service.yml             #   Service type LoadBalancer (expose public qua ELB)
│
└── argocd/                         # ArgoCD Application definitions
    └── ui-application.yml          #   ArgoCD Application: retail-store-ui
```

### Các service hiện tại

| Service | Manifest path | ArgoCD Application | Trạng thái |
|---------|---------------|--------------------|-----------|
| UI | `apps/ui/` | `retail-store-ui` | ✅ Hoạt động |
| Catalog | *(chưa có)* | *(chưa có)* | ⏳ Roadmap |
| Cart | *(chưa có)* | *(chưa có)* | ⏳ Roadmap |
| Orders | *(chưa có)* | *(chưa có)* | ⏳ Roadmap |
| Checkout | *(chưa có)* | *(chưa có)* | ⏳ Roadmap |

---

## Hoạt động của ArgoCD Application

File `argocd/ui-application.yml` định nghĩa một ArgoCD `Application` resource:

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
    path: apps/ui                    # Folder chứa manifest
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true                    # Xoá resource không còn trong Git
      selfHeal: true                 # Khôi phục nếu có ai sửa trực tiếp trên cluster
    syncOptions:
      - CreateNamespace=true         # Tự tạo namespace nếu chưa có
```

### Giải thích từng field

| Field | Ý nghĩa |
|-------|---------|
| `source.repoURL` | URL Git repo — ArgoCD pull từ đây |
| `source.targetRevision` | Branch/tag/commit để track, ở đây là `main` |
| `source.path` | Folder trong repo chứa manifest (không phải tên file cụ thể) |
| `destination.server` | `kubernetes.default.svc` = chính cluster nơi ArgoCD đang chạy |
| `destination.namespace` | Namespace đích để apply manifest |
| `syncPolicy.automated.prune` | Xoá K8s resource nếu file manifest bị xoá khỏi Git |
| `syncPolicy.automated.selfHeal` | Tự re-apply nếu state thực tế lệch state trong Git |
| `CreateNamespace=true` | ArgoCD tự `kubectl create ns` nếu chưa tồn tại |

### Cách áp dụng ArgoCD Application lần đầu

```bash
# Kết nối kubectl với EKS cluster
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Apply Application definition
kubectl apply -f argocd/ui-application.yml

# Kiểm tra
kubectl get application -n argocd
# NAME              SYNC STATUS   HEALTH STATUS
# retail-store-ui   Synced        Healthy
```

Sau bước này, ArgoCD sẽ **tự động** poll repo mỗi 3 phút (mặc định) và đồng bộ bất kỳ thay đổi nào.

---

## Luồng CI/CD với Jenkins

### Stage `Update GitOps` trong Jenkinsfile

Mỗi lần build thành công (ở repo `retail-store-microservices`), Jenkins chạy stage sau để cập nhật image tag:

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

                sed -i "s|image:.*retail-store/ui.*|image: $FULL_IMAGE|" apps/ui/deployment.yml

                git config user.email "jenkins@ci.local"
                git config user.name "Jenkins CI"
                git add apps/ui/deployment.yml
                git diff --staged --quiet || git commit -m "chore(ui): update image to $IMAGE_TAG"
                git push origin main
            '''
        }
    }
}
```

### Giải thích từng bước

| Bước | Mục đích |
|------|----------|
| `rm -rf gitops-repo` | Clean workspace cũ (tránh state leftover) |
| `git clone` với token | Clone repo qua HTTPS với PAT (không dùng SSH key) |
| `sed -i "s\|image:...\|"` | Thay dòng image cũ bằng image mới (tag = commit SHA) |
| `git diff --staged --quiet \|\|` | Chỉ commit nếu có thay đổi thực sự (idempotent) |
| `git push origin main` | Push thẳng lên main — ArgoCD sẽ detect trong vài phút |

### Credential cần setup trong Jenkins

**Credential ID: `github-gitops-token`**
- **Kind**: Username with password
- **Username**: GitHub username (ví dụ: `tranduyloc895`)
- **Password**: GitHub Fine-grained Personal Access Token

**Quyền token cần (nguyên tắc least-privilege)**:
| Permission | Access | Lý do |
|-----------|--------|-------|
| Contents | Read and write | `git clone` + `git push` |
| Metadata | Read (auto) | Bắt buộc |
| *(các quyền khác)* | — | **Không cấp** |

Repository selected: **Only `retail-store-gitops`** (không cấp toàn org).

---

## Hướng dẫn sử dụng

### Yêu cầu trước

- EKS cluster `ecommerce-cluster` đã chạy (module `02-cluster-eks` trong repo `infrastructure`)
- ArgoCD đã được cài qua Helm (cùng module)
- Repo này đã public hoặc ArgoCD đã được cấu hình credential

### Apply ArgoCD Application

```bash
# SSH vào Jenkins Agent (hoặc local đã update-kubeconfig)
aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1

# Apply
kubectl apply -f argocd/ui-application.yml

# Xem status
kubectl get application -n argocd retail-store-ui
```

### Truy cập ArgoCD UI

```bash
# Port-forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Lấy password admin ban đầu
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Mở browser: `https://localhost:8080` — username `admin`, password từ command trên.

### Cập nhật thủ công (không qua Jenkins)

Trong trường hợp cần deploy không qua CI (hotfix, test):

```bash
git clone https://github.com/tranduyloc895/retail-store-gitops.git
cd retail-store-gitops

# Sửa image tag trong apps/ui/deployment.yml
vim apps/ui/deployment.yml

git add apps/ui/deployment.yml
git commit -m "manual: update ui image to <tag>"
git push origin main
```

ArgoCD sẽ tự sync trong 3 phút, hoặc trigger sync ngay bằng:
```bash
kubectl patch application retail-store-ui -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Rollback

Cực kỳ đơn giản với GitOps — chỉ cần revert commit:

```bash
git revert <commit-hash-của-lần-deploy-lỗi>
git push origin main
```

ArgoCD sẽ tự apply version cũ trong vài phút.

---

## Thêm service mới

Roadmap hiện tại có 4 service chưa lên: catalog, cart, orders, checkout. Các bước để thêm một service (ví dụ: catalog):

### Bước 1: Tạo manifest

```bash
mkdir -p apps/catalog
```

Tạo 3 file:

**`apps/catalog/namespace.yml`** — có thể tái dùng namespace `retail-store`, nên bỏ qua nếu đã có.

**`apps/catalog/deployment.yml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  namespace: retail-store
spec:
  replicas: 2
  selector:
    matchLabels:
      app: catalog
  template:
    metadata:
      labels:
        app: catalog
    spec:
      containers:
        - name: catalog
          image: <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/retail-store/catalog:PLACEHOLDER
          ports:
            - containerPort: 8080
          # env, resources, probes...
```

**`apps/catalog/service.yml`** — có thể dùng `ClusterIP` vì service này chỉ gọi nội bộ từ UI:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: catalog
  namespace: retail-store
spec:
  type: ClusterIP
  selector:
    app: catalog
  ports:
    - port: 80
      targetPort: 8080
```

### Bước 2: Tạo ArgoCD Application

**`argocd/catalog-application.yml`**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-catalog
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/tranduyloc895/retail-store-gitops.git
    targetRevision: main
    path: apps/catalog
  destination:
    server: https://kubernetes.default.svc
    namespace: retail-store
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Bước 3: Tạo Jenkinsfile cho service

Trong `retail-store-microservices/src/catalog/Jenkinsfile`, copy từ UI Jenkinsfile và đổi:
- `ECR_REPO_NAME` = `retail-store/catalog`
- `sed` target path = `apps/catalog/deployment.yml`
- Regex pattern = `retail-store/catalog`

### Bước 4: Apply

```bash
git add apps/catalog/ argocd/catalog-application.yml
git commit -m "feat: onboard catalog service"
git push origin main

# Apply ArgoCD Application mới
kubectl apply -f argocd/catalog-application.yml
```

### (Tương lai) App of Apps pattern

Khi có nhiều service, thay vì `kubectl apply` từng Application, tạo một "root" Application quản lý tất cả:

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
    path: argocd                     # Folder chứa các Application con
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {}
```

Sau đó chỉ cần `kubectl apply -f argocd/root-app.yml` **một lần duy nhất** — mọi Application mới thêm vào folder `argocd/` sẽ được tự động onboard.

---

## Troubleshooting

### ArgoCD hiển thị `OutOfSync`
- **Nguyên nhân**: Manifest trong Git khác với state trên cluster.
- **Fix**: Kiểm tra tab `Diff` trong ArgoCD UI. Nếu expected behavior → đợi auto-sync (hoặc click `Sync` thủ công).

### ArgoCD hiển thị `Degraded` hoặc `Unhealthy`
- **Nguyên nhân**: Pod không start được (image pull error, crashloop, probe fail...).
- **Fix**:
  ```bash
  kubectl describe pod -n retail-store -l app=ui
  kubectl logs -n retail-store -l app=ui --tail=50
  ```

### Jenkins push thành công nhưng ArgoCD không sync
- **Nguyên nhân**: Polling mặc định 3 phút, hoặc ArgoCD không có webhook.
- **Fix tạm**: Trigger sync thủ công trong UI.
- **Fix dài hạn**: Cấu hình GitHub webhook → ArgoCD để sync tức thì (thêm webhook URL `https://<argocd-server>/api/webhook` trong GitHub repo settings).

### `sed` không thay được image trong pipeline
- **Nguyên nhân hay gặp**: Extension file không khớp (`.yml` vs `.yaml`).
- **Fix**: Kiểm tra extension thực tế của file trong repo này.

### Không biết URL của UI service
```bash
kubectl get svc ui -n retail-store -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
Nếu `<pending>` → đợi 2-4 phút cho AWS provision ELB.

---

## Liên kết repo

| Repo | Vai trò |
|------|---------|
| [infrastructure](https://github.com/tranduyloc895/infrastructure) | Terraform + Ansible: VPC, EKS, Jenkins, ECR |
| [retail-store-microservices](https://github.com/tranduyloc895/retail-store-microservices) | Source code 5 microservices + Jenkinsfile |
| **retail-store-gitops** (this repo) | Manifests K8s + ArgoCD Application |

---

> *Đồ án môn NT114 - Đại học Công nghệ Thông tin (UIT)*
