#!/bin/bash
set -e

echo "=========================================="
echo "Setting up Security Profiles"
echo "=========================================="

# Create security namespace
echo "[1/5] Creating security namespace..."
kubectl apply -f security/namespace.yaml

# Install security-profiles-operator using Helm (neurodesk fork with abstract support)
echo "[2/5] Installing security-profiles-operator (neurodesk fork with Helm)..."
echo "Note: Using neurodesk fork which supports 'spec.abstract' API and AppArmor"

# Clone the neurodesk branch temporarily
TEMP_DIR=$(mktemp -d)
cd $TEMP_DIR
git clone --depth 1 --branch neurodesk https://github.com/Edan-Hamilton/security-profiles-operator.git
cd security-profiles-operator

# Install using Helm with AppArmor enabled
echo "Installing with Helm (enableAppArmor=true)..."
helm install security-profiles-operator ./deploy/helm \
  --namespace security \
  --set enableAppArmor=true \
  --set replicaCount=1

# Cleanup temp directory
cd -
rm -rf $TEMP_DIR

# Wait for operator to be ready
echo "[3/5] Waiting for operator..."
sleep 15
kubectl wait --for=condition=ready pod \
  -l app=security-profiles-operator -n security --timeout=300s

# Patch spod daemonset for MicroK8s kubelet path
echo "[4/5] Patching spod for MicroK8s..."
kubectl patch daemonset spod -n security --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/initContainers/0/env/1/value",
    "value": "/var/snap/microk8s/common/var/lib/kubelet"
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/env/3/value",
    "value": "/var/snap/microk8s/common/var/lib/kubelet"
  }
]'

# Wait for spod to be ready
echo "Waiting for spod to be ready..."
kubectl wait --for=condition=ready pod -l name=spod -n security --timeout=300s

# Apply AppArmor profile
echo "[5/5] Creating AppArmor profile..."
kubectl apply -f security/apparmor-profile.yaml

echo ""
echo "✅ Security profiles setup completed"
echo ""
echo "Verify:"
echo "  kubectl get pods -n security"
echo "  kubectl get apparmorprofile -n security"