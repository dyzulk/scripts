#!/bin/bash
# 1. Ubah tautan mirror resmi Debian menjadi HTTP
sudo sed -i 's|https://|http://|g' /etc/apt/mirrors/debian.list
sudo sed -i 's|https://|http://|g' /etc/apt/mirrors/debian-security.list

# 2. Jika ada file .list atau .sources lain yang masih menggunakan https://
sudo sed -i 's|https://deb.debian.org|http://deb.debian.org|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true