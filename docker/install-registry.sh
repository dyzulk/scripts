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

# Define command_exists early so it can be used by all functions
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Helper function to read input safely in both piped and interactive environments
read_input() {
    local prompt="$1"
    local var_name="$2"
    local is_silent="$3"
    local val=""

    if [ -t 0 ]; then
        # Stdin is a TTY, read normally
        if [ "$is_silent" = "silent" ]; then
            read -rsp "$prompt" val
            echo ""
        else
            read -rp "$prompt" val
        fi
    else
        # Stdin is piped (e.g., curl | bash), try to read from /dev/tty
        if [ -c /dev/tty ] && [ -r /dev/tty ]; then
            if [ "$is_silent" = "silent" ]; then
                read -rsp "$prompt" val < /dev/tty
                echo ""
            else
                read -rp "$prompt" val < /dev/tty
            fi
        else
            # Non-interactive fallback (e.g., cron or VM provision scripts)
            val=""
        fi
    fi
    eval "$var_name=\"\$val\""
}

# 1. Check if run as root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error: Skrip ini harus dijalankan sebagai root atau dengan sudo.${NC}" >&2
    exit 1
fi

# Check if Linux
if [ "$(uname)" != "Linux" ]; then
    echo -e "${RED}Error: Skrip ini hanya mendukung sistem operasi Linux.${NC}" >&2
    exit 1
fi

# Argument Parsing for Uninstall
UNINSTALL=false
if [ "$1" = "uninstall" ] || [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
    UNINSTALL=true
fi

uninstall_registry() {
    echo -e "${YELLOW}Memulai proses uninstall (Full Clean)...${NC}"
    
    # 1. Stop and remove containers
    if command_exists docker; then
        if docker ps -a --format '{{.Names}}' | grep -Eq "^docker-registry$"; then
            echo -e "${BLUE}Menghentikan dan menghapus container docker-registry...${NC}"
            docker rm -f docker-registry >/dev/null 2>&1
        fi
        
        if docker ps -a --format '{{.Names}}' | grep -Eq "^registry-proxy$"; then
            echo -e "${BLUE}Menghentikan dan menghapus container registry-proxy (Caddy)...${NC}"
            docker rm -f registry-proxy >/dev/null 2>&1
        fi
        
        # 2. Remove Docker Network
        if docker network inspect registry-net >/dev/null 2>&1; then
            echo -e "${BLUE}Menghapus network registry-net...${NC}"
            docker network rm registry-net >/dev/null 2>&1
        fi
    else
        echo -e "${YELLOW}Docker tidak terdeteksi, melewati proses pembersihan container.${NC}"
    fi
    
    # 3. Clean up storage data
    read_input "Tentukan direktori data yang ingin dihapus (Default: $DEFAULT_STORAGE): " STORAGE_DIR
    STORAGE_DIR=${STORAGE_DIR:-$DEFAULT_STORAGE}
    
    if [ -d "$STORAGE_DIR" ]; then
        echo -e "${RED}Peringatan: Seluruh data registry di '$STORAGE_DIR' akan dihapus permanen!${NC}"
        read_input "Apakah Anda yakin ingin menghapus folder ini? [y/N]: " CONFIRM
        CONFIRM=${CONFIRM:-n}
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}Menghapus direktori data: $STORAGE_DIR...${NC}"
            rm -rf "$STORAGE_DIR"
            echo -e "${GREEN}✓ Direktori data berhasil dihapus.${NC}"
        else
            echo -e "${YELLOW}Penghapusan direktori data dibatalkan oleh pengguna.${NC}"
        fi
    else
        echo -e "${YELLOW}Direktori $STORAGE_DIR tidak ditemukan. Tidak ada data yang dihapus.${NC}"
    fi
    
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}   Uninstall Selesai! (Resource bersih)           ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    exit 0
}

# Run uninstall if argument is active
if [ "$UNINSTALL" = true ]; then
    uninstall_registry
fi

# 2. Check & Install Docker
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

# 3. Ask Registry Version
echo -e "\nPilih versi Container Registry yang ingin dideploy:"
echo -e "1) Registry v2 (Docker Distribution - Legacy/Stable: registry:2)"
echo -e "2) Registry v3 (CNCF Distribution OCI Spec - Modern: registry:3.0.0-alpha.1)"
read_input "Pilihan Anda [1-2] (Default: 2): " choice
choice=${choice:-2}

if [ "$choice" = "1" ]; then
    REGISTRY_IMAGE="registry:2"
    VERSION_NAME="v2"
else
    REGISTRY_IMAGE="registry:3.0.0-alpha.1"
    VERSION_NAME="v3"
fi

# 4. Storage Configuration
read_input "Tentukan direktori penyimpanan data (Default: $DEFAULT_STORAGE): " STORAGE_DIR
STORAGE_DIR=${STORAGE_DIR:-$DEFAULT_STORAGE}
mkdir -p "$STORAGE_DIR"

