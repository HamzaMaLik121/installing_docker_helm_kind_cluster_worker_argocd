#!/bin/bash

set -e

# ============================================================
#        FULL ARGOCD SETUP SCRIPT - AWS EC2 (Ubuntu)
#        Installs: Docker, Kind, Kubectl, Helm, ArgoCD
#        Enhanced: Docker socket perms, private IP support
# ============================================================

CLUSTER_NAME="argocd-cluster"
NAMESPACE="argocd"
KIND_CONFIG="kind-config.yaml"
KIND_VERSION="v0.30.0"
KUBECTL_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)

echo "========================================="
echo "   🚀 Full ArgoCD Setup Script"
echo "========================================="

# ---------------------------
# Auto-detect Private IP
# ---------------------------
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "🌐 Detected Private IP: $PRIVATE_IP"

# ============================================================
# STEP 0: Fix Docker Socket Permissions (upfront)
# ============================================================
echo ""
echo "🔧 [0/7] Fixing Docker socket permissions..."

# Add user to docker group
sudo usermod -aG docker $USER 2>/dev/null || true

# Fix socket permissions immediately (no logout needed)
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# Verify docker works now
if docker ps &>/dev/null; then
    echo "✅ Docker socket accessible without sudo."
    DOCKER="docker"
else
    echo "⚠️  Falling back to sudo docker."
    DOCKER="sudo docker"
fi

# ============================================================
# STEP 1: Install Docker
# ============================================================
echo ""
echo "🐳 [1/7] Installing Docker..."

if command -v docker &> /dev/null; then
    echo "✅ Docker already installed: $(docker --version)"
else
    sudo apt-get update -y
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Fix permissions right after install
    sudo usermod -aG docker $USER
    sudo chmod 666 /var/run/docker.sock

    echo "✅ Docker installed: $(docker --version)"
fi

sudo systemctl enable docker
sudo systemctl start docker

# Re-check after install
if docker ps &>/dev/null; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

echo "✅ Docker is running."

# ============================================================
# STEP 2: Install kubectl
# ============================================================
echo ""
echo "☸️  [2/7] Installing kubectl ($KUBECTL_VERSION)..."

if command -v kubectl &> /dev/null; then
    echo "✅ kubectl already installed: $(kubectl version --client 2>/dev/null | head -1)"
else
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
    echo "✅ kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
fi

# ============================================================
# STEP 3: Install Kind
# ============================================================
echo ""
echo "📦 [3/7] Installing Kind ($KIND_VERSION)..."

if command -v kind &> /dev/null; then
    echo "✅ Kind already installed: $(kind version)"
else
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    echo "✅ Kind installed: $(kind version)"
fi

# ============================================================
# STEP 4: Install Helm
# ============================================================
echo ""
echo "⛵ [4/7] Installing Helm..."

if command -v helm &> /dev/null; then
    echo "✅ Helm already installed: $(helm version --short)"
else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "✅ Helm installed: $(helm version --short)"
fi

# ============================================================
# STEP 5: Install ArgoCD CLI
# ============================================================
echo ""
echo "🔧 [5/7] Installing ArgoCD CLI..."

if command -v argocd &> /dev/null; then
    echo "✅ ArgoCD CLI already installed: $(argocd version --client 2>/dev/null | head -1)"
else
    curl -sSL -o argocd-linux-amd64 \
        https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
    rm -f argocd-linux-amd64
    echo "✅ ArgoCD CLI installed."
fi

# ============================================================
# STEP 6: Create Kind Cluster with Private IP
# ============================================================
echo ""
echo "☸️  [6/7] Creating Kind Cluster: $CLUSTER_NAME ..."
echo "📌 Using Private IP: $PRIVATE_IP for API server"

cat > $KIND_CONFIG <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "$PRIVATE_IP"
  apiServerPort: 6443
nodes:
  - role: control-plane
    image: kindest/node:v1.33.1
  - role: worker
    image: kindest/node:v1.33.1
  - role: worker
    image: kindest/node:v1.33.1
EOF

echo "📄 Kind config written:"
cat $KIND_CONFIG

# Delete existing cluster if present
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "⚠️  Cluster '$CLUSTER_NAME' already exists. Deleting and recreating..."
    kind delete cluster --name $CLUSTER_NAME
fi

