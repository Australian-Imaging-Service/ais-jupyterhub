# Troubleshooting Guide

**Important Note:** Replace `<username>`, `<jupyter-token>`, and domain names with your actual deployment values.

## Common Issues and Solutions

### 1. Cleanup Issues

#### Problem: Namespace stuck in "Terminating"
```bash
# Force delete namespace
kubectl get namespace jupyter -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/jupyter/finalize" -f -
```

#### Problem: PVs stuck in "Released" state
```bash
# Remove claimRef to make PV available again
kubectl patch pv jupyter-xnat-gpfs-shared -p '{"spec":{"claimRef": null}}'
```

### 2. Longhorn Installation Issues

#### Problem: Longhorn pods in CrashLoopBackOff
```bash
# Check logs
kubectl logs -n longhorn-system -l app=longhorn-manager

# Common fix: Ensure proper directory permissions
sudo mkdir -p /var/snap/microk8s/common/var/lib/longhorn
sudo chown -R root:root /var/snap/microk8s/common/var/lib/longhorn
```

#### Problem: No StorageClass created
```bash
# Manually create default StorageClass
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 3. NFS Mount Issues

#### Problem: PVC stuck in "Pending"
```bash
# Check PV and PVC
kubectl describe pv jupyter-xnat-gpfs-shared
kubectl describe pvc -n jupyter xnat-gpfs

# Verify NFS server is running
kubectl get pods -n storage

# Test NFS mount manually
kubectl run -n jupyter test-nfs --image=busybox --rm -it --restart=Never -- sh
# Inside pod:
mount -t nfs nfs-server.storage.svc.cluster.local:/gpfs /mnt
ls /mnt
```

#### Problem: Permission denied in mounted directory
```bash
# Check NFS export permissions
kubectl exec -n storage deploy/nfs-server -- ls -la /exports/gpfs
kubectl exec -n storage deploy/nfs-server -- chmod -R 755 /exports/gpfs

# Check workspace directory permissions
kubectl exec -n storage deploy/nfs-server -- ls -la /exports/gpfs/workspaces/users
kubectl exec -n storage deploy/nfs-server -- chmod -R 755 /exports/gpfs/workspaces/users
```

### 4. JupyterHub Installation Issues

#### Problem: Helm install times out
```bash
# Check pod status
kubectl get pods -n jupyter
kubectl describe pod -n jupyter <pod-name>

# Check events
kubectl get events -n jupyter --sort-by='.lastTimestamp'

# Increase timeout and retry
helm install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --values 5-jupyterhub-values.yaml \
  --timeout 20m \
  --debug
```

#### Problem: Hub pod fails to start
```bash
# Check hub logs
kubectl logs -n jupyter -l component=hub

# Common issues:
# - Database connection: Check db PVC is bound
# - Config syntax: Validate YAML syntax in extraConfig
# - Image pull: Check image name and registry access
# - Crypt key: Verify JUPYTERHUB_CRYPT_KEY_HEX is valid hex string
```

#### Problem: Proxy pod fails to start
```bash
# Check proxy logs
kubectl logs -n jupyter -l component=proxy

# Check configmap
kubectl get configmap -n jupyter hub-config -o yaml
```

#### Problem: External idle culler service not starting
```bash
# Check if culler service exists
kubectl get pods -n jupyter | grep user-cull

# Check hub logs for culler errors
kubectl logs -n jupyter -l component=hub | grep -i cull

# Verify loadRoles and services configuration
kubectl get configmap -n jupyter hub-config -o yaml | grep -A 20 "user-cull"
```

### 5. Authentication Issues

#### Problem: AAF OAuth fails
```bash
# Check Hub logs for OAuth errors
kubectl logs -n jupyter -l component=hub | grep -i oauth

# Verify OAuth configuration
kubectl get configmap -n jupyter hub-config -o yaml | grep -A 20 GenericOAuthenticator

# Common fixes:
# 1. Verify callback URL matches AAF registration
#    Expected: https://xnat-test.ssdsorg.cloud.edu.au/jupyter/hub/oauth_callback
# 2. Check client_id and client_secret are correct
# 3. Ensure ingress is routing /jupyter correctly
# 4. Verify AAF test endpoint is accessible
```

#### Problem: "403 Forbidden" when accessing JupyterHub
```bash
# Check ingress configuration
kubectl get ingress -n jupyter jupyterhub -o yaml

