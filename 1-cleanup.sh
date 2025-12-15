#!/bin/bash
# Complete cleanup of JupyterHub, Longhorn, Security Profiles, and CVMFS installation
set -e

echo "=========================================="
echo "CLEANUP: Removing JupyterHub, Longhorn, Security, and CVMFS"
echo "=========================================="

# 1. Delete JupyterHub Helm release
echo "[1/9] Uninstalling JupyterHub Helm release..."
microk8s helm uninstall jupyterhub -n jupyter 2>/dev/null || echo "JupyterHub not found or already removed"

# 2. Delete all jupyter namespace resources
echo "[2/9] Deleting all resources in jupyter namespace..."
microk8s kubectl delete all --all -n jupyter --force --grace-period=0 2>/dev/null || true
microk8s kubectl delete pvc --all -n jupyter --force --grace-period=0 2>/dev/null || true
microk8s kubectl delete configmap --all -n jupyter 2>/dev/null || true
microk8s kubectl delete secret --all -n jupyter 2>/dev/null || true
microk8s kubectl delete daemonset --all -n jupyter --force --grace-period=0 2>/dev/null || true

# Wait for pods to terminate
echo "Waiting for jupyter pods to terminate..."
sleep 10

# 3. Delete jupyter namespace
echo "[3/9] Deleting jupyter namespace..."
microk8s kubectl delete namespace jupyter 2>/dev/null || echo "Namespace already deleted"

# 4. Remove Security Profiles Operator
echo "[4/9] Uninstalling Security Profiles Operator..."
microk8s helm uninstall security-profiles-operator -n security 2>/dev/null || echo "SPO not found or already removed"

# Delete security namespace resources
echo "Cleaning up security namespace resources..."
microk8s kubectl delete all --all -n security --force --grace-period=0 2>/dev/null || true

# Wait a bit
sleep 5

# 5. Delete security namespace
echo "[5/9] Deleting security namespace..."
microk8s kubectl delete namespace security 2>/dev/null || echo "Security namespace already deleted"

# Clean up cluster-scoped SPO resources
echo "Cleaning up cluster-scoped security resources..."

# Delete all SPO CRDs (this will cascade delete all CR instances)
microk8s kubectl get crd 2>/dev/null | grep 'security-profiles-operator.x-k8s.io' | awk '{print $1}' | xargs -r microk8s kubectl delete crd 2>/dev/null || true

# Delete ClusterRoles and ClusterRoleBindings
microk8s kubectl get clusterrole 2>/dev/null | grep -E "(spo-|security-profiles)" | awk '{print $1}' | xargs -r microk8s kubectl delete clusterrole 2>/dev/null || true
microk8s kubectl get clusterrolebinding 2>/dev/null | grep -E "(spo-|security-profiles)" | awk '{print $1}' | xargs -r microk8s kubectl delete clusterrolebinding 2>/dev/null || true

# Delete webhooks
microk8s kubectl delete mutatingwebhookconfiguration spo-mutating-webhook-configuration 2>/dev/null || true
microk8s kubectl delete validatingwebhookconfiguration spo-validating-webhook-configuration 2>/dev/null || true

# Delete any ServiceMonitors
microk8s kubectl delete servicemonitor -n security --all 2>/dev/null || true

# 6. Remove Longhorn
echo "[6/9] Uninstalling Longhorn..."
microk8s helm uninstall longhorn -n longhorn-system 2>/dev/null || echo "Longhorn not found or already removed"

# Wait for Longhorn to clean up
echo "Waiting for Longhorn resources to clean up..."
sleep 15

# Force delete Longhorn resources if stuck
microk8s kubectl delete namespace longhorn-system --force --grace-period=0 2>/dev/null || true

# 7. Clean up any orphaned PVs
echo "[7/9] Cleaning up orphaned PersistentVolumes..."
microk8s kubectl get pv | grep -E "jupyter|longhorn" | awk '{print $1}' | xargs -r microk8s kubectl delete pv 2>/dev/null || true

# 8. Complete CVMFS cleanup
echo "[8/9] Uninstalling CVMFS completely..."