# 5. Authentication Configuration
read_input "Aktifkan autentikasi Username & Password? [y/N]: " ENABLE_AUTH
ENABLE_AUTH=${ENABLE_AUTH:-n}

AUTH_FLAGS=""
IS_AUTH_ENABLED=false
if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
    read_input "Masukkan Username: " AUTH_USER
    read_input "Masukkan Password: " AUTH_PASS "silent"
    
    AUTH_DIR="${STORAGE_DIR}/auth"
    mkdir -p "$AUTH_DIR"
    
    echo -e "${BLUE}Membuat file kredensial htpasswd...${NC}"
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

# 6. Reverse Proxy & ACME Configuration
read_input "Aktifkan Reverse Proxy (Caddy)? [y/N]: " ENABLE_PROXY
ENABLE_PROXY=${ENABLE_PROXY:-n}

IS_PROXY_ENABLED=false
USE_HTTPS=false

if [[ "$ENABLE_PROXY" =~ ^[Yy]$ ]]; then
    IS_PROXY_ENABLED=true
    
    read_input "Aktifkan HTTPS/SSL? [y/N]: " ENABLE_HTTPS
    ENABLE_HTTPS=${ENABLE_HTTPS:-n}
    
    if [[ "$ENABLE_HTTPS" =~ ^[Yy]$ ]]; then
        USE_HTTPS=true
        read_input "Masukkan Domain Name (misal: registry.kamu.com): " DOMAIN_NAME
        read_input "Masukkan Email untuk Kontak ACME: " ACME_EMAIL
        
        echo -e "\nPilih Provider ACME:"
        echo -e "1) Let's Encrypt"
        echo -e "2) ZeroSSL (Membutuhkan EAB)"
        echo -e "3) Custom ACME (misal: Step-CA / Local CA)"
        read_input "Pilihan Anda [1-3] (Default: 1): " ACME_CHOICE
        ACME_CHOICE=${ACME_CHOICE:-1}
        
        if [ "$ACME_CHOICE" = "2" ]; then
            read_input "Masukkan ZeroSSL EAB KID: " EAB_KID
            read_input "Masukkan ZeroSSL EAB HMAC Key: " EAB_HMAC
        elif [ "$ACME_CHOICE" = "3" ]; then
            read_input "Masukkan ACME Directory URL (misal: https://step-ca.local/acme/acme/directory): " ACME_URL
            read_input "Masukkan path file Root CA Certificate lokal (opsional): " CUSTOM_CA_PATH
        fi
    else
        # Pada HTTP, Caddy dikonfigurasi sebagai catch-all (:80) sehingga bisa diakses dari IP/domain apa saja.
        # Input ini hanya digunakan untuk menampilkan petunjuk cara penggunaan di akhir skrip.
        read_input "Masukkan Domain Name / Host IP utama untuk petunjuk HTTP (Default: localhost): " DOMAIN_NAME
        DOMAIN_NAME=${DOMAIN_NAME:-localhost}
    fi
else
    # Tanpa Reverse Proxy: Butuh Port ekspos langsung ke host
    read_input "Tentukan port ekspos registry ke host (Default: $DEFAULT_PORT): " PORT
    PORT=${PORT:-$DEFAULT_PORT}
    
    if command_exists ss; then
        if ss -tulnp | grep -q ":${PORT} "; then
            echo -e "${RED}Error: Port ${PORT} sudah digunakan oleh service lain.${NC}" >&2
            exit 1
        fi
    fi
fi

# 7. Network Creation (jika menggunakan proxy)
if [ "$IS_PROXY_ENABLED" = true ]; then
    if ! docker network inspect registry-net >/dev/null 2>&1; then
        echo -e "${BLUE}Membuat docker network: registry-net...${NC}"
        docker network create registry-net >/dev/null
    fi
fi

# 8. Clean up old containers
if docker ps -a --format '{{.Names}}' | grep -Eq "^docker-registry$"; then
    echo -e "${YELLOW}Menghapus container docker-registry lama...${NC}"
    docker rm -f docker-registry >/dev/null 2>&1
fi

if docker ps -a --format '{{.Names}}' | grep -Eq "^registry-proxy$"; then
    echo -e "${YELLOW}Menghapus container registry-proxy lama...${NC}"
    docker rm -f registry-proxy >/dev/null 2>&1
fi

# 9. Deploy Registry Container
echo -e "${BLUE}Mendeploy Container Registry ${VERSION_NAME}...${NC}"

if [ "$IS_PROXY_ENABLED" = true ]; then
    # Jika pakai proxy, taruh di network dan tidak ekspos port ke publik
    docker run -d \
        --name docker-registry \
        --network registry-net \
        --restart always \
        -v "${STORAGE_DIR}":/var/lib/registry \
        ${AUTH_FLAGS} \
        "${REGISTRY_IMAGE}"
else
    # Tanpa proxy, ekspos port langsung ke host
    docker run -d \
        --name docker-registry \
        --restart always \
        -p "${PORT}":5000 \
        -v "${STORAGE_DIR}":/var/lib/registry \
        ${AUTH_FLAGS} \
        "${REGISTRY_IMAGE}"
