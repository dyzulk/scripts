#!/bin/bash

# Configuration
DOCKER_VERSION="28.5.0"
DEFAULT_PORT="5000"
DEFAULT_STORAGE="/var/lib/registry"
LANDING_PAGE_URL="https://raw.githubusercontent.com/dyzulk/scripts/main/docker/index-registry.html"

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

# Helper function to get local IP
get_local_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip:-127.0.0.1}"
}

# Helper function to get public IP
get_public_ip() {
    local ip
    ip=$(curl -sS --max-time 3 ifconfig.me 2>/dev/null)
    echo "$ip"
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

# 1. System Requirements Check
check_system_requirements() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Error: Skrip ini harus dijalankan sebagai root atau dengan sudo.${NC}" >&2
        return 1
    fi

    if [ "$(uname)" != "Linux" ]; then
        echo -e "${RED}Error: Skrip ini hanya mendukung sistem operasi Linux.${NC}" >&2
        return 1
    fi
    return 0
}

# 1b. Check & Install Curl
install_curl() {
    if command_exists curl; then
        echo -e "${GREEN}✓ curl sudah terinstall.${NC}"
        return 0
    fi

    echo -e "${YELLOW}curl belum terinstall. Menginstal curl...${NC}"

    if command_exists apt-get; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command_exists dnf; then
        dnf install -y -q curl
    elif command_exists yum; then
        yum install -y -q curl
    elif command_exists apk; then
        apk add --no-cache curl
    else
        echo -e "${RED}Error: Tidak dapat mendeteksi package manager untuk menginstal curl.${NC}" >&2
        return 1
    fi

    if command_exists curl; then
        echo -e "${GREEN}✓ curl berhasil diinstal.${NC}"
        return 0
    fi

    echo -e "${RED}Error: Gagal menginstal curl.${NC}" >&2
    return 1
}

# 2. Uninstall Process
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
        echo -e "${YELLOW}Docker tidak terdeteksi, melewati pembersihan kontainer.${NC}"
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
    return 0
}

# 3. Check & Install Docker
install_docker() {
    if command_exists docker; then
        echo -e "${GREEN}✓ Docker sudah terinstall.${NC}"
        local docker_version_installed
        docker_version_installed=$(docker --version | awk '{print $3}' | sed 's/,//')
        echo -e "Versi terinstall: ${docker_version_installed}"
        return 0
    fi

    echo -e "${YELLOW}Docker belum terinstall. Menginstal Docker versi ${DOCKER_VERSION}...${NC}"
    curl -sSL https://get.docker.com | sh -s -- --version ${DOCKER_VERSION}
    
    if command_exists apt-mark; then
        echo -e "${BLUE}Mengunci versi paket Docker agar tidak ter-update otomatis...${NC}"
        apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras >/dev/null 2>&1
    fi
    
    # Start and enable docker
    systemctl enable --now docker >/dev/null 2>&1
    
    if command_exists docker; then
        echo -e "${GREEN}✓ Docker versi $(docker --version) berhasil di-install.${NC}"
        return 0
    fi

    echo -e "${RED}Error: Gagal menginstal Docker.${NC}" >&2
    return 1
}

# 4. Generate Htpasswd file securely
generate_htpasswd() {
    local user="$1"
    local pass="$2"
    local out_file="$3"
    
    # 1. Gunakan utilitas host lokal jika terpasang (paling cepat & aman)
    if command_exists htpasswd; then
        echo -e "${BLUE}Menggunakan utilitas htpasswd lokal host...${NC}"
        htpasswd -Bbn "$user" "$pass" > "$out_file" 2>/dev/null
        return $?
    fi
    
    # 2. Gunakan Docker dengan image httpd:alpine (ringan dan pasti memiliki htpasswd)
    if command_exists docker; then
        echo -e "${BLUE}Mengunduh base image httpd:alpine untuk utilitas htpasswd...${NC}"
        docker pull httpd:alpine
        echo -e "${BLUE}Membuat file kredensial menggunakan kontainer httpd:alpine...${NC}"
        docker run --rm --entrypoint htpasswd httpd:alpine -Bbn "$user" "$pass" > "$out_file" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$out_file" ]; then
            return 0
        fi
    fi
    return 1
}

