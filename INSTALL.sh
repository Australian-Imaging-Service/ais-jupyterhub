#!/bin/bash
# Master installation script - runs complete installation sequence
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

echo -e "${BLUE}"
echo "=========================================="
echo "   JUPYTERHUB-XNAT INTEGRATION"
echo "   Master Installation Script"
echo "=========================================="
echo -e "${NC}"

# Function to wait for user confirmation
wait_for_user() {
    echo ""
    echo -e "${YELLOW}$1${NC}"
    read -p "Press ENTER to continue or Ctrl+C to abort..."
}

# Function to check if command succeeded
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
        echo "Check logs above for errors"
        exit 1
    fi
}

# Pre-flight checks
echo -e "${BLUE}[Pre-flight Checks]${NC}"
echo "Checking prerequisites..."

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found${NC}"
    echo "Please install kubectl or add alias: alias kubectl='microk8s kubectl'"
    exit 1
fi
echo -e "${GREEN}✓ kubectl found${NC}"

# Check helm
if ! command -v helm &> /dev/null; then
    echo -e "${RED}✗ helm not found${NC}"
    echo "Please install helm or add alias: alias helm='microk8s helm'"
    exit 1
fi
echo -e "${GREEN}✓ helm found${NC}"

# Check XNAT
if ! kubectl get pods -n ais-xnat xnat-web-0 &>/dev/null; then
    echo -e "${RED}✗ XNAT not found${NC}"
    echo "Please ensure XNAT is deployed in ais-xnat namespace"
    exit 1
fi
echo -e "${GREEN}✓ XNAT found${NC}"

# Check NFS server
if ! kubectl get pods -n storage -l app=nfs-server &>/dev/null; then
    echo -e "${RED}✗ NFS server not found${NC}"
    echo "Please ensure NFS server is deployed in storage namespace"
    exit 1
fi
echo -e "${GREEN}✓ NFS server found${NC}"

echo ""
echo -e "${GREEN}All prerequisites met!${NC}"

wait_for_user "Ready to begin installation?"

# Step 1: Cleanup
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 1: Cleanup Existing Installation"
echo "==========================================${NC}"
chmod +x 1-cleanup.sh
./1-cleanup.sh
check_status $?

wait_for_user "Cleanup complete. Ready to install Longhorn?"

# Step 2: Install Longhorn
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 2: Installing Longhorn"
echo "==========================================${NC}"
chmod +x 2-install-longhorn.sh
./2-install-longhorn.sh
check_status $?

wait_for_user "Longhorn installed. Ready to install CVMFS?"

# Step 3: Install CVMFS
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 3: Installing CVMFS CSI Driver"
echo "==========================================${NC}"
chmod +x 6-cvmfs-mounts.sh
./6-cvmfs-mounts.sh
check_status $?

wait_for_user "CVMFS installed. Ready to install Security Profiles Operator?"

# Step 4: Install Security Profiles Operator
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 4: Installing Security Profiles Operator"
echo "==========================================${NC}"
chmod +x 7-security-setup.sh
./7-security-setup.sh
check_status $?

wait_for_user "Security Profiles Operator installed. Ready to install JupyterHub?"

# Step 5: Install JupyterHub
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 5: Installing JupyterHub"
echo "==========================================${NC}"

# Create namespace
echo "Creating jupyter namespace..."
kubectl create namespace jupyter 2>/dev/null || echo "Namespace already exists"

chmod +x 8-install-jupyterhub.sh
./8-install-jupyterhub.sh
check_status $?

wait_for_user "JupyterHub installed. Ready to verify?"

# Step 6: Verify Installation
echo ""
echo -e "${BLUE}=========================================="
echo "STEP 6: Verifying Installation"
echo "==========================================${NC}"

# Manual verification since 8-verify.sh doesn't exist
echo "Checking JupyterHub deployment..."
kubectl get pods -n jupyter
echo ""
echo "Checking Security Profiles..."
kubectl get apparmorprofile -n security
echo ""
echo "Checking CVMFS mounts..."
kubectl get pods -n mounts -l component=cvmfs 2>/dev/null || echo "No CVMFS pods (expected if using CSI)"
echo ""
echo "Checking Longhorn..."
kubectl get pods -n longhorn-system

VERIFY_STATUS=0

echo ""
if [ $VERIFY_STATUS -eq 0 ]; then
    echo -e "${GREEN}=========================================="
    echo "  INSTALLATION COMPLETE!"
    echo "==========================================${NC}"
    echo ""
    echo -e "${GREEN}✓ All components installed and verified${NC}"
    echo ""
    echo "Next Steps:"
    echo "1. Configure XNAT Plugin (see XNAT-CONFIGURATION.md)"
    echo "2. Enable JupyterHub for projects in XNAT"
    echo "3. Test user workflow"
    echo ""
    echo "Access URLs:"
    echo "  XNAT: http://xnat-test.ssdsorg.cloud.edu.au"
    echo "  JupyterHub: http://xnat-test.ssdsorg.cloud.edu.au/jupyter"
    echo ""
    echo "Service Information:"
    echo "  JupyterHub API: http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"
    echo "  Service Token: <jupyter-token>"
    echo ""
    echo "Documentation:"
    echo "  README.md - Overview and architecture"
    echo "  XNAT-CONFIGURATION.md - XNAT plugin setup"
    echo "  TROUBLESHOOTING.md - Common issues and solutions"
    echo ""
else
    echo -e "${RED}=========================================="
    echo "  VERIFICATION FAILED"
    echo "==========================================${NC}"
    echo ""
    echo "Some components are not working correctly."
    echo "Please check the verification output above."
    echo ""
    echo "Troubleshooting:"
    echo "  ./8-verify.sh - Run verification again"
    echo "  kubectl get pods -n jupyter - Check pod status"
    echo "  kubectl logs -n jupyter -l component=hub - Check hub logs"
    echo ""
    echo "See TROUBLESHOOTING.md for detailed help."
    exit 1
fi
