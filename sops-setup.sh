#!/bin/bash
# SOPS Setup Script - First-time installation and configuration
# This script installs SOPS, age, and sets up encryption for secrets

set -e

echo "=========================================="
echo "SOPS Setup for JupyterHub Secrets"
echo "=========================================="
echo ""

# Check if running in the correct directory
if [ ! -f "5-jupyterhub-values.yaml" ]; then
    echo "ERROR: Must run from ais-jupyterhub repository root"
    exit 1
fi

# Function to install SOPS
install_sops() {
    if command -v sops &> /dev/null; then
        echo "✓ SOPS already installed: $(sops --version | head -1)"
        return 0
    fi

    echo "Installing SOPS..."
    SOPS_VERSION="3.8.1"
    ARCH=$(uname -m)

    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    fi

    curl -LO "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}"
    chmod +x "sops-v${SOPS_VERSION}.linux.${ARCH}"
    sudo mv "sops-v${SOPS_VERSION}.linux.${ARCH}" /usr/local/bin/sops
    echo "✓ SOPS installed successfully"
}

# Function to install age
install_age() {
    if command -v age &> /dev/null && command -v age-keygen &> /dev/null; then
        echo "✓ age already installed: $(age --version 2>&1 | head -1)"
        return 0
    fi

    echo "Installing age..."
    AGE_VERSION="1.1.1"
    ARCH=$(uname -m)

    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    fi

    curl -LO "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH}.tar.gz"
    tar xzf "age-v${AGE_VERSION}-linux-${ARCH}.tar.gz"
    sudo mv age/age age/age-keygen /usr/local/bin/
    rm -rf age "age-v${AGE_VERSION}-linux-${ARCH}.tar.gz"
    echo "✓ age installed successfully"
}

# Function to setup age key
setup_age_key() {
    mkdir -p .keys

    if [ -f ".keys/age-key.txt" ]; then
        echo "✓ Age key already exists"
        echo ""
        echo "Current public key:"
        grep "public key:" .keys/age-key.txt || echo "Unable to read public key"
        echo ""
        read -p "Generate a new key? This will backup the old one. (yes/no): " confirm

        if [ "$confirm" != "yes" ]; then
            echo "Keeping existing key."
            return 0
        fi

        # Backup old key
        cp .keys/age-key.txt ".keys/age-key.txt.backup.$(date +%Y%m%d-%H%M%S)"
        echo "✓ Backed up existing key"
    fi

    echo "Generating new age encryption key..."
    age-keygen -o .keys/age-key.txt
    chmod 600 .keys/age-key.txt

    echo ""
    echo "✓ Age key generated and saved to .keys/age-key.txt"
    echo ""
    echo "IMPORTANT: Share this key with your team members securely!"
    echo "=========================================="
    cat .keys/age-key.txt
    echo "=========================================="
    echo ""
}

# Function to update .sops.yaml with correct public key
update_sops_config() {
    if [ ! -f ".keys/age-key.txt" ]; then
        echo "ERROR: Age key not found"
        exit 1
    fi

    # Extract public key
    PUBLIC_KEY=$(grep "public key:" .keys/age-key.txt | awk '{print $4}')

    if [ -z "$PUBLIC_KEY" ]; then
        echo "ERROR: Could not extract public key from .keys/age-key.txt"
        exit 1
    fi

    echo "Updating .sops.yaml with public key: $PUBLIC_KEY"

    cat > .sops.yaml << EOF
# SOPS configuration file
# Defines which files should be encrypted and with which key

creation_rules:
  # Encrypt secrets files with age
  - path_regex: .*secrets\.yaml$
    age: $PUBLIC_KEY
    # Only encrypt values containing these patterns (case insensitive)
    encrypted_regex: (client_secret|apiToken|password|secret|key|token|SECRET|PASSWORD|KEY|TOKEN|CRYPT|crypt)

  # Encrypt any file with .enc.yaml extension
  - path_regex: .*\.enc\.yaml$
    age: $PUBLIC_KEY
    encrypted_regex: (client_secret|apiToken|password|secret|key|token|SECRET|PASSWORD|KEY|TOKEN|CRYPT|crypt)
EOF

    echo "✓ .sops.yaml configured"
}

# Function to setup gitignore
setup_gitignore() {
    if [ ! -f .gitignore ]; then
        touch .gitignore
    fi

    if ! grep -q "^.keys/" .gitignore; then
        echo "" >> .gitignore
        echo "# SOPS encryption keys - DO NOT COMMIT" >> .gitignore
        echo ".keys/" >> .gitignore
        echo "*.dec.yaml" >> .gitignore
        echo "✓ Updated .gitignore"
    else
        echo "✓ .gitignore already configured"
    fi
}

# Function to make helper scripts executable
setup_helpers() {
    if [ -f "sops-helper.sh" ]; then
        chmod +x sops-helper.sh
        echo "✓ Made sops-helper.sh executable"
    fi
}

# Main installation flow
echo "Step 1: Installing SOPS..."
install_sops
echo ""

echo "Step 2: Installing age..."
install_age
echo ""

echo "Step 3: Setting up age encryption key..."
setup_age_key
echo ""

echo "Step 4: Configuring SOPS..."
update_sops_config
echo ""

echo "Step 5: Configuring .gitignore..."
setup_gitignore
echo ""

echo "Step 6: Setting up helper scripts..."
setup_helpers
echo ""

echo "=========================================="
echo "✓ SOPS Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Edit your secrets:"
echo "   ./sops-helper.sh edit"
echo ""
echo "2. Or generate fresh random secrets:"
echo "   ./sops-helper.sh generate"
echo ""
echo "3. Share .keys/age-key.txt securely with team members"
echo "   (via password manager, encrypted email, or secure vault)"
echo ""
echo "4. Commit encrypted files to git:"
echo "   git add .sops.yaml 5-jupyterhub-secrets.yaml sops-*.sh"
echo "   git add .gitignore"
echo "   git commit -m 'Add SOPS encryption for secrets'"
echo ""
echo "Files to COMMIT to git:"
echo "  ✓ .sops.yaml"
echo "  ✓ 5-jupyterhub-secrets.yaml (encrypted)"
echo "  ✓ sops-helper.sh"
echo "  ✓ sops-setup.sh"
echo "  ✓ .gitignore"
echo ""
echo "Files to NEVER commit:"
echo "  ✗ .keys/ directory (private keys)"
echo "  ✗ *.dec.yaml files (decrypted secrets)"
echo ""