# 5. Setup authentication flow
setup_authentication() {
    read_input "Aktifkan autentikasi Username & Password? [y/N]: " ENABLE_AUTH
    ENABLE_AUTH=${ENABLE_AUTH:-n}
    
    AUTH_FLAGS=""
    IS_AUTH_ENABLED=false
    
    if [[ "$ENABLE_AUTH" =~ ^[Yy]$ ]]; then
        read_input "Masukkan Username: " AUTH_USER
        if [ -z "$AUTH_USER" ]; then
            echo -e "${RED}Error: Username tidak boleh kosong! Autentikasi dibatalkan.${NC}" >&2
            return 1
        fi
        
        read_input "Masukkan Password: " AUTH_PASS "silent"
        if [ -z "$AUTH_PASS" ]; then
            echo -e "${RED}Error: Password tidak boleh kosong! Autentikasi dibatalkan.${NC}" >&2
            return 1
        fi
        
        local auth_dir="${STORAGE_DIR}/auth"
        mkdir -p "$auth_dir"
        
        echo -e "${BLUE}Membuat file kredensial htpasswd...${NC}"
        if generate_htpasswd "$AUTH_USER" "$AUTH_PASS" "${auth_dir}/htpasswd"; then
            echo -e "${GREEN}✓ File htpasswd berhasil dibuat.${NC}"
            AUTH_FLAGS="-v ${auth_dir}:/auth -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=Registry-Realm -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd"
            IS_AUTH_ENABLED=true
            return 0
        else
            echo -e "${RED}Error: Gagal membuat file htpasswd.${NC}" >&2
            return 1
        fi
    fi
    return 0
}

# 5b. Download Landing Page HTML
download_landing_page() {
    if [ "$IS_PROXY_ENABLED" != true ]; then
        echo -e "${YELLOW}Reverse Proxy tidak aktif, melewati unduhan landing page.${NC}"
        return 0
    fi

    local html_dir="${STORAGE_DIR}/caddy/html"
    mkdir -p "$html_dir"

    echo -e "${BLUE}Mengunduh landing page dari repository...${NC}"
    if curl -fsSL "${LANDING_PAGE_URL}" -o "${html_dir}/index.html"; then
        echo -e "${GREEN}✓ Landing page berhasil diunduh ke ${html_dir}/index.html${NC}"
        return 0
    fi

    echo -e "${RED}Error: Gagal mengunduh landing page dari ${LANDING_PAGE_URL}${NC}" >&2
    return 1
}

