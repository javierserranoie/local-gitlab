# GitLab Installation/Uninstallation Justfile
# Usage: just install        - Install GitLab
#        just uninstall      - Uninstall GitLab
#        just start          - Start GitLab (scale up all components)
#        just stop           - Stop GitLab (scale down all components)
#        just reset-password - Reset root password to password123
#        just registry-token [SCOPE] [REPO] - Get JWT token for registry access
#          Default (no params): Full access (catalog, push, pull for all repositories)
#          SCOPE: all (default), catalog, pull, push, push-pull
#          REPO: repository path (e.g., group/project) - required for pull/push/push-pull

NAMESPACE := "dev"
RELEASE_NAME := "gitlab"
CHART_REPO := "https://charts.gitlab.io"
CHART_NAME := "gitlab"
GITLAB_DOMAIN := "gitlab.dev.local"
REGISTRY_DOMAIN := "registry.dev.local"
GITLAB_USER := "root"

# Install GitLab using Helm
install:
    #!/usr/bin/env bash
    set -e
    echo "=== GitLab Installation Script ==="
    echo "Namespace: {{NAMESPACE}}"
    echo "Release Name: {{RELEASE_NAME}}"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if helm is available
    if ! command -v helm &> /dev/null; then
        echo "Error: helm is not installed or not in PATH"
        exit 1
    fi
    
    # Create namespace
    echo "Creating namespace {{NAMESPACE}}..."
    kubectl apply -f namespace.yaml
    
    # Create Traefik IngressClass and SSH IngressRouteTCP
    echo "Creating Traefik IngressClass..."
    kubectl apply -f ingressclass.yaml || echo "Ingress resources already exist, skipping..."
    
    # Configure Traefik with SSH entrypoint
    echo "Configuring Traefik with SSH entrypoint..."
    # Check if SSH entrypoint already exists
    if ! kubectl get deployment traefik -n kube-system -o yaml | grep -q "entryPoints.ssh.address"; then
        echo "Adding SSH entrypoint to Traefik..."
        kubectl patch deployment traefik -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--entryPoints.ssh.address=:22/tcp"}]' || echo "Failed to add SSH entrypoint arg"
        kubectl patch deployment traefik -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/ports/-", "value": {"containerPort": 22, "name": "ssh", "protocol": "TCP"}}]' || echo "Failed to add SSH container port"
        kubectl patch svc traefik -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "ssh", "port": 22, "protocol": "TCP", "targetPort": 22}}]' || echo "Failed to add SSH service port"
        echo "Waiting for Traefik to restart..."
        kubectl rollout status deployment/traefik -n kube-system --timeout=2m || echo "Traefik rollout timeout"
    else
        echo "SSH entrypoint already configured"
    fi
    
    # Add GitLab Helm repository
    echo "Adding GitLab Helm repository..."
    helm repo add gitlab {{CHART_REPO}} || echo "Repository already exists, updating..."
    helm repo update
    
    # Temporarily label cert-manager CRDs to allow Helm to manage them
    echo "Labeling existing cert-manager CRDs for Helm management..."
    for crd in $(kubectl get crd -o name | grep cert-manager.io 2>/dev/null); do
        kubectl label "$crd" \
          app.kubernetes.io/managed-by=Helm \
          meta.helm.sh/release-name={{RELEASE_NAME}} \
          meta.helm.sh/release-namespace={{NAMESPACE}} \
          --overwrite 2>/dev/null || true
        kubectl annotate "$crd" \
          meta.helm.sh/release-name={{RELEASE_NAME}} \
          meta.helm.sh/release-namespace={{NAMESPACE}} \
          --overwrite 2>/dev/null || true
    done || echo "CRD labeling skipped (cert-manager CRDs may not exist)"
    
    # Install GitLab
    echo "Installing GitLab Helm chart..."
    echo "Note: Disabling cert-manager and nginx-ingress (using existing Traefik)"
    helm upgrade --install {{RELEASE_NAME}} gitlab/{{CHART_NAME}} \
      --namespace {{NAMESPACE}} \
      --timeout 600s \
      --values values.yaml \
      --set cert-manager.install=false \
      --set cert-manager.installCRDs=false \
      --skip-crds || {
        echo "Installation failed. Cleaning up cert-manager CRD labels..."
        # Clean up cert-manager CRD labels
        for crd in $(kubectl get crd -o name | grep cert-manager.io 2>/dev/null); do
            kubectl label "$crd" app.kubernetes.io/managed-by- 2>/dev/null || true
            kubectl annotate "$crd" meta.helm.sh/release-name- meta.helm.sh/release-namespace- 2>/dev/null || true
        done
        exit 1
      }
    
    # Wait for GitLab toolbox pod to be ready
    echo ""
    echo "Waiting for GitLab toolbox pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=toolbox -n {{NAMESPACE}} --timeout=300s || echo "Toolbox pod not ready yet, continuing..."
    
    # Reset root password to default
    echo ""
    echo "Setting root password to default (password123)..."
    TOOLBOX_POD=$(kubectl get pods -n {{NAMESPACE}} -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$TOOLBOX_POD" ]; then
        kubectl exec -n {{NAMESPACE}} "$TOOLBOX_POD" -- gitlab-rails runner "u = User.find_by_username('root'); if u; u.password = 'password123'; u.password_confirmation = 'password123'; u.skip_confirmation!; u.unlock_access!; u.save!; puts 'Root password set to: password123'; else puts 'Root user not found'; end" 2>/dev/null || echo "Password reset skipped (GitLab may still be initializing)"
    else
        echo "Toolbox pod not found, password reset skipped"
    fi
    
    # Apply SSH ingress route (after GitLab Shell service exists)
    echo ""
    echo "Waiting for GitLab Shell service..."
    kubectl wait --for=condition=ready pod -l app=gitlab-shell -n {{NAMESPACE}} --timeout=300s 2>/dev/null || echo "GitLab Shell not ready yet, continuing..."
    echo "Applying SSH ingress route..."
    kubectl apply -f ingressclass.yaml || echo "SSH ingress route skipped"
    
    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "To check the status of your GitLab installation, run:"
    echo "  kubectl get pods -n {{NAMESPACE}}"
    echo ""
    echo "Default GitLab credentials:"
    echo "  Username: root"
    echo "  Password: password123"
    echo ""
    echo "To get the original generated password (if needed), run:"
    echo "  kubectl get secret {{RELEASE_NAME}}-gitlab-initial-root-password -n {{NAMESPACE}} -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "To access GitLab, you may need to configure DNS or add entries to /etc/hosts:"
    echo "  <INGRESS_IP> gitlab.dev.local"
    echo "  <INGRESS_IP> registry.dev.local"
    echo "  <INGRESS_IP> minio.dev.local"
    echo ""
    echo "Note: If you encounter 404 errors, ensure the Traefik IngressClass exists:"
    echo "  kubectl get ingressclass traefik"
    echo "If missing, create it with: kubectl apply -f ingressclass.yaml"
    echo ""
    echo "For SSH access (git push over SSH):"
    echo "  Test: ssh -T git@{{GITLAB_DOMAIN}}"

# Uninstall GitLab Helm release
uninstall:
    #!/usr/bin/env bash
    set -e
    echo "=== GitLab Uninstallation Script ==="
    echo "Namespace: {{NAMESPACE}}"
    echo "Release Name: {{RELEASE_NAME}}"
    echo ""
    
    # Check if helm is available
    if ! command -v helm &> /dev/null; then
        echo "Error: helm is not installed or not in PATH"
        exit 1
    fi
    
    # Uninstall GitLab Helm release
    echo "Uninstalling GitLab Helm release..."
    helm uninstall {{RELEASE_NAME}} --namespace {{NAMESPACE}} || echo "Release not found, skipping..."
    
    # Optionally delete namespace (uncomment if you want to remove the namespace)
    # echo "Deleting namespace {{NAMESPACE}}..."
    # kubectl delete namespace {{NAMESPACE}}
    
    echo ""
    echo "=== Uninstallation Complete ==="
    echo "Note: PVCs (Persistent Volume Claims) are preserved by default."
    echo "To remove them, manually delete the PVCs in the {{NAMESPACE}} namespace."

# Stop GitLab (scale down all components without uninstalling)
stop:
    #!/usr/bin/env bash
    set -e
    echo "=== Stopping GitLab ==="
    echo "Namespace: {{NAMESPACE}}"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Scale down all deployments
    echo "Scaling down deployments..."
    kubectl scale deployment --all --replicas=0 --namespace {{NAMESPACE}} || echo "No deployments found or already scaled down"
    
    # Scale down all statefulsets
    echo "Scaling down statefulsets..."
    kubectl scale statefulset --all --replicas=0 --namespace {{NAMESPACE}} || echo "No statefulsets found or already scaled down"
    
    # Scale down gitlab-runner if it exists
    echo "Scaling down GitLab Runner..."
    kubectl scale deployment --replicas=0 --namespace {{NAMESPACE}} -l app=gitlab-runner 2>/dev/null || echo "GitLab Runner not found or already scaled down"
    
    echo ""
    echo "=== GitLab Stopped ==="
    echo "All components have been scaled down to 0 replicas."
    echo "Data and configuration are preserved."
    echo ""
    echo "To start GitLab again, run: just start"

# Start GitLab (scale up all components)
start:
    #!/usr/bin/env bash
    set -e
    echo "=== Starting GitLab ==="
    echo "Namespace: {{NAMESPACE}}"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Scale up all deployments to 1 replica
    echo "Scaling up deployments..."
    kubectl scale deployment --all --replicas=1 --namespace {{NAMESPACE}} 2>/dev/null || echo "No deployments found or already running"
    
    # Scale up all statefulsets to 1 replica
    echo "Scaling up statefulsets..."
    kubectl scale statefulset --all --replicas=1 --namespace {{NAMESPACE}} 2>/dev/null || echo "No statefulsets found or already running"
    
    echo ""
    echo "=== GitLab Started ==="
    echo "All components are being scaled up to 1 replica."
    echo "Data and configuration are preserved."
    echo ""
    echo "To check the status, run:"
    echo "  kubectl get pods -n {{NAMESPACE}} -w"

# Reset root password to default (password123)
reset-password:
    #!/usr/bin/env bash
    set -e
    echo "=== Resetting GitLab Root Password ==="
    echo "Namespace: {{NAMESPACE}}"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Get toolbox pod
    TOOLBOX_POD=$(kubectl get pods -n {{NAMESPACE}} -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$TOOLBOX_POD" ]; then
        echo "Error: GitLab toolbox pod not found in namespace {{NAMESPACE}}"
        echo "Make sure GitLab is installed and running."
        exit 1
    fi
    
    echo "Found toolbox pod: $TOOLBOX_POD"
    echo "Resetting root password to: password123"
    echo ""
    
    # Reset password
    kubectl exec -n {{NAMESPACE}} "$TOOLBOX_POD" -- gitlab-rails runner "u = User.find_by_username('root'); if u; u.password = 'password123'; u.password_confirmation = 'password123'; u.skip_confirmation!; u.unlock_access!; u.save!; puts 'Root password successfully reset to: password123'; else puts 'Error: Root user not found'; exit 1; end" || {
        echo "Error: Failed to reset password. Make sure GitLab is fully initialized."
        exit 1
    }
    
    echo ""
    echo "=== Password Reset Complete ==="
    echo "Default GitLab credentials:"
    echo "  Username: root"
    echo "  Password: password123"

# Get JWT token for GitLab Container Registry access
# Usage: just registry-token [SCOPE] [REPO]
#   Without parameters: Gets token with catalog, push, and pull access to all repositories
#   SCOPE: catalog, pull, push, push-pull, or all (default: all)
#   REPO: repository path (e.g., group/project) - required for pull/push/push-pull
#   Set GITLAB_TOKEN environment variable with your Personal Access Token
registry-token SCOPE="all" REPO="":
    #!/usr/bin/env bash
    set -e
    echo "=== GitLab Registry JWT Token ==="
    
    if [ -z "${GITLAB_TOKEN}" ]; then
        echo "Error: GITLAB_TOKEN environment variable is not set"
        echo "Please set it with: export GITLAB_TOKEN=your_personal_access_token"
        echo ""
        echo "You can create a Personal Access Token at:"
        echo "  http://{{GITLAB_DOMAIN}}/-/user_settings/personal_access_tokens"
        echo ""
        echo "Required scopes:"
        echo "  - read_registry (for pull/catalog)"
        echo "  - write_registry (for push)"
        exit 1
    fi
    
    case "{{SCOPE}}" in
        all|"")
            echo "Getting JWT token with full access (catalog, push, pull for all repositories)..."
            # Multiple scopes: catalog access + push/pull for all repositories
            SCOPE_PARAM="registry:catalog:* repository:*:push repository:*:pull"
            ;;
        catalog)
            echo "Getting JWT token for catalog access..."
            SCOPE_PARAM="registry:catalog:*"
            ;;
        pull)
            if [ -z "{{REPO}}" ]; then
                echo "Error: Repository path is required for pull scope"
                echo "Usage: just registry-token pull group/project"
                exit 1
            fi
            echo "Getting JWT token for pull access to repository: {{REPO}}"
            SCOPE_PARAM="repository:{{REPO}}:pull"
            ;;
        push)
            if [ -z "{{REPO}}" ]; then
                echo "Error: Repository path is required for push scope"
                echo "Usage: just registry-token push group/project"
                exit 1
            fi
            echo "Getting JWT token for push access to repository: {{REPO}}"
            SCOPE_PARAM="repository:{{REPO}}:push"
            ;;
        push-pull)
            if [ -z "{{REPO}}" ]; then
                echo "Error: Repository path is required for push-pull scope"
                echo "Usage: just registry-token push-pull group/project"
                exit 1
            fi
            echo "Getting JWT token for push and pull access to repository: {{REPO}}"
            SCOPE_PARAM="repository:{{REPO}}:push,pull"
            ;;
        *)
            echo "Error: Invalid scope '{{SCOPE}}'"
            echo "Valid scopes: all (default), catalog, pull, push, push-pull"
            exit 1
            ;;
    esac
    
    echo ""
    echo "Requesting token from: http://{{GITLAB_DOMAIN}}/jwt/auth"
    echo "Scope: $SCOPE_PARAM"
    echo ""
    
    # Get JWT token
    # URL encode the scope parameter (spaces become %20)
    SCOPE_ENCODED=$(echo "$SCOPE_PARAM" | sed 's/ /%20/g')
    RESPONSE=$(curl -s -u "{{GITLAB_USER}}:${GITLAB_TOKEN}" \
      "http://{{GITLAB_DOMAIN}}/jwt/auth?service=container_registry&scope=${SCOPE_ENCODED}")
    
    # Check if jq is available
    if command -v jq &> /dev/null; then
        TOKEN=$(echo "$RESPONSE" | jq -r '.token')
        if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
            echo "Error: Failed to get token. Response:"
            echo "$RESPONSE" | jq '.'
            exit 1
        fi
    else
        # Fallback: extract token using grep/sed
        TOKEN=$(echo "$RESPONSE" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
        if [ -z "$TOKEN" ]; then
            echo "Error: Failed to get token. Response:"
            echo "$RESPONSE"
            exit 1
        fi
    fi
    
    echo "JWT Token:"
    echo "$TOKEN"
    echo ""
    echo "To use this token with curl:"
    echo "  curl -H \"Authorization: Bearer $TOKEN\" http://{{REGISTRY_DOMAIN}}/v2/"
    echo ""
    echo "To test catalog access:"
    echo "  curl -H \"Authorization: Bearer $TOKEN\" http://{{REGISTRY_DOMAIN}}/v2/_catalog"
    echo ""
    echo "To use with Docker, login with:"
    echo "  docker login {{REGISTRY_DOMAIN}} -u {{GITLAB_USER}} -p \${GITLAB_TOKEN}"
