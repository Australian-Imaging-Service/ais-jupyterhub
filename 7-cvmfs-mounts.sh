#!/bin/bash
# 7-cvmfs-mounts.sh - Setup CVMFS for XNAT JupyterHub
set -e

echo "=========================================="
echo "Setting up CVMFS Mounts"
echo "=========================================="

# Create namespace for mounts
echo "[1/6] Creating mounts namespace..."
microk8s kubectl create namespace mounts --dry-run=client -o yaml | microk8s kubectl apply -f -

# Add CVMFS CSI Helm repository
echo "[2/6] Adding CVMFS CSI Helm repository..."
microk8s helm repo add cvmfs-csi https://registry.cern.ch/chartrepo/cern
microk8s helm repo add smarter-device-manager https://smarter-project.github.io/smarter-device-manager
microk8s helm repo update

# Label nodes for smarter-device-manager (enables /dev/fuse access)
echo "[3/6] Labeling nodes for device manager..."
microk8s kubectl get nodes -o name | while read node; do
  microk8s kubectl label $node smarter-device-manager=enabled --overwrite
done

# Install smarter-device-manager for /dev/fuse access
echo "[4/6] Installing smarter-device-manager..."
microk8s helm upgrade --install smarter-device-manager smarter-device-manager/smarter-device-manager \
  -n mounts \
  --set config[0].devicematch="^fuse$" \
  --set config[0].nummaxdevices=20 \
  --wait

# Install CVMFS CSI driver
echo "[5/6] Installing CVMFS CSI driver..."
microk8s helm upgrade --install cvmfs-csi cvmfs-csi/cvmfs-csi \
  -n mounts \
  -f cvmfs_mount/values.yaml \
  --set kubeletDirectory=/var/snap/microk8s/common/var/lib/kubelet \
  --wait

# Create CVMFS PVC in jupyter namespace
echo "[6/6] Creating CVMFS PVC..."
microk8s kubectl apply -f cvmfs_mount/pvc.yaml

echo ""
echo "✓ CVMFS setup completed successfully"
echo ""
echo "Verify installation:"
echo "  microk8s kubectl get pods -n mounts"
echo "  microk8s kubectl get pvc -n jupyter cvmfs"