# 6. Collect user configurations
collect_user_inputs() {
    echo -e "\nPilih versi Container Registry yang ingin dideploy:"
    echo -e "1) Registry v2 (Docker Distribution - Legacy/Stable: registry:2)"
    echo -e "2) Registry v3 (CNCF Distribution OCI Spec - Modern: registry:3)"
    read_input "Pilihan Anda [1-2] (Default: 2): " choice
    choice=${choice:-2}
    
    if [ "$choice" = "1" ]; then
        REGISTRY_IMAGE="registry:2"
        VERSION_NAME="v2"
    else
        REGISTRY_IMAGE="registry:3"
        VERSION_NAME="v3"
    fi
    
    read_input "Tentukan direktori penyimpanan data (Default: $DEFAULT_STORAGE): " STORAGE_DIR
    STORAGE_DIR=${STORAGE_DIR:-$DEFAULT_STORAGE}
    mkdir -p "$STORAGE_DIR"
    
    # Run authentication setup
    if ! setup_authentication; then
        return 1
    fi
    
    # Proxy configuration
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
            if [ -z "$DOMAIN_NAME" ]; then
                echo -e "${RED}Error: Domain Name tidak boleh kosong!${NC}" >&2
                return 1
            fi
            
            echo -e "\nPilih Provider SSL/HTTPS:"
            echo -e "1) Let's Encrypt (Otomatis & Publik)"
            echo -e "2) ZeroSSL (Otomatis & Publik - Membutuhkan EAB)"
            echo -e "3) Custom ACME (misal: Step-CA / Local CA)"
            echo -e "4) Self-Signed SSL (Sertifikat Internal/Lokal)"
            read_input "Pilihan Anda [1-4] (Default: 1): " ACME_CHOICE
            ACME_CHOICE=${ACME_CHOICE:-1}
            
            if [ "$ACME_CHOICE" != "4" ]; then
                read_input "Masukkan Email untuk Kontak ACME: " ACME_EMAIL
                if [ -z "$ACME_EMAIL" ]; then
                    echo -e "${RED}Error: Email ACME tidak boleh kosong!${NC}" >&2
                    return 1
                fi
            fi
            
            if [ "$ACME_CHOICE" = "2" ]; then
                read_input "Masukkan ZeroSSL EAB KID: " EAB_KID
                read_input "Masukkan ZeroSSL EAB HMAC Key: " EAB_HMAC
                if [ -z "$EAB_KID" ] || [ -z "$EAB_HMAC" ]; then
                    echo -e "${RED}Error: ZeroSSL EAB KID dan HMAC Key tidak boleh kosong!${NC}" >&2
                    return 1
                fi
            elif [ "$ACME_CHOICE" = "3" ]; then
                read_input "Masukkan ACME Directory URL (misal: https://step-ca.local/acme/acme/directory): " ACME_URL
                if [ -z "$ACME_URL" ]; then
                    echo -e "${RED}Error: ACME Directory URL tidak boleh kosong!${NC}" >&2
                    return 1
                fi
                read_input "Masukkan path file Root CA Certificate lokal (opsional): " CUSTOM_CA_PATH
            fi
        else
            # Pada HTTP, Caddy dikonfigurasi sebagai catch-all (:80) sehingga bisa diakses dari IP/domain apa saja.
            DOMAIN_NAME=""
        fi
    else
        # Tanpa Reverse Proxy: Butuh Port ekspos langsung ke host
        read_input "Tentukan port ekspos registry ke host (Default: $DEFAULT_PORT): " PORT
        PORT=${PORT:-$DEFAULT_PORT}
        
        if command_exists ss; then
            if ss -tulnp | grep -q ":${PORT} "; then
                echo -e "${RED}Error: Port ${PORT} sudah digunakan oleh service lain.${NC}" >&2
                return 1
            fi
        fi
    fi
    return 0
}

# 7. Deploy Registry Container
deploy_registry() {
    # Network Creation (jika menggunakan proxy)
    if [ "$IS_PROXY_ENABLED" = true ]; then
        if ! docker network inspect registry-net >/dev/null 2>&1; then
            echo -e "${BLUE}Membuat docker network: registry-net...${NC}"
            if ! docker network create registry-net >/dev/null; then
                echo -e "${RED}Error: Gagal membuat docker network.${NC}" >&2
                return 1
            fi
        fi
    fi

    # Clean up old containers
    if docker ps -a --format '{{.Names}}' | grep -Eq "^docker-registry$"; then
        echo -e "${YELLOW}Menghapus container docker-registry lama...${NC}"
        docker rm -f docker-registry >/dev/null 2>&1
    fi
    
    if docker ps -a --format '{{.Names}}' | grep -Eq "^registry-proxy$"; then
        echo -e "${YELLOW}Menghapus container registry-proxy lama...${NC}"
        docker rm -f registry-proxy >/dev/null 2>&1
    fi

    # Mengunduh image secara transparan agar kemajuan pengunduhan tampil di terminal
    echo -e "${BLUE}Mengunduh image ${REGISTRY_IMAGE}...${NC}"
    docker pull "${REGISTRY_IMAGE}"

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
    
    if [ $? -eq 0 ]; then
        return 0
    fi
    return 1
}

