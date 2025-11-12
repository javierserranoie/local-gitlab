# GitLab Helm Chart Installation

This repository contains the configuration files to install GitLab using the official GitLab Helm chart in the `dev` namespace.

## Prerequisites

- Kubernetes cluster (1.19+)
- kubectl configured to access your cluster
- Helm 3.x installed
- Sufficient cluster resources (recommended: 8+ CPU cores, 16+ GB RAM)
- Traefik ingress controller installed and configured

## Quick Start

### 1. Review and Customize Configuration

Before installation, review and customize the `values.yaml` file:

- Update the `global.hosts.domain` to match your domain
- Adjust resource limits based on your cluster capacity
- Configure storage sizes according to your needs
- Modify any other settings as required

### 2. Install GitLab

Run the installation:

```bash
just install
```

Or install manually:

```bash
# Create namespace
kubectl apply -f namespace.yaml

# Create Traefik IngressClass (required for Traefik ingress routing)
kubectl apply -f ingressclass.yaml

# Add GitLab Helm repository
helm repo add gitlab https://charts.gitlab.io
helm repo update

# Install GitLab
helm upgrade --install gitlab gitlab/gitlab \
  --namespace dev \
  --timeout 600s \
  --values values.yaml
```

### 3. Wait for Installation

Monitor the installation progress:

```bash
kubectl get pods -n dev -w
```

The installation may take 10-20 minutes depending on your cluster resources.

### 4. Get GitLab Root Password

The installation script automatically sets the root password to `password123` for convenience.

**Default credentials:**
- Username: `root`
- Password: `password123`

If you need to retrieve the original generated password:

```bash
kubectl get secret gitlab-gitlab-initial-root-password -n dev -o jsonpath='{.data.password}' | base64 -d
```

### 5. Access GitLab

1. Get the ingress IP address:
   ```bash
   kubectl get ingress -n dev
   ```

2. Add DNS entries or update `/etc/hosts`:
   ```
   <INGRESS_IP> gitlab.dev.local
   <INGRESS_IP> registry.dev.local
   <INGRESS_IP> minio.dev.local
   ```

3. Access GitLab in your browser:
   - URL: `http://gitlab.dev.local`
   - Username: `root`
   - Password: `password123` (default, set automatically during installation)

### 6. SSH Access for Git Push

SSH access is automatically configured during installation. The `just install` command:
- Configures Traefik with SSH entrypoint (port 22)
- Creates the SSH IngressRouteTCP resource

Test SSH connection:
```bash
ssh -T git@gitlab.dev.local
```

Use SSH for git operations:
```bash
git clone git@gitlab.dev.local:username/project.git
```

### 7. Access GitLab Container Registry

The GitLab Container Registry uses JWT authentication. You need to obtain a JWT token from GitLab first, then use it to access the registry.

#### Using curl

**Step 1:** Get a JWT token from GitLab using your Personal Access Token:

```bash
# For full access (catalog, push, pull for all repositories) - RECOMMENDED
curl -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=registry:catalog:*%20repository:*:push%20repository:*:pull"

# For listing repositories (catalog)
curl -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=registry:catalog:*"

# For pulling images from a specific repository
curl -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=repository:group/project:pull"

# For pushing images to a specific repository
curl -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=repository:group/project:push"

# For both push and pull
curl -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=repository:group/project:push,pull"
```

**Step 2:** Use the JWT token to access the registry:

```bash
# Extract token with full access and use it (requires jq)
JWT_TOKEN=$(curl -s -u "root:YOUR_PERSONAL_ACCESS_TOKEN" \
  "http://gitlab.dev.local/jwt/auth?service=container_registry&scope=registry:catalog:*%20repository:*:push%20repository:*:pull" \
  | jq -r '.token')

# Access registry endpoint
curl -H "Authorization: Bearer $JWT_TOKEN" http://registry.dev.local/v2/

# List repositories
curl -H "Authorization: Bearer $JWT_TOKEN" http://registry.dev.local/v2/_catalog
```

#### Using justfile commands

You can use the convenient `just` commands:

```bash
# Get JWT token with full access (catalog, push, pull for all repositories) - DEFAULT
just registry-token

# Or explicitly specify 'all'
just registry-token all

# Get JWT token for catalog access only
just registry-token catalog

# Get JWT token for pulling from a specific repository
just registry-token pull group/project

# Get JWT token for pushing to a specific repository
just registry-token push group/project

# Get JWT token for both push and pull on a specific repository
just registry-token push-pull group/project
```

**Note:** Set the `GITLAB_TOKEN` environment variable before running:
```bash
export GITLAB_TOKEN=your_personal_access_token
```

#### Using Docker

To use Docker with the registry, you need to login:

```bash
# Login to registry (Docker will handle JWT token exchange automatically)
docker login registry.dev.local -u root -p YOUR_PERSONAL_ACCESS_TOKEN
```

