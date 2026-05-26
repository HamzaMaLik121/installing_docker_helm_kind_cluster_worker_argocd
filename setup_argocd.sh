#!/bin/bash

set -e

# ============================================================
#        FULL ARGOCD SETUP SCRIPT - AWS EC2 (Ubuntu)
#        Installs: Docker, Kind, Kubectl, Helm, ArgoCD
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

    # Add Docker's official GPG key & repo
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
    echo "✅ Docker installed: $(docker --version)"
fi

# ============================================================
# STEP 2: Fix Docker Permissions
# ============================================================
echo ""
echo "🔐 [2/7] Fixing Docker permissions..."

sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER

# Apply group without needing logout
if ! groups $USER | grep -q docker; then
    echo "⚠️  Adding $USER to docker group (takes effect in this session via newgrp)"
fi

# Run all subsequent docker commands with sudo fallback
DOCKER="sudo docker"
if docker ps &>/dev/null 2>&1; then
    DOCKER="docker"
fi

echo "✅ Docker permissions OK."

# ============================================================
# STEP 3: Install kubectl
# ============================================================
echo ""
echo "☸️  [3/7] Installing kubectl ($KUBECTL_VERSION)..."

if command -v kubectl &> /dev/null; then
    echo "✅ kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
    echo "✅ kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# ============================================================
# STEP 4: Install Kind
# ============================================================
echo ""
echo "📦 [4/7] Installing Kind ($KIND_VERSION)..."

if command -v kind &> /dev/null; then
    echo "✅ Kind already installed: $(kind version)"
else
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    echo "✅ Kind installed: $(kind version)"
fi

# ============================================================
# STEP 5: Install Helm
# ============================================================
echo ""
echo "⛵ [5/7] Installing Helm..."

if command -v helm &> /dev/null; then
    echo "✅ Helm already installed: $(helm version --short)"
else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "✅ Helm installed: $(helm version --short)"
fi

# ============================================================
# STEP 6: Create Kind Cluster
# ============================================================
echo ""
echo "☸️  [6/7] Creating Kind Cluster: $CLUSTER_NAME ..."

# Write kind config using 0.0.0.0 (works on all EC2 instances)
cat > $KIND_CONFIG <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: 6443
nodes:
  - role: control-plane
    image: kindest/node:v1.33.1
  - role: worker
    image: kindest/node:v1.33.1
  - role: worker
    image: kindest/node:v1.33.1
EOF

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "⚠️  Cluster '$CLUSTER_NAME' already exists. Deleting and recreating..."
    kind delete cluster --name $CLUSTER_NAME
fi

# Use sg docker to ensure docker group permissions are active
sg docker -c "kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG"

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

# Create namespace
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
# Install ArgoCD CLI
# ============================================================
echo ""
echo "🔧 Installing ArgoCD CLI..."

if command -v argocd &> /dev/null; then
    echo "✅ ArgoCD CLI already installed: $(argocd version --client --short 2>/dev/null || argocd version --client)"
else
    curl -sSL -o argocd-linux-amd64 \
        https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
    rm -f argocd-linux-amd64
    echo "✅ ArgoCD CLI installed."
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
sleep 5  # give secret a moment to populate

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
# Done — Access Instructions
# ============================================================
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || echo "<your-public-ip>")

echo ""
echo "========================================="
echo "   ✅ ArgoCD Setup Complete!"
echo "========================================="
echo ""
echo "📌 Cluster:    $CLUSTER_NAME"
echo "📌 Namespace:  $NAMESPACE"
echo "📌 Public IP:  $PUBLIC_IP"
echo "📌 Private IP: $PRIVATE_IP"
echo ""
echo "🌐 Access ArgoCD UI:"
echo "   kubectl port-forward svc/argocd-server -n $NAMESPACE 8080:443 --address=0.0.0.0 &"
echo "   Then open: https://$PUBLIC_IP:8080"
echo ""
echo "🔐 CLI Login:"
echo "   argocd login $PUBLIC_IP:8080 --username admin --password '$PASSWORD' --insecure"
echo ""
echo "👤 Username: admin"
echo "🔑 Password: $PASSWORD"
echo "========================================="