# 8. Configure and Deploy Caddy (jika proxy aktif)
configure_and_deploy_proxy() {
    if [ "$IS_PROXY_ENABLED" != true ]; then
        return 0
    fi

    echo -e "${BLUE}Mengonfigurasi Caddy Reverse Proxy...${NC}"
    local caddy_dir="${STORAGE_DIR}/caddy"
    mkdir -p "${caddy_dir}/data" "${caddy_dir}/config"
    
    # Generate Caddyfile
    local caddyfile_path="${caddy_dir}/Caddyfile"
    
    if [ "$USE_HTTPS" = true ]; then
        if [ "$ACME_CHOICE" = "1" ]; then
            # Let's Encrypt
            cat <<EOF > "$caddyfile_path"
$DOMAIN_NAME {
    tls $ACME_EMAIL

    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
        elif [ "$ACME_CHOICE" = "2" ]; then
            # ZeroSSL dengan EAB
            cat <<EOF > "$caddyfile_path"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca https://acme.zerossl.com/v2/DV90
        eab $EAB_KID $EAB_HMAC
    }

    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
        elif [ "$ACME_CHOICE" = "3" ]; then
            # Custom ACME (Step-CA)
            if [ -n "$CUSTOM_CA_PATH" ] && [ -f "$CUSTOM_CA_PATH" ]; then
                cat <<EOF > "$caddyfile_path"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca $ACME_URL
        ca_trusted_pem_file /etc/caddy/root.crt
    }

    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
            else
                cat <<EOF > "$caddyfile_path"
