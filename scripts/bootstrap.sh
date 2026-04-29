#!/usr/bin/env bash
# bootstrap.sh — One-shot setup for a fresh EKS cluster.
#
# Run once after `terraform apply` on 02-cluster-eks completes:
#   aws eks update-kubeconfig --name ecommerce-cluster --region ap-southeast-1
#   bash scripts/bootstrap.sh
#
# What this script does:
#   1. Waits for ArgoCD CRDs + server to be Ready.
#   2. Creates the `monitoring` namespace (idempotent).
#   3. Creates the `grafana-admin` secret with a random password (only if absent).
#   4. Applies argocd/root-application.yml (App-of-Apps root).
#
# After the script exits, ArgoCD syncs all Applications automatically.

set -euo pipefail

echo "==> [1/4] Waiting for ArgoCD CRDs to be established..."
kubectl wait \
  --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=120s

echo "==> [2/4] Waiting for ArgoCD server deployment to be Available..."
kubectl -n argocd wait \
  --for=condition=Available \
  deployment/argocd-server \
  --timeout=180s

echo "==> [3/4] Creating monitoring namespace (idempotent)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "==> [3/4] Creating Grafana admin secret (skipped if it already exists)..."
if kubectl -n monitoring get secret grafana-admin &>/dev/null; then
  echo "    Secret 'grafana-admin' already exists — skipping creation."
else
  PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${PASSWORD}"
  echo ""
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║  Grafana admin password: ${PASSWORD}  ║"
  echo "  ║  SAVE THIS NOW — it will not be shown again.             ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo ""
fi

echo "==> [4/4] Applying root Application (App-of-Apps)..."
kubectl apply -f argocd/root-application.yml

echo ""
echo "Bootstrap complete. ArgoCD is now syncing all Applications."
echo "Track progress:"
echo "  kubectl get applications -n argocd -w"
