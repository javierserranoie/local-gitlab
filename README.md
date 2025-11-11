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

### 6. Access GitLab Container Registry

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
- `justfile` - Installation and uninstallation recipes

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

## Additional Resources

- [GitLab Helm Chart Documentation](https://docs.gitlab.com/charts/)
- [GitLab Helm Chart Values Reference](https://docs.gitlab.com/charts/charts/globals.html)
- [GitLab Installation Guide](https://docs.gitlab.com/ee/install/)

## Support

For issues related to:
- GitLab Helm chart: [GitLab Helm Chart Issues](https://gitlab.com/gitlab-org/charts/gitlab/-/issues)
- GitLab application: [GitLab Support](https://about.gitlab.com/support/)
