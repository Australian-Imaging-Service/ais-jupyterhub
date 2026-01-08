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

# Get absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/5-jupyterhub-secrets.yaml"
AGE_KEY_FILE="$SCRIPT_DIR/.keys/age-key.txt"

# Function to install JupyterHub with a specific method
install_jupyterhub() {
    local method=$1
    export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

    case $method in
        1)
            # Option 1: helm-secrets plugin
            if ! helm plugin list 2>/dev/null | grep -q "^secrets"; then
                echo "Installing helm-secrets plugin..."

                if ! helm plugin install https://github.com/jkroepke/helm-secrets 2>&1; then
                    echo ""
                    echo "ERROR: Failed to install helm-secrets plugin."
                    echo "This might be due to git/snap conflicts or network issues."
                    return 1
                fi
            fi

            # Verify plugin is installed
            if ! helm plugin list 2>/dev/null | grep -q "^secrets"; then
                echo "ERROR: helm-secrets plugin not available."
                return 1
            fi

            echo "Installing with helm-secrets plugin..."
            helm secrets install jupyterhub jupyterhub/jupyterhub \
              --namespace jupyter \
              --version 4.3.1 \
              --values "$SCRIPT_DIR/5-jupyterhub-values.yaml" \
              --values "secrets://$SECRETS_FILE" \
              --timeout 10m
            return $?
            ;;

        2)
            # Option 2: Manual decryption
            echo "Decrypting secrets to temporary file..."
            TEMP_SECRETS=$(mktemp)

            if ! sops -d "$SECRETS_FILE" > "$TEMP_SECRETS" 2>&1; then
                echo "ERROR: Failed to decrypt secrets."
                rm -f "$TEMP_SECRETS"
                return 1
            fi

            echo "Installing with decrypted secrets..."
            helm install jupyterhub jupyterhub/jupyterhub \
              --namespace jupyter \
              --version 4.3.1 \
              --values "$SCRIPT_DIR/5-jupyterhub-values.yaml" \
              --values "$TEMP_SECRETS" \
              --timeout 10m

            local result=$?
            rm -f "$TEMP_SECRETS"

            if [ $result -eq 0 ]; then
                echo "Cleaned up temporary secrets file"
            fi

            return $result
            ;;

        3)
            # Option 3: Values file only
            echo "Installing with values file only..."
            echo "WARNING: Ensure 5-jupyterhub-values.yaml contains all required secrets!"
            helm install jupyterhub jupyterhub/jupyterhub \
              --namespace jupyter \
              --version 4.3.1 \
              --values "$SCRIPT_DIR/5-jupyterhub-values.yaml" \
              --timeout 10m
            return $?
            ;;
    esac
}

# Check if SOPS is available and secrets file exists
if command -v sops &> /dev/null && [ -f "$SECRETS_FILE" ] && [ -f "$AGE_KEY_FILE" ]; then
    ATTEMPT=0
    MAX_ATTEMPTS=3
    SUCCESS=false

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ] && [ "$SUCCESS" = false ]; do
        ATTEMPT=$((ATTEMPT + 1))

        echo ""
        echo "SOPS encrypted secrets detected!"
        if [ $ATTEMPT -gt 1 ]; then
            echo "Attempt $ATTEMPT of $MAX_ATTEMPTS"
        fi
        echo ""
        echo "Choose installation method:"
        echo "  1) helm-secrets plugin with secrets:// (installs plugin if needed)"
        echo "  2) Manual decryption to temp file (recommended if option 1 fails)"
        echo "  3) Values file only (skip encrypted secrets)"
        echo ""
        read -p "Enter choice (1, 2, or 3): " choice

        if install_jupyterhub "$choice"; then
            SUCCESS=true
            echo ""
            echo "✓ Installation successful!"
        else
            echo ""
            echo "✗ Installation failed!"

            if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
                echo ""
                echo "Would you like to try a different method?"
                read -p "Try again? (y/n): " retry

                if [ "$retry" != "y" ] && [ "$retry" != "Y" ]; then
                    echo "Installation aborted by user."
                    exit 1
                fi
            else
                echo ""
                echo "Maximum attempts reached. Installation failed."
                echo ""
                echo "Troubleshooting tips:"
                echo "  - Option 1 fails: Usually git/snap conflicts - try Option 2"
                echo "  - Option 2 fails: Check SOPS_AGE_KEY_FILE and age key"
                echo "  - Option 3 fails: Ensure secrets are in 5-jupyterhub-values.yaml"
                exit 1
            fi
        fi
    done

    if [ "$SUCCESS" = false ]; then
        exit 1
    fi
else
    echo ""
    echo "SOPS not configured or secrets missing."
    echo "Installing with values file only..."
    echo ""

    if ! helm install jupyterhub jupyterhub/jupyterhub \
      --namespace jupyter \
      --version 4.3.1 \
      --values "$SCRIPT_DIR/5-jupyterhub-values.yaml" \
      --timeout 10m; then
        echo ""
        echo "Installation failed!"
        exit 1
    fi
fi

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
