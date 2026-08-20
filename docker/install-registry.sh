#!/bin/bash

# Configuration
DOCKER_VERSION="28.5.0"
DEFAULT_PORT="5000"
DEFAULT_STORAGE="/var/lib/registry"

# Color constants
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}   Container Registry Auto Installer (v2 / v3)    ${NC}"
echo -e "${BLUE}==================================================${NC}"

# 1. Check if run as root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error: Skrip ini harus dijalankan sebagai root atau dengan sudo.${NC}" >&2
    exit 1
fi

# Check if MacOS
if [ "$(uname)" = "Darwin" ]; then
    echo -e "${RED}Error: Skrip ini hanya mendukung sistem operasi Linux.${NC}" >&2
    exit 1
fi

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# 2. Check & Install Docker (Dokploy compatible version)
if command_exists docker; then
    echo -e "${GREEN}✓ Docker sudah terinstall.${NC}"
    docker_version_installed=$(docker --version | awk '{print $3}' | sed 's/,//')
    echo -e "Versi terinstall: ${docker_version_installed}"
else
    echo -e "${YELLOW}Docker belum terinstall. Menginstal Docker versi ${DOCKER_VERSION}...${NC}"
    curl -sSL https://get.docker.com | sh -s -- --version ${DOCKER_VERSION}
    
    if command_exists apt-mark; then
        echo -e "${BLUE}Mengunci versi paket Docker agar tidak ter-update otomatis...${NC}"
        apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras
    fi
    
    # Start and enable docker
    systemctl enable --now docker
    
    if command_exists docker; then
        echo -e "${GREEN}✓ Docker versi $(docker --version) berhasil di-install.${NC}"
    else
        echo -e "${RED}Error: Gagal menginstal Docker.${NC}" >&2
        exit 1
    fi
fi

# 3. Ask Registry Version (v2 or v3)
echo -e "\nPilih versi Container Registry yang ingin dideploy:"
echo -e "1) Registry v2 (Docker Distribution - Legacy/Stable: registry:2)"
echo -e "2) Registry v3 (CNCF Distribution OCI Spec - Modern: registry:3.0.0-alpha.1)"
read -rp "Pilihan Anda [1-2] (Default: 2): " choice
choice=${choice:-2}

if [ "$choice" = "1" ]; then
    REGISTRY_IMAGE="registry:2"
    VERSION_NAME="v2"
else
    REGISTRY_IMAGE="registry:3.0.0-alpha.1"
    VERSION_NAME="v3"
fi

# 4. Storage & Port Configuration
read -rp "Tentukan port ekspos registry (Default: $DEFAULT_PORT): " PORT
PORT=${PORT:-$DEFAULT_PORT}

# Check if port is in use
if command_exists ss; then
    if ss -tulnp | grep -q ":${PORT} "; then
        echo -e "${RED}Error: Port ${PORT} sudah digunakan oleh service lain.${NC}" >&2
        exit 1
    fi
fi

read -rp "Tentukan direktori penyimpanan data (Default: $DEFAULT_STORAGE): " STORAGE_DIR
STORAGE_DIR=${STORAGE_DIR:-$DEFAULT_STORAGE}

# Create storage dir if not exists
mkdir -p "$STORAGE_DIR"

# 5. Autentikasi Configuration
read -rp "Aktifkan autentikasi Username & Password? [y/N]: " ENABLE_AUTH
ENABLE_AUTH=${ENABLE_AUTH:-n}

AUTH_FLAGS=""
IS_AUTH_ENABLED=false
if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
    read -rp "Masukkan Username: " AUTH_USER
    read -rsp "Masukkan Password: " AUTH_PASS
    echo ""
    
    AUTH_DIR="${STORAGE_DIR}/auth"
    mkdir -p "$AUTH_DIR"
    
    echo -e "${BLUE}Membuat file kredensial htpasswd...${NC}"
    # Pastikan image sudah ada dengan pull terlebih dahulu
    docker pull -q "${REGISTRY_IMAGE}"
    docker run --rm --entrypoint htpasswd "${REGISTRY_IMAGE}" -Bbn "$AUTH_USER" "$AUTH_PASS" > "${AUTH_DIR}/htpasswd" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "${AUTH_DIR}/htpasswd" ]; then
        echo -e "${GREEN}✓ File htpasswd berhasil dibuat.${NC}"
        AUTH_FLAGS="-v ${AUTH_DIR}:/auth -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=Registry-Realm -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd"
        IS_AUTH_ENABLED=true
    else
        echo -e "${RED}Gagal membuat file htpasswd. Melanjutkan tanpa autentikasi...${NC}"
    fi
fi

# 6. Clean up old registry container if exists
if docker ps -a --format '{{.Names}}' | grep -Eq "^docker-registry$"; then
    echo -e "${YELLOW}Menghapus container docker-registry lama...${NC}"
    docker rm -f docker-registry >/dev/null 2>&1
fi

# 7. Deploy Registry
echo -e "${BLUE}Mendeploy Container Registry ${VERSION_NAME} menggunakan image ${REGISTRY_IMAGE}...${NC}"
docker run -d \
    --name docker-registry \
    --restart always \
    -p "${PORT}":5000 \
    -v "${STORAGE_DIR}":/var/lib/registry \
    ${AUTH_FLAGS} \
    "${REGISTRY_IMAGE}"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}   Container Registry Berhasil Dideploy!          ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "Versi: ${VERSION_NAME} (${REGISTRY_IMAGE})"
    echo -e "Port ekspos: ${PORT}"
    echo -e "Direktori Storage: ${STORAGE_DIR}"
    echo -e "\nCara Penggunaan (Push & Pull):"
    if [ "$IS_AUTH_ENABLED" = true ]; then
        echo -e "0. Login ke registry terlebih dahulu:"
        echo -e "   ${YELLOW}docker login localhost:${PORT}${NC} (masukkan username dan password Anda)"
    fi
    echo -e "1. Tag image Anda:"
    echo -e "   ${YELLOW}docker tag <image-name> localhost:${PORT}/<image-name>${NC}"
    echo -e "2. Push ke registry:"
    echo -e "   ${YELLOW}docker push localhost:${PORT}/<image-name>${NC}"
    echo -e "3. Pull dari registry:"
    echo -e "   ${YELLOW}docker pull localhost:${PORT}/<image-name>${NC}"
    echo -e "\nCatatan: Jika diakses dari host luar, pastikan mengonfigurasi insecure-registries di daemon.json atau menggunakan TLS/Reverse Proxy."
else
    echo -e "${RED}Error: Gagal mendeploy container registry.${NC}" >&2
    exit 1
fi