# Verify ingress is routing correctly
kubectl describe ingress -n jupyter jupyterhub

# Test proxy service directly
kubectl port-forward -n jupyter svc/proxy-public 8081:8081
# Access: http://localhost:8081/jupyter
```

#### Problem: "413 Request Entity Too Large" or "502 Bad Gateway" during OAuth
**Symptom:** OAuth callback fails with 413 or 502 errors, particularly with AAF which sends large headers.

**Root Cause:** Nginx ingress has default buffer limits that are small for AAF's OAuth headers.

**Solution - Apply Ingress Buffer Fix:**

```bash
# Step 1: Add buffer annotations to JupyterHub ingress
kubectl -n jupyter annotate ingress jupyterhub \
  nginx.ingress.kubernetes.io/proxy-buffer-size="32k" \
  nginx.ingress.kubernetes.io/proxy-buffers-number="8" \
  nginx.ingress.kubernetes.io/proxy-busy-buffers-size="24k" \
  --overwrite

# Step 2: Get ingress controller configmap and deployment names
INGRESS_CM=$(kubectl -n ingress get configmap -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')
INGRESS_DEPLOY=$(kubectl -n ingress get deployment -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}')

echo "ConfigMap: $INGRESS_CM"
echo "Deployment: $INGRESS_DEPLOY"

# Step 3: Patch global ingress controller configuration
kubectl -n ingress patch configmap $INGRESS_CM \
  --type merge -p '{"data":{
    "proxy-buffer-size":"32k",
    "large-client-header-buffers":"4 32k",
    "ignore-invalid-headers":"true"
  }}'

# Step 4: Restart ingress controller to apply changes
kubectl -n ingress rollout restart deployment/$INGRESS_DEPLOY
kubectl -n ingress rollout status deployment/$INGRESS_DEPLOY

# Verify changes applied
kubectl -n ingress get configmap $INGRESS_CM -o yaml | grep -A 3 "proxy-buffer"
```

**Verification:**
```bash
# Test OAuth login again - should work without 413/502 errors
# Check ingress logs for any remaining errors
kubectl logs -n ingress -l app.kubernetes.io/name=ingress-nginx | grep -i "upstream sent too big header"
```

**Prevention:** Run the `post-install-ingress-fix.sh` script immediately after installation if using AAF authentication.

#### Problem: Username normalization issues
```bash
# Check hub logs for username processing
kubectl logs -n jupyter -l component=hub | grep -i "normalize"

# Verify database has xnat_username column
kubectl exec -n jupyter -l component=hub -- sqlite3 /srv/jupyterhub/jupyterhub.sqlite "PRAGMA table_info(users);"

# Check stored usernames
kubectl exec -n jupyter -l component=hub -- sqlite3 /srv/jupyterhub/jupyterhub.sqlite "SELECT name, xnat_username FROM users;"
```

### 6. User Spawn Issues

#### Problem: User notebook fails to spawn
```bash
# Check spawner logs in hub
kubectl logs -n jupyter -l component=hub | grep -i spawn

# Check for user pod
kubectl get pods -n jupyter | grep jupyter-

# If user pod exists, check its logs
kubectl logs -n jupyter jupyter-<username>

# Check events
kubectl get events -n jupyter --field-selector involvedObject.name=jupyter-<username>
```

#### Problem: User pod stuck in "Pending"
```bash
# Check pod status
kubectl describe pod -n jupyter jupyter-<username>

# Common issues:
# - Insufficient resources: Check node capacity
# - PVC binding: Check user PVC status
# - Image pull: Check image exists and is accessible
# - Init container failure: Check workspace-setup init container logs
```

#### Problem: Init container (workspace-setup) fails
```bash
# Check init container logs
kubectl logs -n jupyter jupyter-<username> -c workspace-setup

# Verify NFS mount in init container
kubectl describe pod -n jupyter jupyter-<username> | grep -A 10 "Init Containers"

# Common fixes:
# - Check NFS permissions on /exports/gpfs/workspaces/users
# - Verify busybox image is accessible
# - Check init container has correct volumeMounts
```

#### Problem: User can't access workspace directory
```bash
# Check pre_spawn_hook execution
kubectl logs -n jupyter -l component=hub | grep -i "\[XNAT\]"

# Verify workspace exists on NFS
kubectl exec -n storage deploy/nfs-server -- ls -la /exports/gpfs/workspaces/users/

