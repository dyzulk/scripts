# Personal Scripts Repository

This repository contains a collection of shell scripts to simplify system administration, automate Docker setup, and deploy local container registries.

## Available Scripts

### 1. Docker & Registry
* **[`docker/install-registry.sh`](docker/install-registry.sh)**: Automated script to check for Docker (or install Docker version `28.5.0` compatible with Dokploy) and deploy Container Registry v2 or v3.
  * **Features**:
    * Automated Docker check & installation.
    * Packages locking (`apt-mark hold`) to prevent accidental Docker upgrades.
    * Deploy Registry v2 (`registry:2`) or Registry v3 (`registry:3.0.0-alpha.1`).
    * Optional automatic basic authentication setup (Username & Password) using `htpasswd`.
  * **How to use (Direct via curl)**:
    You can run the installer script directly on your server without cloning the repository:
    ```bash
    curl -sSL https://raw.githubusercontent.com/dyzulk/scripts/main/docker/install-registry.sh | sudo bash
    ```
  * **How to use (Local execution)**:
    ```bash
    chmod +x docker/install-registry.sh
    sudo ./docker/install-registry.sh
    ```

### 2. APT Configurations (Debian)
* **[`apt/docker-install.sh`](apt/docker-install.sh)**: Adds official Docker GPG keys and setup HTTP-based official Docker APT repository for Debian.
  * **How to use**:
    ```bash
    sudo ./apt/docker-install.sh
    ```
* **[`apt/https-to-http.sh`](apt/https-to-http.sh)**: Changes default Debian mirror URLs from HTTPS to HTTP (useful in closed network environments blocking HTTPS apt traffic).
  * **How to use**:
    ```bash
    sudo ./apt/https-to-http.sh
    ```

---

## License
This repository is licensed under the MIT License. See [LICENSE](LICENSE) for details.
