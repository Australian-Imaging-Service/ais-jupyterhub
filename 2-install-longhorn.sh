#!/bin/bash
# Install Longhorn for JupyterHub persistent storage
set -e

echo "=========================================="
echo "STEP 1: Installing Longhorn"
echo "=========================================="

# Add Longhorn Helm repo
echo "[1/4] Adding Longhorn Helm repository..."
microk8s helm repo add longhorn https://charts.longhorn.io
microk8s helm repo update

# Create namespace
echo "[2/4] Creating longhorn-system namespace..."
microk8s kubectl create namespace longhorn-system 2>/dev/null || echo "Namespace already exists"

# Install Longhorn with microk8s-specific settings
echo "[3/4] Installing Longhorn..."
microk8s helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath="/var/snap/microk8s/common/var/lib/longhorn" \
  --set csi.kubeletRootDir="/var/snap/microk8s/common/var/lib/kubelet" \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=1 \
  --set defaultSettings.replicaAutoBalance="least-effort"

# Wait for Longhorn to be ready
echo "[4/4] Waiting for Longhorn to be ready..."
microk8s kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=300s
microk8s kubectl wait --for=condition=ready pod -l app=longhorn-driver-deployer -n longhorn-system --timeout=300s

echo ""
echo "=========================================="
echo "Longhorn Installation Complete"
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  microk8s kubectl get pods -n longhorn-system"
echo "  microk8s kubectl get storageclass"
echo ""
echo "Longhorn UI (if ingress enabled):"
echo "  microk8s kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Access at: http://localhost:8080"
echo ""
