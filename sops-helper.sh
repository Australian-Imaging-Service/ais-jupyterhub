#!/bin/bash
# SOPS Helper Script - Simplified secrets management
# Usage: ./sops-helper.sh <command>

set -e

SECRETS_FILE="5-jupyterhub-secrets.yaml"
AGE_KEY_FILE=".keys/age-key.txt"

# Check if age key exists
check_key() {
    if [ ! -f "$AGE_KEY_FILE" ]; then
        echo "ERROR: Age key not found at $AGE_KEY_FILE"
        echo ""
        echo "Solutions:"
        echo "  1. For new setup: Run ./sops-setup.sh"
        echo "  2. For existing team: Get the key from your team lead and save to $AGE_KEY_FILE"
        echo ""
        exit 1
    fi
}

# View secrets in plain text (read-only)
view_secrets() {
    check_key
    echo "Viewing secrets from $SECRETS_FILE (read-only)..."
    echo "=================================================="

    if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d "$SECRETS_FILE" 2>/dev/null; then
        echo ""
        echo "ERROR: Cannot decrypt secrets!"
        echo ""
        echo "This usually means:"
        echo "  1. The secrets file was encrypted with a DIFFERENT key (not yours)"
        echo "  2. You're using this repo from another organization"
        echo ""
        echo "Solutions:"
        echo "  - If you're from the SAME team: Get the correct .keys/age-key.txt from your team lead"
        echo "  - If you're from a NEW organization: Generate your own secrets"
        echo ""
        echo "To create your own secrets:"
        echo "  1. ./sops-helper.sh generate    # Generate fresh random values"
        echo "  2. ./sops-helper.sh edit        # Edit with your actual values"
        echo ""
        return 1
    fi
}

# Edit secrets (opens editor, auto-encrypts on save)
edit_secrets() {
    check_key
    echo "Opening $SECRETS_FILE in editor..."
    echo "Changes will be automatically encrypted when you save and exit."

    if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops "$SECRETS_FILE" 2>/dev/null; then
        echo ""
        echo "ERROR: Cannot decrypt secrets for editing!"
        echo ""
        echo "This usually means:"
        echo "  1. The secrets file was encrypted with a DIFFERENT key (not yours)"
        echo "  2. You're using this repo from another organization"
        echo ""
        echo "Solutions:"
        echo "  - If you're from the SAME team: Get the correct .keys/age-key.txt from your team lead"
        echo "  - If you're from a NEW organization: Generate your own secrets"
        echo ""
        echo "To create your own secrets:"
        echo "  1. ./sops-helper.sh generate    # Generate fresh random values"
        echo "  2. ./sops-helper.sh edit        # Edit with your actual values"
        echo ""
        return 1
    fi

    echo "✓ Secrets updated and encrypted!"
}

# Decrypt to a file (for debugging)
decrypt_secrets() {
    check_key
    OUTPUT_FILE="${SECRETS_FILE}.dec"
    echo "Decrypting to $OUTPUT_FILE..."
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d "$SECRETS_FILE" > "$OUTPUT_FILE"
    echo "✓ Decrypted to $OUTPUT_FILE"
    echo ""
    echo "WARNING: This file contains PLAINTEXT secrets!"
    echo "         Delete it after use: rm $OUTPUT_FILE"
}

# Encrypt a decrypted file
encrypt_secrets() {
    check_key
    INPUT_FILE="${1:-${SECRETS_FILE}.dec}"

    if [ ! -f "$INPUT_FILE" ]; then
        echo "ERROR: File not found: $INPUT_FILE"
        echo "Usage: ./sops-helper.sh encrypt [file]"
        exit 1
    fi

    echo "Encrypting $INPUT_FILE to $SECRETS_FILE..."
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -e "$INPUT_FILE" > "$SECRETS_FILE"
    echo "✓ Encrypted to $SECRETS_FILE"
    echo ""
    echo "Don't forget to delete the plaintext file: rm $INPUT_FILE"
}

# Generate fresh secrets with random values
generate_fresh() {
    check_key

    echo "Generating fresh secrets with random values..."
    echo ""
    echo "WARNING: This will create a NEW secrets file template!"
    echo "         Your existing secrets will be backed up to ${SECRETS_FILE}.backup"
    echo ""
    read -p "Continue? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi

    # Backup existing file
    if [ -f "$SECRETS_FILE" ]; then
        cp "$SECRETS_FILE" "${SECRETS_FILE}.backup"
        echo "✓ Backed up existing secrets to ${SECRETS_FILE}.backup"
    fi

    # Generate random secrets
    CLIENT_SECRET=$(openssl rand -hex 32)
    API_TOKEN=$(openssl rand -hex 32)
    CRYPT_KEY_HEX=$(openssl rand -hex 32)
    XNAT_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')

    # Create temp file with new secrets
    TEMP_FILE=$(mktemp)
    cat > "$TEMP_FILE" << EOF
# JupyterHub Secrets (Encrypted with SOPS)
# Generated: $(date)
# Edit with: ./sops-helper.sh edit

hub:
  config:
    GenericOAuthenticator:
      client_id: "REPLACE_WITH_YOUR_OAUTH_CLIENT_ID"
      client_secret: "$CLIENT_SECRET"

  services:
    xnat-service:
      apiToken: "$API_TOKEN"

  extraEnv:
    JUPYTERHUB_CRYPT_KEY_HEX: "$CRYPT_KEY_HEX"
    XNAT_PASSWORD: "$XNAT_PASSWORD"
EOF

    # Encrypt it
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -e "$TEMP_FILE" > "$SECRETS_FILE"
    rm "$TEMP_FILE"

    echo ""
    echo "✓ Fresh secrets generated and encrypted!"
    echo ""
    echo "Next steps:"
    echo "  1. Edit secrets with: ./sops-helper.sh edit"
    echo "  2. Replace 'REPLACE_WITH_YOUR_OAUTH_CLIENT_ID' with your actual OAuth client ID"
    echo "  3. Update other values as needed for your deployment"
    echo ""
    echo "Generated values:"
    echo "  - client_secret: <random 64-char hex>"
    echo "  - apiToken: <random 64-char hex>"
    echo "  - JUPYTERHUB_CRYPT_KEY_HEX: <random 64-char hex>"
    echo "  - XNAT_PASSWORD: <random 21-char string>"
}

# Show usage
show_usage() {
    cat << EOF
SOPS Helper - Manage encrypted secrets easily

Usage: ./sops-helper.sh <command>

Commands:
  view        View secrets in plain text (read-only)
  edit        Edit secrets in your editor (auto-encrypts on save)
  decrypt     Decrypt secrets to a file (for debugging)
  encrypt     Encrypt a plaintext file
  generate    Generate fresh secrets with random values
  help        Show this help message

Examples:
  ./sops-helper.sh view              # View current secrets
  ./sops-helper.sh edit              # Edit secrets
  ./sops-helper.sh generate          # Generate fresh random secrets

Environment:
  SOPS_AGE_KEY_FILE: $AGE_KEY_FILE
  SECRETS_FILE: $SECRETS_FILE

For more info: See README.md section "Secrets Management with SOPS"
EOF
}

# Main command dispatcher
case "${1:-}" in
    view)
        view_secrets
        ;;
    edit)
        edit_secrets
        ;;
    decrypt)
        decrypt_secrets
        ;;
    encrypt)
        encrypt_secrets "$2"
        ;;
    generate)
        generate_fresh
        ;;
    help|--help|-h|"")
        show_usage
        ;;
    *)
        echo "ERROR: Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac
