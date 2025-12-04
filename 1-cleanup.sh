#!/bin/bash
# Complete cleanup of existing JupyterHub and Longhorn installation (if any exists)
set -e

echo "=========================================="
echo "CLEANUP: Removing broken JupyterHub installation"
echo "=========================================="

# 1. Delete JupyterHub Helm release
echo "[1/6] Uninstalling JupyterHub Helm release..."
helm uninstall jupyterhub -n jupyter 2>/dev/null || echo "JupyterHub not found or already removed"

# 2. Delete all jupyter namespace resources
echo "[2/6] Deleting all resources in jupyter namespace..."
kubectl delete all --all -n jupyter --force --grace-period=0 2>/dev/null || true
kubectl delete pvc --all -n jupyter --force --grace-period=0 2>/dev/null || true
kubectl delete configmap --all -n jupyter 2>/dev/null || true
kubectl delete secret --all -n jupyter 2>/dev/null || true
kubectl delete daemonset --all -n jupyter --force --grace-period=0 2>/dev/null || true

# Wait for pods to terminate
echo "Waiting for jupyter pods to terminate..."
sleep 10

# 3. Delete jupyter namespace
echo "[3/6] Deleting jupyter namespace..."
kubectl delete namespace jupyter 2>/dev/null || echo "Namespace already deleted"

# 4. Remove Longhorn
echo "[4/6] Uninstalling Longhorn..."
helm uninstall longhorn -n longhorn-system 2>/dev/null || echo "Longhorn not found or already removed"

# Wait for Longhorn to clean up
echo "Waiting for Longhorn resources to clean up..."
sleep 15

# Force delete Longhorn resources if stuck
kubectl delete namespace longhorn-system --force --grace-period=0 2>/dev/null || true

# 5. Clean up any orphaned PVs
echo "[5/6] Cleaning up orphaned PersistentVolumes..."
kubectl get pv | grep -E "jupyter|longhorn" | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null || true

# 6. Clean up CVMFS remnants on nodes (if any)
echo "[6/6] Cleaning CVMFS mounts on nodes..."
# Note: This would require SSH to nodes in production
# For microk8s single-node, we can check locally
if [ -d /cvmfs ]; then
    echo "WARNING: /cvmfs directory exists on node. May need manual cleanup."
fi

echo ""
echo "=========================================="
echo "CLEANUP COMPLETE"
echo "=========================================="
echo ""
echo "Verify cleanup:"
echo "  kubectl get all -n jupyter"
echo "  kubectl get pvc -n jupyter"
echo "  kubectl get ns | grep jupyter"
echo "  helm list -A | grep -E 'jupyter|longhorn'"
echo ""


# -------- LONGHORN ULTRA-cleanup (MicroK8s, timeout-safe) --------
# Usage: uncomment the below section (from START) to run Longhorn cleanup
# Note: This is a more aggressive cleanup for Longhorn installations
# that may be stuck due to finalizers or other issues.
# -------------------- START --------------------

# echo "=========================================="
# echo "LONGHORN ULTRA-CLEANUP: Removing all Longhorn resources"
# echo "=========================================="


# # Set to your kubectl if not using MicroK8s:
# KCTL="${KCTL:-microk8s kubectl}"


# k() {
#   timeout 8s $KCTL --request-timeout=6s "$@" 2>/dev/null
# }

# echo ">>> Using KCTL='$KCTL'"
# $KCTL version >/dev/null 2>&1 || { echo "ERR: '$KCTL' not found/working. Set KCTL to your kubectl and retry."; exit 1; }

# echo ">>> [0] Unstick namespace (remove finalizers if present)"
# k get ns longhorn-system >/dev/null && \
#   $KCTL patch namespace longhorn-system --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true

# echo ">>> [1] Remove admission webhooks (prevents CR deletes from hanging)"
# k get mutatingwebhookconfiguration -o name | grep -i longhorn | xargs -r $KCTL delete >/dev/null 2>&1 || true
# k get validatingwebhookconfiguration -o name | grep -i longhorn | xargs -r $KCTL delete >/dev/null 2>&1 || true

# echo ">>> [2] Remove StorageClasses & CSIDriver"
# $KCTL delete sc longhorn longhorn-static --ignore-not-found >/dev/null 2>&1 || true
# $KCTL delete csidriver driver.longhorn.io --ignore-not-found >/dev/null 2>&1 || true

# echo ">>> [3] Delete any VolumeAttachments referencing Longhorn (best-effort)"
# k get volumeattachment -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.attacher}{"\n"}{end}' \
# | awk '$2 ~ /driver\.longhorn\.io/ {print $1}' \
# | xargs -r $KCTL delete volumeattachment >/dev/null 2>&1 || true

# echo ">>> [4] Delete all longhorn.io CRDs directly (garbage-collects their instances)"

# CRDS=$(k get crd -o name | grep -i 'longhorn\.io' || true)
# if [ -n "$CRDS" ]; then
#   echo "$CRDS" | xargs -r $KCTL delete --wait=false >/dev/null 2>&1 || true
# fi


# for attempt in 1 2 3 4 5; do
#   REM=$($KCTL get crd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.group}{"\n"}{end}' 2>/dev/null | awk '$2=="longhorn.io"{print $1}')
#   [ -z "$REM" ] && break
#   echo "    attempt $attempt: removing CRD finalizers & re-deleting"
#   echo "$REM" | xargs -r -I{} $KCTL patch crd {} --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
#   echo "$REM" | xargs -r $KCTL delete --wait=false >/dev/null 2>&1 || true
#   sleep 2
# done

# echo ">>> [5] Final namespace cleanup"
# if k get ns longhorn-system >/dev/null; then
#   $KCTL patch namespace longhorn-system --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
#   $KCTL delete namespace longhorn-system --ignore-not-found >/dev/null 2>&1 || true
# fi

# echo ">>> [6] Optional local-node cleanup (this node only)"
# if command -v iscsiadm >/dev/null 2>&1; then
#   iscsiadm -m session >/dev/null 2>&1 || true
# fi
# mount | grep -qi '/var/lib/longhorn' && sudo umount -lf /var/lib/longhorn 2>/dev/null || true
# sudo rm -rf /var/lib/longhorn 2>/dev/null || true

# echo ">>> Verification:"
# $KCTL get sc 2>/dev/null | grep -i longhorn || echo "no storageclasses"
# $KCTL get csidriver 2>/dev/null | grep -i longhorn || echo "no csidrivers"
# $KCTL get crd 2>/dev/null | grep -i longhorn || echo "no longhorn CRDs"
# $KCTL get ns longhorn-system >/dev/null 2>&1 || echo "namespace gone"
# echo ">>> Done."



# -------------------- END --------------------