**Note:** Your Personal Access Token must have the `read_registry` scope (for pull) and/or `write_registry` scope (for push).

## Configuration

### Key Configuration Files

- `namespace.yaml` - Kubernetes namespace definition
- `ingressclass.yaml` - Traefik IngressClass resource (required for ingress routing)
- `values.yaml` - GitLab Helm chart values
- `justfile` - Installation, uninstallation, and management recipes (includes SSH configuration)

### Common Customizations

#### Change Domain

Edit `values.yaml`:
```yaml
global:
  hosts:
    domain: dev.local
    gitlab:
      name: gitlab.dev.local
```

#### Adjust Resources

Edit resource limits in `values.yaml`:
```yaml
gitlab:
  webservice:
    resources:
      requests:
        memory: "2Gi"
        cpu: "1000m"
```

#### Configure Storage

Edit persistence sizes:
```yaml
gitlab:
  gitaly:
    persistence:
      size: 100Gi
```

## Uninstallation

To uninstall GitLab:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Or manually:

```bash
helm uninstall gitlab --namespace dev
```

**Note:** Persistent Volume Claims (PVCs) are preserved by default. To remove them:

```bash
kubectl delete pvc -n dev --all
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n dev
```

### View Pod Logs

```bash
kubectl logs -n dev <pod-name>
```

### Check Events

```bash
kubectl get events -n dev --sort-by='.lastTimestamp'
```

### Common Issues

1. **Pods stuck in Pending**: Check if you have sufficient resources
2. **Image pull errors**: Ensure your cluster can access container registries
3. **Ingress returning 404**: Ensure the Traefik IngressClass exists:
   ```bash
   kubectl get ingressclass traefik
   ```
   If missing, create it:
   ```bash
   kubectl apply -f ingressclass.yaml
   ```
4. **422 error on login**: Clear browser cookies/cache for `gitlab.dev.local` and try again. If persistent, reset the root password:
   ```bash
   just reset-password
   ```
   Or manually:
   ```bash
   kubectl exec -n dev $(kubectl get pods -n dev -l app=toolbox -o jsonpath='{.items[0].metadata.name}') -- gitlab-rails runner "u = User.find_by_username('root'); u.password = 'password123'; u.password_confirmation = 'password123'; u.skip_confirmation!; u.unlock_access!; u.save!; puts 'Password reset complete'"
   ```

## Configure Gitlab Runner

### Registering a Runner (Local Installation)

If you're registering a GitLab runner locally (outside the Kubernetes cluster), you may encounter TLS certificate verification errors because Traefik uses certificates that don't match `gitlab.dev.local`.

#### Option 1: Use HTTP Instead of HTTPS (Easiest for Development)

The simplest solution for development is to register using HTTP:

```bash
gitlab-runner register \
  --url http://gitlab.dev.local \
  --token YOUR_RUNNER_TOKEN \
  --executor shell \
  --description "Local Runner" \
  --non-interactive
```

**Note:** Make sure GitLab is accessible via HTTP. If you're using Traefik, ensure the `web` entrypoint (HTTP) is enabled.

#### Option 1b: Skip TLS Verification (If HTTP Doesn't Work)

If you must use HTTPS, you can manually create the config file to skip TLS verification:

1. **First, create the config file manually:**

```bash
# Determine config location (user-mode vs system-mode)
CONFIG_FILE="$HOME/.gitlab-runner/config.toml"  # For user-mode
# Or: CONFIG_FILE="/etc/gitlab-runner/config.toml"  # For system-mode

mkdir -p "$(dirname "$CONFIG_FILE")"
```

2. **Create the config file with TLS verification disabled:**

```bash
cat > "$CONFIG_FILE" << EOF
concurrent = 1
check_interval = 0

[[runners]]
  name = "Local Runner"
  url = "https://gitlab.dev.local"
  token = "YOUR_RUNNER_TOKEN"
  executor = "shell"
  tls-ca-file = ""
EOF
```

3. **Verify the runner can connect:**

```bash
# For user-mode
gitlab-runner verify

# For system-mode
sudo gitlab-runner verify
```

4. **Start the runner:**

```bash
# For user-mode
gitlab-runner run

# For system-mode
sudo gitlab-runner start
```

#### Option 2: Get Traefik CA Certificate

If you want to properly verify the certificate, you can extract the CA certificate from Traefik:

```bash
# Get the Traefik certificate secret
kubectl get secret -n kube-system -o jsonpath='{.items[?(@.metadata.name=="traefik-default-cert")].data.tls\.crt}' | base64 -d > /tmp/traefik-cert.crt

# Or if using a different certificate provider, find the secret:
kubectl get secrets -n kube-system | grep traefik

# Then use it during registration
gitlab-runner register \
  --url https://gitlab.dev.local \
  --token YOUR_RUNNER_TOKEN \
  --tls-ca-file /tmp/traefik-cert.crt \
  --executor shell \
  --description "Local Runner"
```

