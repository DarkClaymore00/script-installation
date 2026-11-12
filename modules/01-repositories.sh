#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/config.conf"
source "$BASE_DIR/lib/common.sh"

check_root

if [[ ! -r /etc/os-release ]]; then
    error "Arquivo /etc/os-release não encontrado."
    exit 1
fi

source /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$CODENAME" ]]; then
    error "Não foi possível identificar VERSION_CODENAME."
    exit 1
fi

# Preservar fontes já configuradas, inclusive no formato deb822 (.sources).
if grep -RqsE '(^[[:space:]]*deb(-src)?[[:space:]].*(deb\.debian\.org|security\.debian\.org)|^[[:space:]]*URIs:[[:space:]].*(deb\.debian\.org|security\.debian\.org))' \
    /etc/apt/sources.list /etc/apt/sources.list.d \
    --include='*.list' --include='*.sources' 2>/dev/null; then
    mark_skipped "Fontes oficiais Debian já existem; configuração atual preservada."
    exit 0
fi

TARGET="/etc/apt/sources.list.d/script-installation.sources"
if [[ -e "$TARGET" ]] && ! grep -qF '# Gerenciado pelo script-installation' "$TARGET"; then
    error "$TARGET já existe e não pertence ao instalador."
    exit 1
fi

backup_file "$TARGET"
cat > "$TARGET" <<EOF_SOURCES
# Gerenciado pelo script-installation
Types: deb
URIs: https://deb.debian.org/debian
Suites: $CODENAME $CODENAME-updates
Components: main contrib non-free non-free-firmware

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
EOF_SOURCES

chmod 644 "$TARGET"
success "Fontes Debian configuradas em $TARGET."
