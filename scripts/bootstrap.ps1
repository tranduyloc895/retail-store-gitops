# bootstrap.ps1 — One-shot setup for a fresh EKS cluster (Windows PowerShell)

$ErrorActionPreference = "Stop"

# Resolve repo root (tránh lỗi path khi chạy từ scripts/)
$repoRoot = Resolve-Path "$PSScriptRoot\.."

Write-Host "==> [1/5] Waiting for ArgoCD CRDs..."
kubectl wait `
  --for=condition=Established `
  crd/applications.argoproj.io `
  --timeout=120s

Write-Host "==> [2/5] Waiting for ArgoCD server..."
kubectl -n argocd wait `
  --for=condition=Available `
  deployment/argocd-server `
  --timeout=180s

Write-Host "==> [3/5] Creating monitoring namespace (idempotent)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

Write-Host "==> [4/5] Ensuring Grafana admin secret..."

# Lấy secret (nếu có)
$secret = kubectl -n monitoring get secret grafana-admin --ignore-not-found

if ($secret) {
    Write-Host "Secret 'grafana-admin' already exists."

    # Lấy password từ secret
    $encoded = kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}"

    if ($encoded) {
        $password = [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String($encoded)
        )

        Write-Host ""
        Write-Host "=============================================="
        Write-Host "Grafana admin password (existing): $password"
        Write-Host "=============================================="
        Write-Host ""
    }
    else {
        Write-Host "Warning: Secret exists but password field is empty."
    }
}
else {
    Write-Host "Secret not found. Creating new one..."

    # Generate random 24-character password
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $password = -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

    kubectl -n monitoring create secret generic grafana-admin `
      --from-literal=admin-user=admin `
      --from-literal=admin-password="$password"

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "Grafana admin password (new): $password"
    Write-Host "SAVE THIS NOW - it will not be shown again."
    Write-Host "=============================================="
    Write-Host ""
}

Write-Host "==> [5/5] Applying root Application (App-of-Apps)..."
kubectl apply -f "$repoRoot\argocd\root-application.yml"

Write-Host ""
Write-Host "Bootstrap complete."
Write-Host "Track progress:"
Write-Host "kubectl get applications -n argocd -w"