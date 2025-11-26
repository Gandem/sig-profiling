#!/bin/bash
set -e

CRI_DOCKERD_VERSION="0.3.21"
CNI_PLUGIN_VERSION="v1.8.0"

echo "Installing requirements for minikube with driver=none on Ubuntu host..."

# Update system
echo "Updating system packages..."
sudo apt-get update

# Install Docker
echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group
    sudo usermod -aG docker $USER
    echo "Docker installed. You may need to log out and back in for group changes to take effect."
else
    echo "Docker already installed."
fi

# Install conntrack and other dependencies
echo "Installing conntrack and dependencies..."
sudo apt-get install -y \
    conntrack \
    socat \
    ebtables \
    ethtool \
    cri-tools \
    wget

# Install cri-dockerd (required for Kubernetes v1.24+ with Docker)
echo "Installing cri-dockerd..."
if ! command -v cri-dockerd &> /dev/null; then
    # Detect Ubuntu version
    UBUNTU_CODENAME=$(lsb_release -cs)
    ARCH=$(dpkg --print-architecture)

    echo "Detected Ubuntu $UBUNTU_CODENAME ($ARCH)"

    # Map noble (24.04) to jammy (22.04) since noble package isn't available yet
    case "$UBUNTU_CODENAME" in
        noble)
            echo "Using jammy package for noble (24.04)"
            UBUNTU_CODENAME="jammy"
            ;;
    esac

    # Download the appropriate .deb package
    DEB_FILE="cri-dockerd_${CRI_DOCKERD_VERSION}.3-0.ubuntu-${UBUNTU_CODENAME}_${ARCH}.deb"
    DEB_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/${DEB_FILE}"

    echo "Downloading cri-dockerd from $DEB_URL"
    wget "$DEB_URL"

    sudo dpkg -i "$DEB_FILE" || sudo apt-get install -f -y
    rm "$DEB_FILE"

    sudo systemctl enable cri-docker.socket
    sudo systemctl start cri-docker.service
    echo "cri-dockerd installed and started."
else
    echo "cri-dockerd already installed."
fi

# Install CNI plugins (required for Kubernetes v1.24+ with none driver)
echo "Installing CNI plugins..."
CNI_PLUGIN_INSTALL_DIR="/opt/cni/bin"
if [ ! -d "$CNI_PLUGIN_INSTALL_DIR" ] || [ -z "$(ls -A $CNI_PLUGIN_INSTALL_DIR)" ]; then
    # Detect architecture
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64)
            CNI_ARCH="amd64"
            ;;
        arm64)
            CNI_ARCH="arm64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    CNI_PLUGIN_TAR="cni-plugins-linux-${CNI_ARCH}-${CNI_PLUGIN_VERSION}.tgz"

    echo "Downloading CNI plugins ${CNI_PLUGIN_VERSION} for ${CNI_ARCH}..."
    curl -LO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/${CNI_PLUGIN_TAR}"

    sudo mkdir -p "$CNI_PLUGIN_INSTALL_DIR"
    sudo tar -xf "$CNI_PLUGIN_TAR" -C "$CNI_PLUGIN_INSTALL_DIR"
    rm "$CNI_PLUGIN_TAR"

    echo "CNI plugins installed to $CNI_PLUGIN_INSTALL_DIR"
else
    echo "CNI plugins already installed."
fi

# Install kubectl
echo "Installing kubectl..."
if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    echo "kubectl installed."
else
    echo "kubectl already installed."
fi

# Install minikube
echo "Installing minikube..."
if ! command -v minikube &> /dev/null; then
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    echo "minikube installed."
else
    echo "minikube already installed."
fi

# Configure system for Kubernetes
echo "Configuring system for Kubernetes..."

# Disable swap (required for Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load required kernel modules
sudo modprobe br_netfilter
sudo modprobe overlay

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
overlay
EOF

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

echo ""
echo "✅ Installation complete!"
echo ""
echo "Versions installed:"
docker --version
kubectl version --client
minikube version
cri-dockerd --version 2>/dev/null || echo "cri-dockerd: $(cri-dockerd --version 2>&1 | head -1)"
echo ""
echo "To start minikube with driver=none, run:"
echo "  sudo minikube start --driver=none"
echo ""
echo "Note: With driver=none, you need to run minikube commands as root (sudo)."
echo "After starting minikube, run:"
echo "  sudo chown -R \$USER \$HOME/.kube \$HOME/.minikube"
echo "  chmod -R u+wrx \$HOME/.kube \$HOME/.minikube"
