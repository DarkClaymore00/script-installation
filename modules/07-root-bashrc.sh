#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/lib/common.sh"

info "Configurando .bashrc do root para ls colorido"

if [[ "$EUID" -ne 0 ]]; then
    error "Este módulo precisa ser executado como root."
    exit 1
fi

ROOT_BASHRC="/root/.bashrc"

touch "$ROOT_BASHRC"

if ! grep -qF "# CONFIGURACAO LS COLORIDO - SCRIPT INSTALLATION" "$ROOT_BASHRC"; then
    cat >> "$ROOT_BASHRC" <<'EOF_BASHRC'

# CONFIGURACAO LS COLORIDO - SCRIPT INSTALLATION
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors)"
fi

alias ls='ls --color=auto'
alias ll='ls --color=auto -l'
alias la='ls --color=auto -la'
EOF_BASHRC
fi

info ".bashrc do root configurado."