fi

# 10. Configure and Deploy Caddy (jika proxy aktif)
if [ "$IS_PROXY_ENABLED" = true ]; then
    echo -e "${BLUE}Mengonfigurasi Caddy Reverse Proxy...${NC}"
    CADDY_DIR="${STORAGE_DIR}/caddy"
    mkdir -p "${CADDY_DIR}/data" "${CADDY_DIR}/config"
    
    # Generate Caddyfile
    CADDYFILE_PATH="${CADDY_DIR}/Caddyfile"
    
    if [ "$USE_HTTPS" = true ]; then
        if [ "$ACME_CHOICE" = "1" ]; then
            # Let's Encrypt
            cat <<EOF > "$CADDYFILE_PATH"
$DOMAIN_NAME {
    tls $ACME_EMAIL
    reverse_proxy docker-registry:5000
}
EOF
        elif [ "$ACME_CHOICE" = "2" ]; then
            # ZeroSSL dengan EAB
            cat <<EOF > "$CADDYFILE_PATH"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca https://acme.zerossl.com/v2/DV90
        eab $EAB_KID $EAB_HMAC
    }
    reverse_proxy docker-registry:5000
}
EOF
        elif [ "$ACME_CHOICE" = "3" ]; then
            # Custom ACME (Step-CA)
            if [ -n "$CUSTOM_CA_PATH" ] && [ -f "$CUSTOM_CA_PATH" ]; then
                cat <<EOF > "$CADDYFILE_PATH"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca $ACME_URL
        ca_trusted_pem_file /etc/caddy/root.crt
    }
    reverse_proxy docker-registry:5000
}
EOF
            else
                cat <<EOF > "$CADDYFILE_PATH"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca $ACME_URL
    }
    reverse_proxy docker-registry:5000
}
EOF
            fi
        fi
    else
        # HTTP Saja (Catch-all :80 agar semua domain & IP bisa masuk tanpa dibatasi)
        cat <<EOF > "$CADDYFILE_PATH"
:80 {
    reverse_proxy docker-registry:5000
}
EOF
    fi
    
    echo -e "${BLUE}Mendeploy Caddy Reverse Proxy Container...${NC}"
    CADDY_VOLUME_CA=""
    if [ "$USE_HTTPS" = true ] && [ "$ACME_CHOICE" = "3" ] && [ -n "$CUSTOM_CA_PATH" ] && [ -f "$CUSTOM_CA_PATH" ]; then
        CADDY_VOLUME_CA="-v ${CUSTOM_CA_PATH}:/etc/caddy/root.crt"
    fi
    
    docker run -d \
        --name registry-proxy \
        --network registry-net \
        --restart always \
        -p 80:80 \
        -p 443:443 \
        -v "$CADDYFILE_PATH":/etc/caddy/Caddyfile \
        -v "${CADDY_DIR}/data":/data \
        -v "${CADDY_DIR}/config":/config \
        $CADDY_VOLUME_CA \
        caddy:latest
fi

# 11. Final Verification & Instructions
if [ $? -eq 0 ]; then
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}   Container Registry Berhasil Dideploy!          ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "Versi Registry: ${VERSION_NAME} (${REGISTRY_IMAGE})"
    echo -e "Direktori Storage: ${STORAGE_DIR}"
    
    if [ "$IS_PROXY_ENABLED" = true ]; then
        echo -e "Reverse Proxy: Caddy (Aktif)"
        if [ "$USE_HTTPS" = true ]; then
            echo -e "Domain / URL: ${YELLOW}https://${DOMAIN_NAME}${NC}"
            URL_ACCESS="https://${DOMAIN_NAME}"
        else
            echo -e "Domain / URL: ${YELLOW}http://${DOMAIN_NAME}${NC}"
            URL_ACCESS="http://${DOMAIN_NAME}"
        fi
    else
        echo -e "Reverse Proxy: Tidak Aktif"
        echo -e "Port Ekspos Host: ${PORT}"
        URL_ACCESS="localhost:${PORT}"
    fi
    
    echo -e "\nCara Penggunaan (Push & Pull):"
    if [ "$IS_AUTH_ENABLED" = true ]; then
        echo -e "0. Login ke registry terlebih dahulu:"
        echo -e "   ${YELLOW}docker login ${URL_ACCESS}${NC} (masukkan username dan password Anda)"
    fi
    echo -e "1. Tag image Anda:"
    echo -e "   ${YELLOW}docker tag <image-name> ${URL_ACCESS}/<image-name>${NC}"
    echo -e "2. Push ke registry:"
    echo -e "   ${YELLOW}docker push ${URL_ACCESS}/<image-name>${NC}"
    echo -e "3. Pull dari registry:"
    echo -e "   ${YELLOW}docker pull ${URL_ACCESS}/<image-name>${NC}"
else
    echo -e "${RED}Error: Gagal mendeploy container registry / reverse proxy.${NC}" >&2
    exit 1
fi