# Check volume mounts in user pod
kubectl describe pod -n jupyter jupyter-<username> | grep -A 10 Mounts

# Verify workspace mount in user pod
kubectl exec -n jupyter jupyter-<username> -- df -h | grep workspace
kubectl exec -n jupyter jupyter-<username> -- ls -la /data/xnat/workspaces/users/
kubectl exec -n jupyter jupyter-<username> -- ls -la /workspace/
```

#### Problem: User can't access project data
```bash
# Check XNAT API response for user
kubectl logs -n jupyter -l component=hub | grep -i "user-options"

# Verify XNAT API is accessible from hub
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n jupyter $HUB_POD -- curl -u admin:admin \
  http://xnat-web.ais-xnat.svc.cluster.local/xapi/jupyterhub/users/testuser/server/user-options

# Check volume mounts in user pod
kubectl describe pod -n jupyter jupyter-<username> | grep -A 20 Mounts

# Verify project data mount in user pod
kubectl exec -n jupyter jupyter-<username> -- df -h
kubectl exec -n jupyter jupyter-<username> -- ls -la /data/xnat/archive/
```

### 7. XNAT Integration Issues

#### Problem: JupyterHub button doesn't appear in XNAT
**Solution:**
```bash
# 1. Verify XNAT plugin is installed
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  ls -la /data/xnat/home/plugins/ | grep jupyterhub

# 2. Check plugin is enabled in XNAT Admin UI
#    Navigate to: Administer > Plugin Settings > JupyterHub Plugin

# 3. Verify plugin configuration
#    Navigate to: Administer > Plugin Settings > JupyterHub Configuration
#    Check: JupyterHub URL and Service Token are set

# 4. Check user has project access in XNAT
#    Navigate to: Projects > [Project] > Access
#    Verify user is listed with appropriate role

# 5. Verify JupyterHub is enabled for the project
#    Navigate to: Projects > [Project] > Project Settings > JupyterHub
```

#### Problem: XNAT can't reach JupyterHub API
```bash
# From XNAT pod, test connectivity
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  curl -v http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api

# Check service exists
kubectl get svc -n jupyter proxy-public

# Check service endpoints
kubectl get endpoints -n jupyter proxy-public

# Verify service token is correct
kubectl logs -n jupyter -l component=hub | grep -i "service.*token"

# Test with correct token
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  curl -H "Authorization: token <jupyter-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api
```

#### Problem: XNAT user-options API not found (404)
```bash
# Check if XNAT plugin endpoint exists
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  curl -u admin:admin http://localhost:8080/xapi/jupyterhub/users/testuser/server/user-options

# Check XNAT logs for API errors
kubectl logs -n ais-xnat xnat-web-0 -c xnat-web | grep -i jupyterhub

# Verify plugin REST endpoint is registered
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  curl -u admin:admin http://localhost:8080/xapi/jupyterhub

# Expected endpoints:
# - /xapi/jupyterhub/users/{username}/server/user-options
# - /xapi/jupyterhub/environments
```

#### Problem: XNAT returns wrong user-options format
```bash
# Check actual API response
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n jupyter $HUB_POD -- \
  curl -u admin:admin \
  http://xnat-web.ais-xnat.svc.cluster.local/xapi/jupyterhub/users/testuser/server/user-options

# Expected format (XNAT task_template structure):
# {
#   "task_template": {
#     "container_spec": {
#       "mounts": [
#         {
#           "source": "/data/xnat/archive/PROJECT_ID/arc001",
#           "target": "/data/xnat/archive/PROJECT_ID/arc001",
#           "read_only": true
#         }
#       ],
#       "env": {
#         "XNAT_PROJECT": "PROJECT_ID"
#       }
#     },
#     "resources": {
#       "cpu_limit": 4,
#       "mem_limit": "8G"
#     }
#   }
# }

# Check pre_spawn_hook parsing
kubectl logs -n jupyter -l component=hub | grep -i "task_template"
```

#### Problem: JupyterHub fails to start user server from XNAT
**Solution:**
```bash
# 1. Check JupyterHub logs for spawn errors
kubectl logs -n jupyter -l component=hub -f

# 2. Verify XNAT is sending correct username format
#    XNAT should send the AAF username (without aaf_ prefix)
#    JupyterHub will normalize it to aaf_<username>