$DOMAIN_NAME {
    tls $ACME_EMAIL {
        ca $ACME_URL
    }

    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
            fi
        elif [ "$ACME_CHOICE" = "4" ]; then
            # Self-Signed SSL (Internal CA)
            cat <<EOF > "$caddyfile_path"
$DOMAIN_NAME {
    tls internal

    # Endpoint publik untuk mengunduh Root CA Certificate
    handle /ca.crt {
        rewrite * /caddy/pki/authorities/local/root.crt
        file_server {
            root /data
        }
    }

    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
        fi
    else
        # HTTP Saja (Catch-all :80 agar semua domain & IP bisa masuk tanpa dibatasi)
        cat <<EOF > "$caddyfile_path"
:80 {
    handle /v2/* {
        reverse_proxy docker-registry:5000
    }

    handle {
        root * /usr/share/caddy
        file_server
    }
}
EOF
    fi
    
    # Unduh Caddy image secara transparan agar tampil di terminal
    echo -e "${BLUE}Mengunduh image caddy:latest...${NC}"
    docker pull caddy:latest

    echo -e "${BLUE}Mendeploy Caddy Reverse Proxy Container...${NC}"
    local caddy_volume_ca=""
    if [ "$USE_HTTPS" = true ] && [ "$ACME_CHOICE" = "3" ] && [ -n "$CUSTOM_CA_PATH" ] && [ -f "$CUSTOM_CA_PATH" ]; then
        caddy_volume_ca="-v ${CUSTOM_CA_PATH}:/etc/caddy/root.crt"
    fi
    
    docker run -d \
        --name registry-proxy \
        --network registry-net \
        --restart always \
        -p 80:80 \
        -p 443:443 \
        -v "$caddyfile_path":/etc/caddy/Caddyfile \
        -v "${caddy_dir}/data":/data \
        -v "${caddy_dir}/config":/config \
        -v "${caddy_dir}/html":/usr/share/caddy \
        $caddy_volume_ca \
        caddy:latest
        
    if [ $? -eq 0 ]; then
        return 0
    fi
    return 1
}

# 9. Summary & Instructions
show_success_summary() {
    local local_ip=$(get_local_ip)
    local public_ip=$(get_public_ip)

    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}   Container Registry Berhasil Dideploy!          ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "Versi Registry: ${VERSION_NAME} (${REGISTRY_IMAGE})"
    echo -e "Direktori Storage: ${STORAGE_DIR}"
    
    local docker_target=""
    if [ "$IS_PROXY_ENABLED" = true ]; then
        echo -e "Reverse Proxy: Caddy (Aktif)"
        if [ "$USE_HTTPS" = true ]; then
            echo -e "Domain / URL Utama: ${YELLOW}https://${DOMAIN_NAME}${NC}"
            echo -e "Akses IP Lokal (HTTP): ${YELLOW}http://${local_ip}${NC} (SSL tidak berlaku untuk IP)"
            if [ -n "$public_ip" ]; then
                echo -e "Akses IP Publik (HTTP): ${YELLOW}http://${public_ip}${NC} (SSL tidak berlaku untuk IP)"
            fi
            docker_target="${DOMAIN_NAME}"
        else
            echo -e "Domain / URL Utama (HTTP): Semua Domain / IP terarah ke server"
            echo -e "Akses IP Lokal (HTTP): ${YELLOW}http://${local_ip}${NC}"
            if [ -n "$public_ip" ]; then
                echo -e "Akses IP Publik (HTTP): ${YELLOW}http://${public_ip}${NC}"
            fi
            docker_target="${local_ip}"
        fi
    else
        echo -e "Reverse Proxy: Tidak Aktif"
        echo -e "Port Ekspos Host: ${PORT}"
        echo -e "Akses IP Lokal: ${YELLOW}http://${local_ip}:${PORT}${NC}"
        if [ -n "$public_ip" ]; then
            echo -e "Akses IP Publik: ${YELLOW}http://${public_ip}:${PORT}${NC}"
        fi
        docker_target="${local_ip}:${PORT}"
    fi
    
    echo -e "\nCara Penggunaan (Push & Pull):"
    if [ "$IS_AUTH_ENABLED" = true ]; then
        echo -e "0. Login ke registry terlebih dahulu:"
        echo -e "   ${YELLOW}docker login ${docker_target}${NC} (masukkan username dan password Anda)"
    fi
    echo -e "1. Tag image Anda:"
    echo -e "   ${YELLOW}docker tag <image-name> ${docker_target}/<image-name>${NC}"
    echo -e "2. Push ke registry:"
    echo -e "   ${YELLOW}docker push ${docker_target}/<image-name>${NC}"
    echo -e "3. Pull dari registry:"
    echo -e "   ${YELLOW}docker pull ${docker_target}/<image-name>${NC}"

    if [ "$USE_HTTPS" != true ]; then
        echo -e "\n${YELLOW}Catatan untuk HTTP (Insecure Registry):${NC}"
        echo -e "Karena Anda menggunakan HTTP biasa, Anda perlu menambahkan host ini ke konfigurasi"
        echo -e "insecure-registries di file /etc/docker/daemon.json di komputer klien Anda:"
        echo -e "   {\n     \"insecure-registries\": [\"${docker_target}\"]\n   }"
    fi

    if [ "$USE_HTTPS" = true ] && [ "$ACME_CHOICE" = "4" ]; then
        echo -e "\n${YELLOW}Catatan Penting untuk Self-Signed SSL:${NC}"
        echo -e "Agar Docker daemon di komputer klien (atau server Dokploy) mempercayai sertifikat ini,"
        echo -e "jalankan perintah satu baris (one-liner) berikut di server Dokploy/klien tersebut:"
        echo -e "   ${YELLOW}sudo mkdir -p /etc/docker/certs.d/${DOMAIN_NAME} && sudo curl -kfsSL https://${DOMAIN_NAME}/ca.crt -o /etc/docker/certs.d/${DOMAIN_NAME}/ca.crt && sudo systemctl restart docker${NC}"
    fi
}

# 10. Orchestrator
main() {
    # Check if run as uninstall
    local uninstall_arg=false
    if [ "$1" = "uninstall" ] || [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
        uninstall_arg=true
    fi

    # 1. Check system requirements
    if ! check_system_requirements; then
        return 1
    fi
    
    # 2. Run uninstall if requested
    if [ "$uninstall_arg" = true ]; then
        uninstall_registry
        return $?
    fi
    
    # 3. Main deployment pipeline (Nested-If / Modular)
    if install_curl; then
        if install_docker; then
            if collect_user_inputs; then
                if deploy_registry; then
                    if download_landing_page; then
                        if configure_and_deploy_proxy; then
                            show_success_summary
                            return 0
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    echo -e "${RED}Error: Gagal mendeploy container registry / reverse proxy.${NC}" >&2
    return 1
}

# Execute main
main "$@"
exit_code=$?
exit $exit_code
