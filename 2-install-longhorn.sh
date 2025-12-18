#!/bin/bash
# Install Longhorn for JupyterHub persistent storage
set -e

echo "=========================================="
echo "STEP 1: Installing Longhorn"
echo "=========================================="

# Add Longhorn Helm repo
echo "[1/4] Adding Longhorn Helm repository..."
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Create namespace
echo "[2/4] Creating longhorn-system namespace..."
kubectl create namespace longhorn-system 2>/dev/null || echo "Namespace already exists"

# Install Longhorn with microk8s-specific settings
echo "[3/4] Installing Longhorn..."
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set defaultSettings.defaultDataPath="/var/snap/microk8s/common/var/lib/longhorn" \
  --set csi.kubeletRootDir="/var/snap/microk8s/common/var/lib/kubelet" \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=1 \
  --set defaultSettings.replicaAutoBalance="least-effort"

# Wait for Longhorn to be ready
echo "[4/4] Waiting for Longhorn to be ready..."
kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=300s
kubectl wait --for=condition=ready pod -l app=longhorn-driver-deployer -n longhorn-system --timeout=300s

# Apply BackupTarget configuration
echo "Configuring Longhorn backup target..."
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: ""
  credentialSecret: ""
  pollInterval: "300s"
EOF

# Wait for BackupTarget to be created
echo "Waiting for BackupTarget to be ready..."
kubectl wait --for=jsonpath='{.status.available}'=true \
  backuptarget/default -n longhorn-system --timeout=60s 2>/dev/null || echo "BackupTarget created"

# Restart Longhorn Manager to pick up the configuration
echo "Restarting Longhorn manager..."
kubectl rollout restart daemonset longhorn-manager -n longhorn-system

# Wait for rollout to complete
kubectl rollout status daemonset longhorn-manager -n longhorn-system --timeout=300s

echo ""
echo "=========================================="
echo "Longhorn Installation Complete"
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n longhorn-system"
echo "  kubectl get storageclass"
echo ""
echo "Longhorn UI (if ingress enabled):"
echo "  kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Access at: http://localhost:8080"
echo ""
