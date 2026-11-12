#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.conf"
source "$BASE_DIR/lib/common.sh"

# Preservar a rede existente por padrão.
if [[ "$CONFIGURAR_IP" != true ]]; then
    mark_skipped "Configuração de IP desabilitada (CONFIGURAR_IP=false)."
    exit 0
fi

# Validar endereço IPv4.
validar_ipv4() {
    local endereco="$1"
    local octeto
    local -a octetos

    [[ "$endereco" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a octetos <<< "$endereco"

    for octeto in "${octetos[@]}"; do
        (( 10#$octeto <= 255 )) || return 1
    done

    return 0
}

# Converter prefixo CIDR em máscara de rede.
converter_mascara() {
    local prefixo="$1"
    local mascara

    mascara=$(( (0xFFFFFFFF << (32 - prefixo)) & 0xFFFFFFFF ))

    printf '%d.%d.%d.%d' \
        "$(( (mascara >> 24) & 255 ))" \
        "$(( (mascara >> 16) & 255 ))" \
        "$(( (mascara >> 8) & 255 ))" \
        "$(( mascara & 255 ))"
}

# Validar parâmetros de rede.
validar_configuracao() {
    local dns
    local ip_base
    local prefixo
    local -a servidores_dns

    if [[ "$TIPO_IP" == "static" ]]; then
        if [[ ! "$IP_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            error "IP_ADDRESS inválido. Exemplo: 192.168.1.50/24."
            return 1
        fi

        ip_base="${IP_ADDRESS%/*}"
        prefixo="${IP_ADDRESS##*/}"

        if ! validar_ipv4 "$ip_base" || (( 10#$prefixo > 32 )); then
            error "Endereço IPv4 ou prefixo CIDR inválido."
            return 1
        fi

        if [[ -n "$GATEWAY" ]] && ! validar_ipv4 "$GATEWAY"; then
            error "Gateway IPv4 inválido."
            return 1
        fi

        IFS=', ' read -r -a servidores_dns <<< "$DNS_SERVERS"

        for dns in "${servidores_dns[@]}"; do
            [[ -z "$dns" ]] && continue

            if ! validar_ipv4 "$dns"; then
                error "Servidor DNS inválido: $dns"
                return 1
            fi
        done

    elif [[ "$TIPO_IP" != "dhcp" ]]; then
        error "TIPO_IP inválido. Utilize dhcp ou static."
        return 1
    fi

    return 0
}

# Detectar o gerenciador de rede.
detectar_gerenciador_rede() {
    if command_exists nmcli && systemctl is-active --quiet NetworkManager; then
        GERENCIADOR="NetworkManager"
        info "NetworkManager detectado."
        return 0
    fi

    if systemctl is-active --quiet systemd-networkd; then
        error "systemd-networkd está ativo, mas ainda não é suportado."
        return 1
    fi

    if command_exists ifup && command_exists ifdown && command_exists ifquery; then
        GERENCIADOR="ifupdown"
        info "ifupdown detectado."
        return 0
    fi

    error "Nenhum gerenciador de rede compatível foi encontrado."
    return 1
}

# Detectar a interface de rede.
detectar_interface() {
    local tipo_interface

    if [[ "$GERENCIADOR" == "NetworkManager" ]]; then
        if [[ -n "$INTERFACE_REDE" ]]; then
            INTERFACE="$INTERFACE_REDE"
        else
            local -a interfaces_ethernet
            local -a interfaces_wifi

            mapfile -t interfaces_ethernet < <(
                nmcli -t -f DEVICE,TYPE,STATE device status |
                awk -F: '$2 == "ethernet" && $3 == "connected" {print $1}'
            )

            mapfile -t interfaces_wifi < <(
                nmcli -t -f DEVICE,TYPE,STATE device status |
                awk -F: '$2 == "wifi" && $3 == "connected" {print $1}'
            )

            if (( ${#interfaces_ethernet[@]} > 0 )); then
                INTERFACE="${interfaces_ethernet[0]}"
                info "Conexão Ethernet priorizada."
            elif (( ${#interfaces_wifi[@]} > 0 )); then
                INTERFACE="${interfaces_wifi[0]}"
                info "Utilizando Wi-Fi."
            else
                error "Nenhuma interface Ethernet ou Wi-Fi conectada."
                return 1
            fi
        fi

        tipo_interface="$(nmcli -g GENERAL.TYPE device show "$INTERFACE" 2>/dev/null || true)"

        if [[ "$tipo_interface" != "ethernet" && "$tipo_interface" != "wifi" ]]; then
            error "Interface inválida ou não suportada: $INTERFACE."
            return 1
        fi

    else
        if [[ -z "$INTERFACE_REDE" ]]; then
            error "Informe a interface em INTERFACE_REDE para utilizar ifupdown."
            return 1
        fi

        INTERFACE="$INTERFACE_REDE"

        if [[ ! "$INTERFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; then
            error "Nome de interface inválido."
            return 1
        fi

        if ! ip link show dev "$INTERFACE" >/dev/null 2>&1; then
            error "Interface não encontrada: $INTERFACE."
            return 1
        fi
    fi

    info "Interface selecionada: $INTERFACE"
}

# Configurar NetworkManager.
configurar_networkmanager() {
    local estado
    local conexao
    local metodo_anterior
    local enderecos_anteriores
    local gateway_anterior
    local dns_anterior
    local ignore_dns_anterior
    local dns_normalizado
    local -a servidores_dns

    estado="$(nmcli -g GENERAL.STATE device show "$INTERFACE" 2>/dev/null || true)"

    if [[ "$estado" != 100* ]]; then
        error "A interface $INTERFACE não está conectada."
        return 1
    fi

    conexao="$(nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null || true)"

    if [[ -z "$conexao" || "$conexao" == "--" ]]; then
        error "Não foi possível identificar o perfil da conexão."
        return 1
    fi

    info "Perfil: $conexao"

    # Guardar as configurações anteriores para permitir restauração.
    metodo_anterior="$(nmcli -g ipv4.method connection show "$conexao")"
    enderecos_anteriores="$(nmcli -g ipv4.addresses connection show "$conexao")"
    gateway_anterior="$(nmcli -g ipv4.gateway connection show "$conexao")"
    dns_anterior="$(nmcli -g ipv4.dns connection show "$conexao")"
    ignore_dns_anterior="$(nmcli -g ipv4.ignore-auto-dns connection show "$conexao")"

    if [[ "$TIPO_IP" == "dhcp" ]]; then
        info "Configurando DHCP."

        if ! nmcli connection modify "$conexao" \
            ipv4.method auto \
            ipv4.addresses "" \
            ipv4.gateway "" \
            ipv4.dns "" \
            ipv4.ignore-auto-dns no; then
            error "Não foi possível modificar o perfil."
            return 1
        fi

    else
        IFS=', ' read -r -a servidores_dns <<< "$DNS_SERVERS"
        dns_normalizado="${servidores_dns[*]}"

        info "Configurando IP estático: $IP_ADDRESS"

        if ! nmcli connection modify "$conexao" \
            ipv4.method manual \
            ipv4.addresses "$IP_ADDRESS" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$dns_normalizado" \
            ipv4.ignore-auto-dns no; then
            error "Não foi possível modificar o perfil."
            return 1
        fi
    fi

    warn "A reconexão pode interromper temporariamente a internet."

    if nmcli connection up "$conexao" ifname "$INTERFACE"; then
        success "Configuração do NetworkManager aplicada."
        return 0
    fi

    error "Falha ao ativar a conexão. Restaurando configurações anteriores."

    if nmcli connection modify "$conexao" \
        ipv4.method "$metodo_anterior" \
        ipv4.addresses "$enderecos_anteriores" \
        ipv4.gateway "$gateway_anterior" \
        ipv4.dns "$dns_anterior" \
        ipv4.ignore-auto-dns "$ignore_dns_anterior"; then

        nmcli connection up "$conexao" ifname "$INTERFACE" || true
    else
        error "Não foi possível restaurar o perfil automaticamente."
    fi

    return 1
}

# Configurar ifupdown.
configurar_ifupdown() {
    local arquivo="/etc/network/interfaces.d/script-installation"
    local backup=""
    local temporario
    local ip_base
    local prefixo
    local mascara
    local -a servidores_dns

    # Verificar se o arquivo principal inclui interfaces.d.
    if ! grep -Eq '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*([[:space:]]|$)|^[[:space:]]*source-directory[[:space:]]+/etc/network/interfaces\.d([[:space:]]|$)' /etc/network/interfaces; then
        error "O arquivo principal não inclui /etc/network/interfaces.d."
        return 1
    fi

    # Não sobrescrever arquivos que não pertencem ao instalador.
    if [[ -f "$arquivo" ]]; then
        if ! grep -q 'Gerenciado pelo script-installation' "$arquivo"; then
            error "O arquivo $arquivo já existe e não pertence ao instalador."
            return 1
        fi

        backup="$arquivo.bak.$(date +%Y%m%d-%H%M%S)"

        if ! cp -a "$arquivo" "$backup"; then
            error "Não foi possível criar o backup."
            return 1
        fi

        info "Backup criado: $backup"
    elif ifquery "$INTERFACE" >/dev/null 2>&1; then
        error "A interface já possui configuração no ifupdown."
        error "Não será criada uma configuração duplicada."
        return 1
    fi

    # Verificar dependência necessária para configurar DNS.
    if [[ "$TIPO_IP" == "static" && -n "$DNS_SERVERS" ]] && ! command_exists resolvconf; then
        error "DNS estático via ifupdown requer resolvconf."
        return 1
    fi

    temporario="$(mktemp /etc/network/interfaces.d/.script-installation.XXXXXX)"

    {
        echo "# Gerenciado pelo script-installation"
        echo "auto $INTERFACE"

        if [[ "$TIPO_IP" == "dhcp" ]]; then
            echo "iface $INTERFACE inet dhcp"
        else
            ip_base="${IP_ADDRESS%/*}"
            prefixo="${IP_ADDRESS##*/}"
            mascara="$(converter_mascara "$prefixo")"

            echo "iface $INTERFACE inet static"
            echo "    address $ip_base"
            echo "    netmask $mascara"

            if [[ -n "$GATEWAY" ]]; then
                echo "    gateway $GATEWAY"
            fi

            if [[ -n "$DNS_SERVERS" ]]; then
                IFS=', ' read -r -a servidores_dns <<< "$DNS_SERVERS"
                echo "    dns-nameservers ${servidores_dns[*]}"
            fi
        fi
    } > "$temporario"

    chmod 644 "$temporario"

    if ! mv -f "$temporario" "$arquivo"; then
        rm -f "$temporario"
        error "Não foi possível gravar a configuração."
        return 1
    fi

    warn "Aplicando configuração com ifupdown."

    if ifup "$INTERFACE"; then
        success "Configuração do ifupdown aplicada."
        return 0
    fi

    error "Falha ao ativar a interface. Restaurando o arquivo anterior."

    if [[ -n "$backup" ]]; then
        cp -a "$backup" "$arquivo"
    else
        rm -f "$arquivo"
    fi

    ifup "$INTERFACE" || true

    return 1
}

# Execução principal.
validar_configuracao || exit 1
detectar_gerenciador_rede || exit 1
detectar_interface || exit 1

info "Gerenciador selecionado: $GERENCIADOR"

case "$GERENCIADOR" in
    NetworkManager)
        configurar_networkmanager
        ;;
    ifupdown)
        configurar_ifupdown
        ;;
    *)
        error "Gerenciador não suportado."
        exit 1
        ;;
esac