#### Option 3: Use the Justfile Command

You can use the convenient `just` command to register a runner:

```bash
just register-runner YOUR_RUNNER_TOKEN
```

This command handles TLS certificate issues automatically for development environments.

### Getting a Runner Registration Token

To get a runner registration token:

1. **For a specific project:**
   - Go to your project → Settings → CI/CD → Runners
   - Copy the registration token

2. **For a group:**
   - Go to your group → Settings → CI/CD → Runners
   - Copy the registration token

3. **For instance-level (shared runners):**
   - Go to Admin Area → CI/CD → Runners
   - Copy the registration token

### Runner Configuration File Location

- **System-mode:** `/etc/gitlab-runner/config.toml`
- **User-mode:** `~/.gitlab-runner/config.toml`

### Troubleshooting Runner Issues

#### Runner Stuck at "Initializing executor providers"

**Note:** The message "Initializing executor providers" followed by "builds=0 max_builds=1" is **normal behavior**. The runner initializes and then waits for jobs. It's not stuck - it's waiting for CI/CD jobs to be assigned.

If you want to see more activity, you can:
- Check the GitLab UI to see if the runner is online (Settings → CI/CD → Runners)
- Trigger a CI/CD pipeline to test if the runner picks up jobs
- Check system logs if running as a service: `sudo journalctl -u gitlab-runner -f`
- Verify the runner connection: `gitlab-runner verify`

If the runner is **truly stuck** (no response, high CPU usage, or errors), try these solutions:

1. **Check if GitLab is accessible:**
   ```bash
   curl -v http://gitlab.dev.local
   gitlab-runner verify
   ```

2. **Verify the runner configuration:**
   ```bash
   # Check config file
   cat ~/.gitlab-runner/config.toml
   
   # Or for system-mode
   sudo cat /etc/gitlab-runner/config.toml
   ```

3. **Check for multiple runner processes:**
   ```bash
   ps aux | grep gitlab-runner
   ```
   If multiple runners are running, stop the ones you don't need:
   ```bash
   # Stop user-mode runner
   pkill -f "gitlab-runner run"
   
   # Or stop system-mode runner
   sudo systemctl stop gitlab-runner
   ```

4. **Check logs to see what's happening:**
   ```bash
   # Check system service logs (if running as system service)
   sudo journalctl -u gitlab-runner -f
   
   # For user-mode, logs go to stdout/stderr where you run the command
   # You can redirect to a file:
   gitlab-runner run > /tmp/gitlab-runner.log 2>&1
   
   # Verify the runner can connect to GitLab
   gitlab-runner verify
   ```

5. **Check if the shell executor can initialize:**
   The shell executor should work immediately. If it's hanging, try:
   - Ensure your shell environment is properly configured
   - Check that basic commands (`sh`, `bash`) are available
   - Verify file permissions in the working directory

6. **Try restarting the runner:**
   ```bash
   # Kill the stuck process
   pkill -f "gitlab-runner run"
   
   # Wait a moment
   sleep 2
   
   # Start again
   gitlab-runner run
   ```

7. **Check GitLab runner logs:**
   ```bash
   # User-mode logs are typically in stdout/stderr
   # System-mode logs:
   sudo journalctl -u gitlab-runner -f
   ```

8. **If using shell executor, ensure it's properly configured:**
   The config should have:
   ```toml
   [[runners]]
     executor = "shell"
   ```
   No additional shell executor configuration is needed for basic usage.

#### Runner Not Picking Up Jobs

If the runner is running but not picking up jobs:

1. **Check runner status in GitLab UI:**
   - Go to your project → Settings → CI/CD → Runners
   - Verify the runner shows as "online" and "active"

2. **Check runner tags match job tags:**
   - If your job has `tags: [docker]`, ensure the runner has the `docker` tag
   - Or set `runUntagged: true` in the runner config

3. **Verify runner is not locked to a specific project:**
   ```toml
   [[runners]]
     locked = false  # Should be false for shared runners
   ```

4. **Check concurrent job limits:**
   ```toml
   concurrent = 1  # Increase if you want multiple concurrent jobs
   ```

## Additional Resources

- [GitLab Helm Chart Documentation](https://docs.gitlab.com/charts/)
- [GitLab Helm Chart Values Reference](https://docs.gitlab.com/charts/charts/globals.html)
- [GitLab Installation Guide](https://docs.gitlab.com/ee/install/)

## Support

For issues related to:
- GitLab Helm chart: [GitLab Helm Chart Issues](https://gitlab.com/gitlab-org/charts/gitlab/-/issues)
- GitLab application: [GitLab Support](https://about.gitlab.com/support/)
