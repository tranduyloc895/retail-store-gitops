```powershell
# bootstrap.ps1 — One-shot setup for a fresh EKS cluster (Windows PowerShell)

$ErrorActionPreference = "Stop"

Write-Host "==> [1/4] Waiting for ArgoCD CRDs to be established..."
kubectl wait `
  --for=condition=Established `
  crd/applications.argoproj.io `
  --timeout=120s

Write-Host "==> [2/4] Waiting for ArgoCD server deployment to be Available..."
kubectl -n argocd wait `
  --for=condition=Available `
  deployment/argocd-server `
  --timeout=180s

Write-Host "==> [3/4] Creating monitoring namespace (idempotent)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

Write-Host "==> [3/4] Creating Grafana admin secret (skipped if it already exists)..."

$secretExists = kubectl -n monitoring get secret grafana-admin 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "    Secret 'grafana-admin' already exists — skipping creation."
}
else {
    # Generate random 24-character password
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $password = -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

    kubectl -n monitoring create secret generic grafana-admin `
      --from-literal=admin-user=admin `
      --from-literal=admin-password="$password"

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗"
    Write-Host "  ║  Grafana admin password: $password"
    Write-Host "  ║  SAVE THIS NOW — it will not be shown again."
    Write-Host "  ╚══════════════════════════════════════════════════════════╝"
    Write-Host ""
}

Write-Host "==> [4/4] Applying root Application (App-of-Apps)..."
kubectl apply -f argocd/root-application.yml

Write-Host ""
Write-Host "Bootstrap complete. ArgoCD is now syncing all Applications."
Write-Host "Track progress:"
Write-Host "  kubectl get applications -n argocd -w"
```