# Create cluster — use sg docker if needed
if $DOCKER ps &>/dev/null; then
    kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG
else
    sg docker -c "kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG"
fi

echo "✅ Kind cluster '$CLUSTER_NAME' is ready."
kubectl cluster-info --context kind-$CLUSTER_NAME
kubectl get nodes

# ============================================================
# STEP 7: Install ArgoCD
# ============================================================
echo ""
echo "🚀 [7/7] Installing ArgoCD..."
echo "========================================="
echo "Choose installation method:"
echo "  1) Helm       — recommended, customizable"
echo "  2) Manifests  — simple, good for demos"
echo "-----------------------------------------"
read -p "Enter choice [1 or 2]: " choice

kubectl create namespace $NAMESPACE 2>/dev/null || echo "⚠️  Namespace '$NAMESPACE' already exists."

install_helm() {
    echo "⛵ Installing ArgoCD via Helm..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
        --namespace $NAMESPACE \
        --set server.service.type=ClusterIP \
        --wait --timeout 5m
}

install_manifests() {
    echo "📄 Installing ArgoCD via official manifests..."
    kubectl apply -n $NAMESPACE \
        -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
}

if [ "$choice" == "1" ]; then
    install_helm
elif [ "$choice" == "2" ]; then
    install_manifests
else
    echo "❌ Invalid choice. Defaulting to Manifests..."
    install_manifests
fi

# ============================================================
# Wait for ArgoCD to be Ready
# ============================================================
echo ""
echo "⏳ Waiting for ArgoCD server to be ready (up to 5 min)..."
kubectl wait --for=condition=Available deployment/argocd-server \
    -n $NAMESPACE --timeout=300s || true

echo ""
kubectl get pods -n $NAMESPACE
echo ""
kubectl get svc -n $NAMESPACE

# ============================================================
# Fetch Admin Password
# ============================================================
echo ""
echo "🔑 Fetching ArgoCD initial admin password..."
sleep 5

PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
    -n $NAMESPACE \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [ -z "$PASSWORD" ]; then
    echo "⚠️  Password not ready yet. Run this manually later:"
    echo "    kubectl get secret argocd-initial-admin-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
else
    echo "✅ Admin Password: $PASSWORD"
fi

# ============================================================
# Start Port-Forward with Private IP binding
# ============================================================
echo ""
echo "🔁 Starting port-forward on $PRIVATE_IP:8080 ..."
pkill -f "port-forward.*argocd-server" 2>/dev/null || true
sleep 1
kubectl port-forward svc/argocd-server -n $NAMESPACE 8080:443 --address=0.0.0.0 &
sleep 3

# ============================================================
# Auto Login via CLI
# ============================================================
echo ""
echo "🔐 Logging in to ArgoCD CLI..."
if [ -n "$PASSWORD" ]; then
    argocd login $PRIVATE_IP:8080 \
        --username admin \
        --password "$PASSWORD" \
        --insecure && echo "✅ ArgoCD CLI logged in." || \
    argocd login localhost:8080 \
        --username admin \
        --password "$PASSWORD" \
        --insecure && echo "✅ ArgoCD CLI logged in via localhost."
else
    echo "⚠️  Skipping auto-login — password not ready."
fi

# ============================================================
# Done
# ============================================================
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com 2>/dev/null || echo "<your-public-ip>")

echo ""
echo "========================================="
echo "   ✅ ArgoCD Setup Complete!"
echo "========================================="
echo ""
echo "📌 Cluster:     $CLUSTER_NAME"
echo "📌 Namespace:   $NAMESPACE"
echo "📌 Private IP:  $PRIVATE_IP"
echo "📌 Public IP:   $PUBLIC_IP"
echo ""
echo "🌐 ArgoCD UI:   http://$PUBLIC_IP:8080"
echo "               http://$PRIVATE_IP:8080  (within VPC)"
echo ""
echo "🔐 CLI Login (if needed):"
echo "   argocd login $PRIVATE_IP:8080 --username admin --password '$PASSWORD' --insecure"
echo "   argocd login localhost:8080   --username admin --password '$PASSWORD' --insecure"
echo ""
echo "👤 Username: admin"
echo "🔑 Password: $PASSWORD"
echo ""
echo "📌 kubeconfig server is set to: $PRIVATE_IP:6443"
echo "   kubectl config view | grep server"
echo "========================================="
