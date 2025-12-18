#!/bin/bash
# 7-cvmfs-mounts.sh - Setup CVMFS for XNAT JupyterHub
set -e

echo "=========================================="
echo "Setting up CVMFS Mounts"
echo "=========================================="

# Create namespace for mounts
echo "[1/6] Creating mounts and jupyter namespace..."
kubectl create namespace mounts --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace jupyter 2>/dev/null || echo "Namespace already exists"

# Add CVMFS CSI Helm repository
echo "[2/6] Adding CVMFS CSI Helm repository..."
helm repo add cvmfs-csi https://registry.cern.ch/chartrepo/cern
helm repo add smarter-device-manager https://smarter-project.github.io/smarter-device-manager
helm repo update

# Label nodes for smarter-device-manager (enables /dev/fuse access)
echo "[3/6] Labeling nodes for device manager..."
kubectl get nodes -o name | while read node; do
  kubectl label $node smarter-device-manager=enabled --overwrite
done

# Install smarter-device-manager for /dev/fuse access
echo "[4/6] Installing smarter-device-manager..."
helm upgrade --install smarter-device-manager smarter-device-manager/smarter-device-manager \
  -n mounts \
  --set config[0].devicematch="^fuse$" \
  --set config[0].nummaxdevices=20 \
  --wait

# Install CVMFS CSI driver
echo "[5/6] Installing CVMFS CSI driver..."
helm upgrade --install cvmfs-csi cvmfs-csi/cvmfs-csi \
  -n mounts \
  -f cvmfs_mount/values.yaml \
  --wait
  # --set kubeletDirectory=/var/snap/microk8s/common/var/lib/kubelet \
  # --wait

# Create CVMFS PVC in jupyter namespace
echo "[6/6] Creating CVMFS PVC..."
kubectl apply -f cvmfs_mount/pvc.yaml

echo ""
echo "✓ CVMFS setup completed successfully"
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n mounts"
echo "  kubectl get pvc -n jupyter cvmfs"