# 3. Test manual spawn via API
curl -X POST \
  -H "Authorization: token <<jupyter-token>>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/testuser/server

# 4. Check for user pod creation
kubectl get pods -n jupyter | grep jupyter-

# 5. Check network connectivity between XNAT and JupyterHub
kubectl exec -n ais-xnat xnat-web-0 -c xnat-web -- \
  curl -v http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api
```

#### Problem: Projects not mounting in user notebook
```bash
# 1. Check XNAT API response includes mounts
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n jupyter $HUB_POD -- \
  curl -u admin:admin \
  http://xnat-web.ais-xnat.svc.cluster.local/xapi/jupyterhub/users/testuser/server/user-options | jq '.task_template.container_spec.mounts'

# 2. Check NFS structure matches XNAT paths
kubectl exec -n storage deploy/nfs-server -- ls -la /exports/gpfs/archive/

# 3. Verify pre_spawn_hook processes mounts correctly
kubectl logs -n jupyter -l component=hub | grep -i "Mounted:"

# 4. Check actual mounts in user pod
kubectl describe pod -n jupyter jupyter-<username> | grep -A 30 "Mounts:"

# 5. Verify inside user container
kubectl exec -n jupyter jupyter-<username> -- df -h
kubectl exec -n jupyter jupyter-<username> -- ls -la /data/xnat/archive/
```

#### Problem: User doesn't see project data in notebook
**Solution:**
```bash
# 1. Verify NFS mount structure matches expected paths
kubectl exec -n storage deploy/nfs-server -- ls -la /exports/gpfs/archive/

# 2. Check pre_spawn_hook logs in Hub pod
kubectl logs -n jupyter -l component=hub | grep -i "\[XNAT\]"

# 3. Verify XNAT API returns correct mount paths
#    Paths should use format: /data/xnat/archive/{PROJECT_ID}/arc001

# 4. Check user pod has correct subPath mounts
kubectl get pod -n jupyter jupyter-<username> -o yaml | grep -A 5 subPath

# 5. Test access inside user pod
kubectl exec -n jupyter jupyter-<username> -- ls -la /data/xnat/archive/
```

### 8. Idle Culling Issues

#### Problem: User pods not being culled after idle timeout
```bash
# 1. Check external culler service is running
kubectl logs -n jupyter -l component=hub | grep -i "idle_culler"

# 2. Verify culler configuration
kubectl get configmap -n jupyter hub-config -o yaml | grep -A 10 "user-cull"

# 3. Check internal culling configuration
kubectl exec -n jupyter jupyter-<username> -- cat /etc/jupyter/jupyter_server_config.py

# 4. Check kernel status
kubectl exec -n jupyter jupyter-<username> -- jupyter lab list

# 5. Monitor culling events
kubectl logs -n jupyter -l component=hub -f | grep -i "cull"
```

#### Problem: Pods being culled too aggressively
```bash
# Check current timeout settings
kubectl get configmap -n jupyter hub-config -o yaml | grep -E "timeout|cull"

# Expected settings:
# - External culler: 86400 seconds (24 hours)
# - Internal pod shutdown: 7200 seconds (2 hours)
# - Internal kernel culling: 5400 seconds (1.5 hours)

# To adjust, edit values file and upgrade:
helm upgrade jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --values 5-jupyterhub-values.yaml \
  --reuse-values
```

### 9. Configuration Updates and Upgrades

#### Problem: Need to update JupyterHub configuration
**Scenario:** You've modified `5-jupyterhub-values.yaml` and need to apply changes to running deployment.

**Solution - Upgrade JupyterHub:**

```bash
# Step 1: Verify your changes in values file
cat 5-jupyterhub-values.yaml | grep -A 10 "<your-change>"

# Step 2: Check current release version
helm list -n jupyter

# Step 3: Perform upgrade
helm upgrade jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --version 4.3.1 \
  --values 5-jupyterhub-values.yaml

# Step 4: Monitor rollout
kubectl -n jupyter rollout status deployment/hub
kubectl -n jupyter rollout status deployment/proxy

# Step 5: Verify pods are running
kubectl get pods -n jupyter

# Step 6: Check hub logs for any errors
kubectl logs -n jupyter -l component=hub --tail=50
```

**Common Configuration Changes:**

**1. Update Resource Limits:**
```yaml
# In 5-jupyterhub-values.yaml
singleuser:
  cpu: { guarantee: 1, limit: 8 }      # Updated from 0.5/4
  memory: { guarantee: 2G, limit: 16G } # Updated from 1G/8G
