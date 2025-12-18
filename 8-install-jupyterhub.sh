#!/bin/bash
# Install JupyterHub with XNAT integration
set -e

echo "=========================================="
echo "STEP 2: Installing JupyterHub"
echo "=========================================="

# Create jupyter namespace
echo "[1/5] Creating jupyter namespace..."
kubectl create namespace jupyter 2>/dev/null || echo "Namespace already exists"

# Apply NFS PVs and PVCs
echo "[2/5] Creating NFS PersistentVolumes and Claims..."
kubectl apply -f 3-nfs-pv.yaml
kubectl apply -f 4-nfs-pvc.yaml

# Wait for PVCs to bind
echo "Waiting for PVCs to bind..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/xnat-gpfs -n jupyter --timeout=60s

# Add JupyterHub Helm repo
echo "[3/5] Adding JupyterHub Helm repository..."
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

# Install JupyterHub
echo "[4/5] Installing JupyterHub..."
helm install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --version 4.3.1 \
  --values 5-jupyterhub-values.yaml \
  --timeout 10m

# Wait for JupyterHub to be ready
echo "[5/5] Waiting for JupyterHub pods to be ready..."
kubectl wait --for=condition=ready pod -l app=jupyterhub -n jupyter --timeout=300s
kubectl wait --for=condition=ready pod -l component=hub -n jupyter --timeout=300s
kubectl wait --for=condition=ready pod -l component=proxy -n jupyter --timeout=300s

echo ""
echo "=========================================="
echo "JupyterHub Installation Complete"
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  kubectl get pods -n jupyter"
echo "  kubectl get svc -n jupyter"
echo "  kubectl get pvc -n jupyter"
echo ""
echo "JupyterHub URLs:"
echo "  External: http://xnat-test.ssdsorg.cloud.edu.au/jupyter"
echo "  Internal API: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
echo ""
echo "XNAT Plugin Configuration:"
echo "  JupyterHub host URL: http://xnat-test.ssdsorg.cloud.edu.au/"
echo "  JupyterHub API URL: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
echo "  Service Token: <jupyter-token>"
echo "  Note: Update XNAT's config to match your domain and token (its nice to generate a new token for a new deployement)."
echo ""