# Delete CVMFS PVC first (prevents volume leak)
echo "  Deleting CVMFS PVC..."
microk8s kubectl delete pvc cvmfs -n jupyter --ignore-not-found=true 2>/dev/null || true

# Wait for PVC deletion
sleep 5

# Delete CVMFS PVs
echo "  Cleaning up CVMFS PVs..."
microk8s kubectl get pv 2>/dev/null | grep cvmfs | awk '{print $1}' | xargs -r microk8s kubectl delete pv --ignore-not-found=true 2>/dev/null || true

# Uninstall CVMFS CSI driver from both possible namespaces
echo "  Uninstalling CVMFS CSI driver..."
microk8s helm uninstall cvmfs-csi -n jupyter 2>/dev/null || true
microk8s helm uninstall cvmfs-csi -n cvmfs 2>/dev/null || true

# Uninstall smarter-device-manager
echo "  Uninstalling smarter-device-manager..."
microk8s helm uninstall smarter-device-manager -n jupyter 2>/dev/null || true

# Remove node labels
echo "  Removing node labels..."
microk8s kubectl get nodes -o name 2>/dev/null | while read node; do
  microk8s kubectl label $node smarter-device-manager- --overwrite 2>/dev/null || true
done

# Delete CVMFS StorageClass
echo "  Deleting CVMFS StorageClass..."
microk8s kubectl delete storageclass cvmfs --ignore-not-found=true 2>/dev/null || true

# Delete CVMFS namespaces
microk8s kubectl delete namespace cvmfs 2>/dev/null || true
microk8s kubectl delete namespace mounts 2>/dev/null || true

# Clean up CVMFS DaemonSet if exists
microk8s kubectl delete daemonset cvmfs-nodeplugin -n kube-system 2>/dev/null || true

# 9. Clean up CVMFS on nodes
echo "[9/9] Cleaning up CVMFS mounts and autofs..."
# Unmount CVMFS repositories
if mount | grep -q /cvmfs; then
    echo "  Unmounting CVMFS repositories..."
    sudo umount -l /cvmfs/* 2>/dev/null || true
    sudo umount -l /cvmfs 2>/dev/null || true
fi

# Clean up CVMFS cache and config
if [ -d /var/lib/cvmfs ]; then
    echo "  Removing CVMFS cache..."
    sudo rm -rf /var/lib/cvmfs/* 2>/dev/null || true
fi

# Remove AppArmor profiles loaded by SPO
if command -v aa-status >/dev/null 2>&1; then
    if sudo aa-status | grep -q notebook; then
        echo "  Removing AppArmor notebook profile..."
        echo "profile notebook {}" | sudo apparmor_parser -R 2>/dev/null || true
    fi
fi

echo ""
echo "=========================================="
echo "CLEANUP COMPLETE"
echo "=========================================="
echo ""
echo "Verify cleanup:"
echo "  microk8s kubectl get all -n jupyter"
echo "  microk8s kubectl get all -n security"
echo "  microk8s kubectl get all -n cvmfs"
echo "  microk8s kubectl get pvc -n jupyter"
echo "  microk8s kubectl get ns | grep -E 'jupyter|security|cvmfs|longhorn'"
echo "  microk8s helm list -A"
echo "  mount | grep cvmfs"
echo "  sudo aa-status | grep notebook"
echo ""


# -------- LONGHORN ULTRA-cleanup (MicroK8s, timeout-safe) --------
# Usage: uncomment the below section (from START) to run Longhorn cleanup
# Note: This is a more aggressive cleanup for Longhorn installations
# that may be stuck due to finalizers or other issues.
# -------------------- START --------------------

# echo "=========================================="
# echo "LONGHORN ULTRA-CLEANUP: Removing all Longhorn resources"
# echo "=========================================="


# # Set to your microk8s kubectl if not using MicroK8s:
# KCTL="${KCTL:-microk8s kubectl}"


# k() {
#   timeout 8s $KCTL --request-timeout=6s "$@" 2>/dev/null
# }

# echo ">>> Using KCTL='$KCTL'"
# $KCTL version >/dev/null 2>&1 || { echo "ERR: '$KCTL' not found/working. Set KCTL to your microk8s kubectl and retry."; exit 1; }

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



# # -------------------- END --------------------