```

**2. Update Culling Timeouts:**
```yaml
# In 5-jupyterhub-values.yaml
hub:
  services:
    user-cull:
      command:
        - --timeout=172800  # Change from 86400 (24h) to 172800 (48h)
```

**3. Update NeuroDesk Image:**
```yaml
# In 5-jupyterhub-values.yaml
singleuser:
  image:
    name: ghcr.io/neurodesk/neurodesktop/neurodesktop
    tag: "2025-01-15"  # Update to newer version
```

**After Upgrade:**
```bash
# Active users need to restart their servers to get new configuration
# They can do this from JupyterHub control panel or via API:
curl -X DELETE \
  -H "Authorization: token <service-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/<username>/server
```

#### Problem: Need to rollback after failed upgrade
```bash
# Check helm history
helm history -n jupyter jupyterhub

# Rollback to previous revision
helm rollback jupyterhub <revision-number> -n jupyter

# Example: Rollback to revision 2
helm rollback jupyterhub 2 -n jupyter

# Verify rollback
kubectl get pods -n jupyter
kubectl logs -n jupyter -l component=hub --tail=50
```

#### Problem: Configuration changes not taking effect
```bash
# Common causes:

# 1. Values file not being read - check helm command used correct file
helm get values jupyterhub -n jupyter > current-values.yaml
diff current-values.yaml 5-jupyterhub-values.yaml

# 2. ConfigMap not updated - force recreation
kubectl delete configmap hub-config -n jupyter
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyter --values 5-jupyterhub-values.yaml

# 3. Pod not restarted - force pod restart
kubectl delete pod -n jupyter -l component=hub
kubectl wait --for=condition=ready pod -l component=hub -n jupyter --timeout=300s

# 4. Cached values - use --reset-values flag
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyter \
  --values 5-jupyterhub-values.yaml \
  --reset-values
```

### 10. Network Issues

#### Problem: Services can't communicate
```bash
# Check network policies
kubectl get networkpolicies -A

# Test DNS resolution
kubectl run test-dns --image=busybox --rm -it --restart=Never -- nslookup xnat-web.ais-xnat.svc.cluster.local

# Test connectivity between namespaces
kubectl run test-curl --image=curlimages/curl --rm -it --restart=Never -- \
  curl -v http://xnat-web.ais-xnat.svc.cluster.local

# Test JupyterHub API from XNAT namespace
kubectl run -n ais-xnat test-jupyter-api --image=curlimages/curl --rm -it --restart=Never -- \
  curl -v http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api
```

#### Problem: Ingress not routing correctly
```bash
# Check ingress controller
kubectl get pods -n ingress

# Check ingress rules
kubectl get ingress -n jupyter jupyterhub -o yaml

# Test ingress routing (note: for testing bypassing TLS)
curl -H "Host: xnat-test.ssdsorg.cloud.edu.au" http://<ingress-controller-ip>/jupyter

# Check ingress logs
kubectl logs -n ingress -l app.kubernetes.io/name=ingress-nginx

# Verify path rewriting
kubectl describe ingress -n jupyter jupyterhub | grep -A 10 "Rules:"
```

### 11. Resource Issues

#### Problem: Nodes running out of resources
```bash
# Check node resources
kubectl top nodes
kubectl describe nodes

# Check pod resource requests
kubectl describe pod -n jupyter -l component=hub | grep -A 5 "Requests:"

# Check all pod resource usage
kubectl top pod -n jupyter

# Adjust resource limits in values.yaml if needed
# Then upgrade:
helm upgrade jupyterhub jupyterhub/jupyterhub \
  --namespace jupyter \
  --values 5-jupyterhub-values.yaml
```

#### Problem: Disk space issues
```bash
# Check PVC usage
kubectl get pvc -A

# Check actual disk usage on Longhorn
df -h /var/snap/microk8s/common/var/lib/longhorn

# Check NFS usage
kubectl exec -n storage deploy/nfs-server -- df -h

# Clean up old user PVCs
kubectl delete pvc -n jupyter jupyter-<old-username>

# Clean up completed pods
kubectl delete pod -n jupyter --field-selector status.phase=Succeeded
kubectl delete pod -n jupyter --field-selector status.phase=Failed
```

#### Problem: Image pull failures
```bash
# Check if image exists
docker pull ghcr.io/neurodesk/neurodesktop/neurodesktop:2024-12-05

