# JupyterHub-XNAT Integration

Complete integration of JupyterHub with XNAT on Kubernetes.

---

## 📋 Table of Contents
- [🏗️ Architecture Overview](#️-architecture-overview)
- [📦 Prerequisites](#-prerequisites)
- [🚀 Installation Steps](#-installation-steps)
- [⚙️ Configuration](#️-configuration)
- [🧪 Testing](#-testing)
- [👥 User Workflow](#-user-workflow)
- [🔒 Security](#-security)
- [🔧 Troubleshooting](#-troubleshooting)
- [📚 Additional Documentation](#-additional-documentation)
- [📄 License](#-license)
- [✅ Installation Checklist](#-installation-checklist)

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Internet / Users                         │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
              ┌────────────────┐
              │  Nginx Ingress │
              │  Controller    │
              └────┬──────┬────┘
                   │      │
        ┌──────────┘      └──────────┐
        ▼                            ▼
┌───────────────┐          ┌──────────────────┐
│     XNAT      │          │   JupyterHub     │
│               │◄─────────┤                  │
│  - AAF Auth   │  API     │  - AAF OAuth     │
│  - Projects   │  calls   │  - Spawner       │
│  - Plugin     │          │  - Hub           │
└───────┬───────┘          └────────┬─────────┘
        │                           │
        │                    ┌──────┴──────┐
        │                    │             │
        ▼                    ▼             ▼
┌───────────────┐    ┌──────────┐  ┌────────────┐
│  PostgreSQL   │    │   Hub    │  │   Proxy    │
│  (metadata)   │    │   DB     │  │  (route)   │
└───────────────┘    └──────────┘  └────────────┘
        │             Longhorn          │
        │                               │
        ▼                               ▼
┌──────────────────────────────────────────────┐
│           User Notebook Pods                 │
│  ┌─────────────────────────────────────┐     │
│  │  /home/jovyan → Longhorn PVC        │     │
│  │  /data/projects/X → NFS subPath│    │     |
│  │  /data/xnat/workspace → NFS         │     │
│  └─────────────────────────────────────┘     │
└──────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────┐
│          Storage Layer                       │
│  ┌──────────┐           ┌────────────┐       │
│  │ Longhorn │           │ NFS Server │       │
│  │  - User  │           │ /exports/  │       │
│  │   homes  │           │  - gpfs    │       │
│  │  - Hub DB│           │  - xnat    │       │
│  └──────────┘           └────────────┘       │
└──────────────────────────────────────────────┘
```

### Component Details

#### XNAT Layer
- **Purpose:** Medical imaging data management
- **Authentication:** AAF (Australian Access Federation) OAuth
- **Database:** PostgreSQL (metadata only)
- **Storage:** NFS (`/exports/gpfs`, `/exports/xnat`)
- **Plugin:** xnat-jupyterhub-plugin v1.1.1

#### JupyterHub Layer
- **Hub:** Central authentication and spawner
- **Proxy:** Routes traffic to user notebooks
- **Authentication:** AAF OAuth (shared session with XNAT)
- **API:** RESTful API for XNAT plugin
- **Spawner:** KubeSpawner with custom pre_spawn_hook

#### Storage Layer
- **Longhorn:** 
  - Dynamic provisioning for user home directories
  - Hub database persistence
  - Block storage with replication
  
- **NFS:**
  - Shared storage for XNAT data
  - Read-only project data access
  - Read-write workspace directory

#### Network Layer
- **Ingress:** Single entry point (`xnat-test.ssdsorg.cloud.edu.au`)
  - `/` → XNAT
  - `/jupyter` → JupyterHub
  
- **Internal Services:**
  - `xnat-web.ais-xnat.svc.cluster.local` (XNAT API)
  - `proxy-public.jupyter.svc.cluster.local:8081` (JupyterHub API)

---

## 📦 Prerequisites

### Required
- ✅ Kubernetes cluster (microk8s 1.24+)
- ✅ kubectl configured
- ✅ Helm 3.x installed
- ✅ XNAT deployed with AAF authentication
- ✅ XNAT JupyterHub plugin installed
- ✅ NFS server with CSI driver
- ✅ Ingress controller (nginx)

### Minimum Resources
- **CPU:** 4 cores
- **Memory:** 8 GB RAM
- **Storage:** 100 GB available

### Network Requirements
- Port 80/443 accessible for ingress
- DNS configured for `<registered domain>`
- Internal cluster networking enabled

---

## 🚀 Installation Steps

### Step 0: Pre-Installation Check

Verify XNAT is running:
```bash
kubectl get pods -n ais-xnat
# Should show: xnat-web-0 (2/2 Running)
```

Verify NFS server is accessible:
```bash
kubectl get pods -n storage
# Should show: nfs-server-XXXXX (1/1 Running)
```

### Step 1: Cleanup Existing Installation

```bash
chmod +x 1-cleanup.sh
./1-cleanup.sh
```

This removes:
- Old JupyterHub installation
- Old Longhorn installation
- Orphaned PVCs and PVs
- jupyter namespace

**Wait for cleanup to complete before proceeding.**

### Step 2: Install Longhorn

```bash
chmod +x 2-install-longhorn.sh
./2-install-longhorn.sh
```

Longhorn provides:
- Dynamic PVC provisioning
- Storage replication
- Snapshot capabilities
- Volume management UI

**Expected time:** 3-5 minutes

### Step 3: Create Jupyter Namespace

```bash
kubectl create namespace jupyter
```

### Step 4: Create NFS PersistentVolume
```bash
kubectl apply -f 3-nfs-pv.yaml
```

Creates one PV:
- `jupyter-xnat-gpfs-shared` → Points to `/gpfs` on NFS for XNAT workspaces and project data

### Step 5: Create NFS PersistentVolumeClaim
```bash
kubectl apply -f 4-nfs-pvc.yaml
```

Creates one PVC in the jupyter namespace:
- `xnat-gpfs` → Binds to `jupyter-xnat-gpfs-shared` PV for mounting XNAT workspaces and project data

Verify binding:
```bash
kubectl get pvc -n jupyter
# Both should show STATUS: Bound
```

### Step 6: Install JupyterHub

```bash
chmod +x 6-install-jupyterhub.sh
./6-install-jupyterhub.sh
```

This installs:
- JupyterHub Hub (with custom pre_spawn_hook)
- Configurable HTTP Proxy
- User notebook spawner
- AAF OAuth configuration

**Expected time:** 5-10 minutes

### Step 7: Verify Installation

```bash
chmod +x 8-verify.sh
./8-verify.sh
```

Runs comprehensive checks:
- Longhorn health
- Namespace and resources
- PV/PVC bindings
- Pod status
- Service configuration
- API accessibility

**All tests should pass before proceeding.**

### Step 8: Configure XNAT Plugin

Follow detailed guide in `7-XNAT-CONFIGURATION.md`:

1. Login to XNAT admin interface
2. Configure JupyterHub connection settings
3. Set up compute environments
4. Enable JupyterHub for projects
5. Test user workflow

**Required Settings:**
- JupyterHub URL: `http://proxy-public.jupyter.svc.cluster.local:8081/jupyter`
- Service Token: `<generated-service-token>`

---

## ⚙️ Configuration

### Key Configuration Files

#### 5-jupyterhub-values.yaml
Main JupyterHub configuration:
- AAF OAuth credentials
- Pre-spawn hook for XNAT integration
- Resource limits
- Storage configuration
- Image selection (NeuroDesk)

#### XNAT Plugin Settings
Configured via XNAT UI:
- JupyterHub API endpoint
- Service token
- Path translation
- Compute environments

### Customization Points

#### Change NeuroDesk Image Version
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  image:
    name: ghcr.io/neurodesk/neurodesktop/neurodesktop
    tag: "2024-12-05"  # update to latest
```

#### Adjust User Resource Limits
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  cpu:
    guarantee: 0.5  # Minimum CPU
    limit: 4        # Maximum CPU
  memory:
    guarantee: 1G   # Minimum RAM
    limit: 8G       # Maximum RAM
```

#### Change User Home Directory Size
Edit `5-jupyterhub-values.yaml`:
```yaml
singleuser:
  storage:
    capacity: 10Gi  # can change this to increase singleuser storage
```

#### Adjust Idle Timeout
Edit `5-jupyterhub-values.yaml`:
```yaml
cull:
  enabled: true
  timeout: 3600    # Seconds of inactivity (1 hour)
  every: 600       # Check interval (10 minutes)
```

---

## 🧪 Testing

### Test 1: API Connectivity

```bash
# From hub pod
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')

# Test XNAT API
kubectl exec -n jupyter $HUB_POD -- \
  curl -u admin:admin \
  http://xnat-web.ais-xnat.svc.cluster.local/xnat/data/version

# Test JupyterHub API
kubectl exec -n jupyter $HUB_POD -- \
  curl -H "Authorization: token eda886c63564930a7f21ad8465463bf9555bad7d1dfa0a2fb259ac556ea8420e" \
  http://proxy-public.jupyter.svc.cluster.local:8081/jupyter/hub/api
```

### Test 2: User Spawn

```bash
# Start test user's server
curl -X POST \
  -H "Authorization: token eda886c63564930a7f21ad8465463bf9555bad7d1dfa0a2fb259ac556ea8420e" \
  http://proxy-public.jupyter.svc.cluster.local:8081/jupyter/hub/api/users/testuser/server

# Check pod creation
kubectl get pods -n jupyter | grep jupyter-testuser

# Check logs
kubectl logs -n jupyter jupyter-testuser
```

### Test 3: Data Access

Once user pod is running:
```bash
# Check mounts
kubectl exec -n jupyter jupyter-testuser -- df -h

# Check project data
kubectl exec -n jupyter jupyter-testuser -- ls -la /data/xnat/projects/

# Check home directory
kubectl exec -n jupyter jupyter-testuser -- ls -la /home/jovyan/
```

---

## 👥 User Workflow

### For End Users

1. **Access XNAT**
   - Navigate to: http://xnat-test.ssdsorg.cloud.edu.au
   - Click "Login with AAF"
   - Enter AAF credentials

2. **Navigate to Project**
   - Select a project from project list
   - Ensure JupyterHub is enabled for the project

3. **Launch JupyterHub**
   - Click "Launch JupyterHub" button (in project actions)
   - Browser redirects to JupyterHub
   - **No full re-login required** (AAF session reused once correct Idp selected)

4. **Work in Notebook**
   - Jupyter Lab opens automatically
   - Personal workspace: `/home/jovyan`
   - Project data: `/data/projects/{PROJECT_ID}` (read-only)

5. **Save and Exit**
   - Work is automatically saved to personal storage
   - Server shuts down after set limit of inactivity


## 🔒 Security

### Authentication Flow

```
User → XNAT UI → "Launch Jupyter" button
  ↓
XNAT Plugin → JupyterHub API (service token)
  ↓
JupyterHub → Redirects to AAF OAuth
  ↓
AAF → Validates (reuses browser session)
  ↓
User → Redirected back to JupyterHub
  ↓
Pre-spawn hook → Calls XNAT API (admin credentials)
  ↓
XNAT API → Returns user's accessible projects
  ↓
Spawner → Mounts only authorized projects
  ↓
User Notebook → Launches with restricted access
```

### Security Best Practices

- ✅ Change default admin password in `5-jupyterhub-values.yaml`
- ✅ Rotate service token periodically
- ✅ Enable TLS for production (update ingress config)
- ✅ Implement NetworkPolicies for namespace isolation
- ✅ Regular security audits of pod configurations
- ✅ Monitor API access logs

### Secrets Management

Current secrets in configuration:
- AAF client_id and client_secret
- XNAT admin credentials
- JupyterHub service token

**For production:** Move to Kubernetes Secrets:
```bash
kubectl create secret generic jupyterhub-secrets -n jupyter \
  --from-literal=aaf-client-id='xxx' \
  --from-literal=aaf-client-secret='xxx' \
  --from-literal=xnat-admin-password='xxx'
```

---

## 🔧 Troubleshooting

See guide: `9-TROUBLESHOOTING.md`



---

## 📚 Additional Documentation

- **Installation:** This README
- **XNAT Configuration:** `7-XNAT-CONFIGURATION.md`
- **Troubleshooting:** `9-TROUBLESHOOTING.md`
- **Architecture Diagrams:** See above


---

## 📄 License

This integration follows the licenses of its components:
- JupyterHub: BSD License
- XNAT: Simplified BSD License
- Longhorn: Apache 2.0
- NeuroDesk: GPL-3.0

---

## ✅ Installation Checklist

Use this checklist to track your installation:

- [ ] Prerequisites verified
- [ ] Cleanup completed (`1-cleanup.sh`)
- [ ] Longhorn installed (`2-install-longhorn.sh`)
- [ ] Jupyter namespace created
- [ ] NFS PVs created (`3-nfs-pv.yaml`)
- [ ] NFS PVC created and bound (`4-nfs-pvc.yaml`)
- [ ] JupyterHub installed (`6-install-jupyterhub.sh`)
- [ ] Verification passed (`8-verify.sh`)
- [ ] XNAT plugin configured (`7-XNAT-CONFIGURATION.md`)
- [ ] Test user workflow completed
- [ ] Production settings reviewed

---

**Version:** 1.0.0  
**Last Updated:** 03-12-2025  

