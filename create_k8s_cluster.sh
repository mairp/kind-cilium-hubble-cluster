#!/bin/bash

# Variables
CILIUM_NAMESPACE="kube-system"
KIND_CONFIG_FILE="configs/kind-config.yaml"  # Path to your Kind cluster configuration file
CLUSTER_NAME="cilium-demo"           # Name of the Kind cluster
MAX_RETRIES=10                       # Maximum retries for Cilium installation
UPDATE_CLI=false                     # Flag to update CLI tools

# Default versions
DEFAULT_KIND_VERSION="v0.22.0"
DEFAULT_HELM_VERSION="v3.17.1"
DEFAULT_CILIUM_VERSION="v1.18.0-pre.0"
DEFAULT_HUBBLE_VERSION="v1.17.1"

# Fetch the latest Cilium and Hubble versions
LATEST_CILIUM_VERSION=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest | jq -r '.tag_name')
LATEST_HUBBLE_VERSION=$(curl -s https://api.github.com/repos/cilium/hubble/releases/latest | jq -r '.tag_name')

if [ -z "$LATEST_CILIUM_VERSION" ]; then
    echo "Failed to fetch the latest Cilium version. Using default version."
    LATEST_CILIUM_VERSION=$DEFAULT_CILIUM_VERSION
fi

if [ -z "$LATEST_HUBBLE_VERSION" ]; then
    echo "Failed to fetch the latest Hubble version. Using default version."
    LATEST_HUBBLE_VERSION=$DEFAULT_HUBBLE_VERSION
fi

# Fetch the latest Kind version
LATEST_KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_KIND_VERSION" ]; then
    echo "Failed to fetch the latest Kind version. Using default version."
    LATEST_KIND_VERSION=$DEFAULT_KIND_VERSION
fi

# Fetch the latest Helm version
LATEST_HELM_VERSION=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_HELM_VERSION" ]; then
    echo "Failed to fetch the latest Helm version. Using default version."
    LATEST_HELM_VERSION=$DEFAULT_HELM_VERSION
fi

# Fetch the latest kubectl version
LATEST_KUBECTL_VERSION=$(curl -s https://dl.k8s.io/release/stable.txt)
if [ -z "$LATEST_KUBECTL_VERSION" ]; then
    echo "Failed to fetch the latest kubectl version. Using default version."
    LATEST_KUBECTL_VERSION="v1.20.0"  # Set a default version if fetching fails
fi

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --update) UPDATE_CLI=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Function to check if Kind is installed
is_kind_installed() {
    command -v kind > /dev/null 2>&1
}

# Function to install/update Kind
install_kind() {
    local version=$DEFAULT_KIND_VERSION
    if $UPDATE_CLI; then
        version=$LATEST_KIND_VERSION
    fi
    echo "Installing/updating Kind to version $version..."
    curl -Lo kind https://kind.sigs.k8s.io/dl/${version}/kind-linux-amd64
    chmod +x kind
    sudo mv kind /usr/local/bin/kind
    KIND_VERSION=$version
}

# Function to install/update Helm
install_helm() {
    local version=$DEFAULT_HELM_VERSION
    if $UPDATE_CLI; then
        version=$LATEST_HELM_VERSION
    fi
    if $UPDATE_CLI || ! command -v helm > /dev/null 2>&1; then
        echo "Installing/updating Helm to version $version..."
        curl -Lo get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod +x get_helm.sh
        ./get_helm.sh --version $version
        rm get_helm.sh
        HELM_VERSION=$version
    else
        echo "Helm is already installed and --update flag is not provided. Skipping update."
        HELM_VERSION=$(helm version --short | cut -d " " -f 2)
    fi
}

# Function to install/update kubectl
install_kubectl() {
    local version=$LATEST_KUBECTL_VERSION
    if $UPDATE_CLI || ! command -v kubectl > /dev/null 2>&1; then
        echo "Installing/updating kubectl to version $version..."
        curl -LO "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
        KUBECTL_VERSION=$version
    else
        echo "kubectl is already installed and --update flag is not provided. Skipping update."
        KUBECTL_VERSION=$(kubectl version --client --short | cut -d " " -f 3)
    fi
    echo "KUBECTL_VERSION is set to $KUBECTL_VERSION"
}

# Function to delete existing Kind cluster
delete_kind_cluster() {
    echo "Deleting existing Kind cluster..."
    kind delete cluster --name $CLUSTER_NAME || true
}

# Function to create Kind cluster
create_kind_cluster() {
    echo "Creating Kind cluster..."
    kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG_FILE
}

# Function to check Cilium status
check_cilium_status() {
    echo "Checking Cilium status..."
    cilium status --wait
    local status=$?
    if [ $status -eq 0 ]; then
        echo "Cilium is running."
    else
        echo "Cilium is not running."
    fi
    return $status
}

# Function to install Cilium using Helm
install_cilium() {
    echo "Installing Cilium version $LATEST_CILIUM_VERSION using Helm..."
    helm repo add cilium https://helm.cilium.io/
    helm repo update
    helm install cilium cilium/cilium --version $LATEST_CILIUM_VERSION --namespace $CILIUM_NAMESPACE --set global.kubeProxyReplacement=disabled --set global.hostServices.enabled=false --set global.externalIPs.enabled=true --set global.nodePort.enabled=true --set global.bpf.masquerade=true --set global.tunnel=disabled --set global.autoDirectNodeRoutes=true --set global.ipam.mode=kubernetes

    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        echo "Checking Cilium status, attempt $attempt/$MAX_RETRIES"
        if check_cilium_status; then
            echo "Cilium installed successfully."
            return 0
        else
            echo "Cilium installation attempt $attempt failed. Retrying..."
            sleep $((attempt * 20))
        fi
        attempt=$((attempt + 1))
    done
    
    echo "Failed to install Cilium after $MAX_RETRIES attempts."
    exit 1
}

# Function to install Hubble
install_hubble() {
    echo "Installing Hubble version $LATEST_HUBBLE_VERSION..."
    if check_cilium_status; then
        cilium hubble enable
        kubectl wait --for=condition=ready pod -l k8s-app=hubble-relay -n $CILIUM_NAMESPACE --timeout=300s
        echo "Hubble installed successfully."
    else
        echo "Cilium is not ready. Skipping Hubble installation."
        exit 1
    fi
}

# Main script logic

# Validate if Kind is installed
if ! is_kind_installed; then
    echo "Kind is not installed. Installing default version $DEFAULT_KIND_VERSION..."
    install_kind
    KIND_VERSION=$DEFAULT_KIND_VERSION
else
    KIND_VERSION=$(kind version | cut -d " " -f 2)
fi

# Install/update Helm
install_helm

# Install/update kubectl
install_kubectl

# Cluster management
delete_kind_cluster
create_kind_cluster

# Cilium installation
install_cilium

# Hubble installation
install_hubble

echo "Installation complete!"
echo "Kind ($KIND_VERSION), kubectl ($KUBECTL_VERSION), Helm ($HELM_VERSION), Cilium ($LATEST_CILIUM_VERSION), and Hubble ($LATEST_HUBBLE_VERSION)"