# Check pod events
kubectl describe pod -n jupyter jupyter-<username> | grep -A 10 "Events:"

# Check image pull policy
kubectl get pod -n jupyter jupyter-<username> -o yaml | grep imagePullPolicy

# Common fixes:
# 1. Verify image name and tag are correct
# 2. Check registry is accessible from cluster
# 3. Add imagePullSecrets if private registry
```

### 12. Security and Monitoring

#### Problem: Service token not working
```bash
# Verify token is set correctly in hub
kubectl get configmap -n jupyter hub-config -o yaml | grep -i "apitoken"

# Test token
curl -H "Authorization: token <jupyter-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users

# Regenerate token if needed (edit values file and upgrade)
```

#### Monitoring Active Sessions
```bash
# Count active user pods
kubectl get pods -n jupyter | grep jupyter- | wc -l

# List all active users
kubectl get pods -n jupyter -o jsonpath='{range .items[*]}{.metadata.labels.component}{" "}{.metadata.name}{"\n"}{end}' | grep singleuser

# Check hub resource usage
kubectl top pod -n jupyter -l component=hub

# Check user pod resource usage
kubectl top pod -n jupyter -l component=singleuser-server

# Monitor PVC growth
watch kubectl get pvc -n jupyter
```

#### Security Audit
```bash
# Check for exposed secrets
kubectl get secrets -n jupyter -o yaml | grep -v "kubernetes.io/service-account-token"

# Verify TLS is enabled (for production)
kubectl get ingress -n jupyter jupyterhub -o yaml | grep tls

# Check service account permissions
kubectl get serviceaccount -n jupyter
kubectl describe serviceaccount -n jupyter hub

# Verify pod security contexts
kubectl get pod -n jupyter -o yaml | grep -A 5 securityContext
```

### 13. Debugging Commands

#### Get all resources in jupyter namespace
```bash
kubectl get all,pvc,configmap,secret,ingress -n jupyter
```

#### Watch pod status in real-time
```bash
kubectl get pods -n jupyter -w
```

#### Follow logs from hub
```bash
kubectl logs -n jupyter -l component=hub -f --tail=100
```

#### Follow logs with XNAT-specific filtering
```bash
kubectl logs -n jupyter -l component=hub -f | grep -i "\[XNAT\]"
```

#### Check recent events
```bash
kubectl get events -n jupyter --sort-by='.lastTimestamp' | tail -20
```

#### Describe all pods
```bash
kubectl describe pods -n jupyter
```

#### Check ConfigMap
```bash
kubectl get configmap -n jupyter hub-config -o yaml
```

#### Execute commands in hub pod
```bash
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n jupyter $HUB_POD -- env | grep XNAT
kubectl exec -n jupyter $HUB_POD -it -- bash
```

#### Debug user spawn interactively
```bash
# Start a test spawn and watch logs
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')

# Terminal 1: Watch hub logs
kubectl logs -n jupyter $HUB_POD -f

# Terminal 2: Trigger spawn
curl -X POST \
  -H "Authorization: token <jupyter-token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/testuser/server

# Terminal 3: Watch pod creation
kubectl get pods -n jupyter -w
```

### 14. Reset and Fresh Start

If everything is broken, complete reset:

```bash
# 1. Run cleanup
bash 1-cleanup.sh

# 2. Wait for complete cleanup
kubectl get all -n jupyter
kubectl get pvc -n jupyter

# 3. If stuck, force cleanup
kubectl delete namespace jupyter --force --grace-period=0
kubectl delete namespace longhorn-system --force --grace-period=0

# 4. Clean orphaned PVs
kubectl get pv | grep -E "jupyter|longhorn" | awk '{print $1}' | xargs kubectl delete pv

# 5. Clean orphaned user PVCs (if any remain)
kubectl get pv | grep "jupyter-.*" | awk '{print $1}' | xargs kubectl delete pv

# 6. Start fresh
bash 2-install-longhorn.sh
# Wait for Longhorn to be ready
kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=300s

bash 6-install-jupyterhub.sh
# Wait for JupyterHub to be ready
kubectl wait --for=condition=ready pod -l component=hub -n jupyter --timeout=300s

bash 8-verify.sh
```

## Key Log Locations

### Important Logs to Monitor:

```bash
# 1. Hub logs (authentication, spawner, API calls, XNAT integration)
kubectl logs -n jupyter -l component=hub -f

# 2. Proxy logs (routing, traffic)
kubectl logs -n jupyter -l component=proxy -f

# 3. User notebook logs
kubectl logs -n jupyter jupyter-{username}

# 4. Init container logs (workspace setup)
kubectl logs -n jupyter jupyter-{username} -c workspace-setup

# 5. XNAT logs (plugin activity)
kubectl logs -n ais-xnat xnat-web-0 -c xnat-web | grep -i jupyterhub

# 6. Longhorn logs (storage issues)
kubectl logs -n longhorn-system -l app=longhorn-manager

# 7. NFS server logs
kubectl logs -n storage deploy/nfs-server

# 8. Ingress controller logs (OAuth callbacks, routing)
kubectl logs -n ingress -l app.kubernetes.io/name=ingress-nginx -f
```

## Getting Help

### Collecting Debug Information

```bash
# Create comprehensive debug bundle
mkdir debug-info

# JupyterHub resources
kubectl get all,pvc,pv,configmap,ingress -n jupyter -o yaml > debug-info/jupyter-resources.yaml
kubectl logs -n jupyter -l component=hub --tail=500 > debug-info/hub-logs.txt
kubectl logs -n jupyter -l component=proxy --tail=500 > debug-info/proxy-logs.txt
kubectl describe pods -n jupyter > debug-info/pod-descriptions.txt
kubectl get events -n jupyter --sort-by='.lastTimestamp' > debug-info/jupyter-events.txt

# User pod info (if exists)
USER_POD=$(kubectl get pod -n jupyter -l component=singleuser-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$USER_POD" ]; then
    kubectl logs -n jupyter $USER_POD --tail=500 > debug-info/user-pod-logs.txt
    kubectl describe pod -n jupyter $USER_POD > debug-info/user-pod-description.txt
fi

# Storage
kubectl get all -n longhorn-system -o yaml > debug-info/longhorn-resources.yaml
kubectl get pv,pvc -A -o yaml > debug-info/storage-resources.yaml

# XNAT connectivity
HUB_POD=$(kubectl get pod -n jupyter -l component=hub -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n jupyter $HUB_POD -- curl -v http://xnat-web.ais-xnat.svc.cluster.local 2>&1 > debug-info/xnat-connectivity.txt

# Network
kubectl get ingress -A -o yaml > debug-info/ingress-config.yaml
kubectl get svc -A -o yaml > debug-info/services.yaml

# Ingress logs
kubectl logs -n ingress -l app.kubernetes.io/name=ingress-nginx --tail=500 > debug-info/ingress-logs.txt

# Create tarball
tar -czf debug-info-$(date +%Y%m%d-%H%M%S).tar.gz debug-info/
rm -rf debug-info/

echo "Debug bundle created. Share the .tar.gz file when seeking help."
```

### Useful Documentation

- **JupyterHub Docs:** https://jupyterhub.readthedocs.io/
- **Zero to JupyterHub (Z2JH):** https://z2jh.jupyter.org/
- **KubeSpawner:** https://jupyterhub-kubespawner.readthedocs.io/
- **Longhorn Docs:** https://longhorn.io/docs/
- **XNAT Plugin:** https://github.com/NrgXnat/xnat-jupyterhub-plugin
- **XNAT Documentation:** https://wiki.xnat.org/
- **AAF (Australian Access Federation):** https://aaf.edu.au/
- **Nginx Ingress Controller:** https://kubernetes.github.io/ingress-nginx/

---

## Quick Reference: Common Command Patterns

### Stop/Start User Server
```bash
# Stop
curl -X DELETE \
  -H "Authorization: token <token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/<username>/server

# Start
curl -X POST \
  -H "Authorization: token <token>" \
  http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api/users/<username>/server
```

### Upgrade JupyterHub
```bash
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyter \
  --values 5-jupyterhub-values.yaml
```

### Fix Ingress Buffers
```bash
# Run the post-install-ingress-fix.sh script
# Or manually apply annotations + patch configmap
```

### Check All Critical Components
```bash
kubectl get pods -n jupyter -l component=hub
kubectl get pods -n jupyter -l component=proxy
kubectl get svc -n jupyter proxy-public
kubectl get ingress -n jupyter jupyterhub
kubectl get pvc -n jupyter
```

---

