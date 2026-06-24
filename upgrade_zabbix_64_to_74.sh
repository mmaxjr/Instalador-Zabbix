#!/bin/bash
# ============================================================
#  Upgrade Zabbix 6.4.x → 7.0 → 7.4 - Debian 12 + MariaDB
#  Syma Solutions - Suporte
#
#  ATENÇÃO: O Zabbix não permite pular versões maiores.
#  Este script faz o upgrade em dois estágios:
#    Estágio 1: 6.4.x → 7.0 (com migração do banco)
#    Estágio 2: 7.0   → 7.4 (com migração do banco)
# ============================================================
set -e

# --- CONFIGURAÇÕES ------------------------------------------
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="ZabbixPass@2026"
DB_ROOT_PASS="RootPass@2026"
BACKUP_DIR="/root"
TIMEZONE="America/Sao_Paulo"

# Repos
REPO_70="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_7.0-2+debian12_all.deb"
REPO_74="https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb"
# ------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔] $1${NC}"; }
warn()    { echo -e "${YELLOW}[!] $1${NC}"; }
err()     { echo -e "${RED}[✘] $1${NC}"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; \
            echo -e "${CYAN}  $1${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════════${NC}"; }

[ "$EUID" -ne 0 ] && err "Execute como root: sudo bash $0"

CURRENT_VERSION=$(zabbix_server --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "desconhecida")
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================"
echo "   Upgrade Zabbix 6.4 → 7.0 → 7.4 | Debian 12 + MariaDB"
echo "   Syma Solutions - Suporte"
echo "============================================================"
echo "   Versão atual  : ${CURRENT_VERSION}"
echo "   Versão final  : 7.4"
echo "   Banco         : MariaDB / ${DB_NAME}"
echo "   Web server    : Apache2"
echo "============================================================"
echo ""
warn "O upgrade será feito em 2 estágios com backup em cada um."
warn "Tempo estimado: 5 a 15 minutos dependendo do tamanho do banco."
echo ""
read -rp "Confirma o upgrade? [s/N] " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && { echo "Cancelado."; exit 0; }

# ============================================================
# FUNÇÃO: instala repositório
# ============================================================
install_repo() {
    local url="$1" label="$2"
    log "Instalando repositório Zabbix ${label}..."
    rm -f /etc/apt/sources.list.d/zabbix.list
    TMP_DEB=$(mktemp --suffix=.deb)
    wget -q --show-progress -O "$TMP_DEB" "$url" \
        || err "Falha ao baixar repositório ${label}. URL: ${url}"
    dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
    apt-get update -qq
    log "Repositório ${label} configurado."
}

# ============================================================
# FUNÇÃO: aguarda migração do banco e verifica serviço
# ============================================================
wait_migration() {
    local version="$1"
    log "Aguardando migração do banco para ${version} (até 3 min)..."
    local timeout=180 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        # Verifica se o server está rodando
        if systemctl is-active --quiet zabbix-server; then
            # Verifica no log se a migração concluiu
            if grep -q "server #0 started" /var/log/zabbix/zabbix_server.log 2>/dev/null; then
                log "Migração concluída (${elapsed}s)."
                return 0
            fi
        fi
        echo -n "."
    done
    echo ""
    warn "Timeout aguardando migração. Verifique o log manualmente:"
    warn "  tail -50 /var/log/zabbix/zabbix_server.log"
}

# ============================================================
# FUNÇÃO: backup do banco
# ============================================================
fazer_backup() {
    local tag="$1"
    local file="${BACKUP_DIR}/zabbix_backup_${tag}_$(date +%Y%m%d_%H%M%S).sql"
    log "Fazendo backup do banco (${tag})..."
    mysqldump -u root -p"${DB_ROOT_PASS}" \
        --single-transaction --routines --triggers \
        "${DB_NAME}" > "$file" \
        || err "Falha no backup. Verifique DB_ROOT_PASS no topo do script."
    log "Backup salvo: ${file} ($(du -sh "$file" | cut -f1))"
    echo "$file"
}

# ============================================================
# FUNÇÃO: aplica configurações no zabbix_server.conf
# ============================================================
aplicar_conf() {
    local CONF="/etc/zabbix/zabbix_server.conf"
    set_conf() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$CONF"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$CONF"
        elif grep -q "^# ${key}=" "$CONF"; then
            sed -i "s|^# ${key}=.*|${key}=${val}|" "$CONF"
        else
            echo "${key}=${val}" >> "$CONF"
        fi
    }
    set_conf "DBName"           "${DB_NAME}"
    set_conf "DBUser"           "${DB_USER}"
    set_conf "DBPassword"       "${DB_PASS}"
    set_conf "StartPollers"     "10"
    set_conf "StartPingers"     "5"
    set_conf "StartTrappers"    "10"
    set_conf "CacheSize"        "128M"
    set_conf "HistoryCacheSize" "64M"
    set_conf "TrendCacheSize"   "32M"
    set_conf "ValueCacheSize"   "64M"
    set_conf "Timeout"          "30"
    set_conf "LogSlowQueries"   "3000"
}

# ============================================================
# PRÉ-VERIFICAÇÃO
# ============================================================
section "Pré-verificação"

# Verifica conectividade com o repositório
wget -q --spider "$REPO_70" 2>/dev/null \
    || warn "Não foi possível verificar acesso ao repo 7.0 — continuando mesmo assim."

# Verifica MariaDB
systemctl is-active --quiet mariadb || err "MariaDB não está rodando."
log "MariaDB ativo."

# ============================================================
# ██████████████████████████████████████████████████████████
# ESTÁGIO 1: 6.4 → 7.0
# ██████████████████████████████████████████████████████████
# ============================================================
section "ESTÁGIO 1/2 — Upgrade: 6.4.x → 7.0"

BACKUP_1=$(fazer_backup "v${CURRENT_VERSION}_pre70")

log "Parando serviços Zabbix..."
systemctl stop zabbix-server  || true
systemctl stop zabbix-agent2  || true

install_repo "$REPO_70" "7.0"

log "Instalando pacotes Zabbix 7.0..."
apt-get install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2 \
    || err "Falha na instalação dos pacotes 7.0."

VER_70=$(zabbix_server --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
log "Pacotes 7.0 instalados: ${VER_70}"

aplicar_conf

# Limpa log para monitorar migração limpa
> /var/log/zabbix/zabbix_server.log 2>/dev/null || true

log "Iniciando zabbix-server 7.0 (migração automática do banco)..."
systemctl start zabbix-server

wait_migration "7.0"

# Verifica se realmente está na 7.0
if ! systemctl is-active --quiet zabbix-server; then
    err "zabbix-server 7.0 não subiu. Verifique: tail -50 /var/log/zabbix/zabbix_server.log"
fi

systemctl start zabbix-agent2 || true
systemctl restart apache2

log "Estágio 1 concluído: ${CURRENT_VERSION} → ${VER_70}"
echo ""
warn "Aguardando 10s antes de iniciar o estágio 2..."
sleep 10

# ============================================================
# ██████████████████████████████████████████████████████████
# ESTÁGIO 2: 7.0 → 7.4
# ██████████████████████████████████████████████████████████
# ============================================================
section "ESTÁGIO 2/2 — Upgrade: 7.0 → 7.4"

BACKUP_2=$(fazer_backup "v70_pre74")

log "Parando serviços Zabbix..."
systemctl stop zabbix-server  || true
systemctl stop zabbix-agent2  || true

install_repo "$REPO_74" "7.4"

log "Instalando pacotes Zabbix 7.4..."
apt-get install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2 \
    || err "Falha na instalação dos pacotes 7.4."

VER_74=$(zabbix_server --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
log "Pacotes 7.4 instalados: ${VER_74}"

aplicar_conf

# Aplica configurações de PHP
PHP_INI=$(find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1)
if [ -n "$PHP_INI" ]; then
    sed -i "s/^max_execution_time.*/max_execution_time = 300/"   "$PHP_INI"
    sed -i "s/^memory_limit.*/memory_limit = 256M/"              "$PHP_INI"
    sed -i "s/^post_max_size.*/post_max_size = 32M/"             "$PHP_INI"
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 32M/" "$PHP_INI"
    sed -i "s|^;date.timezone.*|date.timezone = ${TIMEZONE}|"    "$PHP_INI"
    sed -i "s|^date.timezone.*|date.timezone = ${TIMEZONE}|"     "$PHP_INI"
    log "PHP configurado."
fi

# Limpa log para migração limpa
> /var/log/zabbix/zabbix_server.log 2>/dev/null || true

log "Iniciando zabbix-server 7.4 (migração automática do banco)..."
systemctl start zabbix-server

wait_migration "7.4"

systemctl start zabbix-agent2 || true
systemctl restart apache2

systemctl enable zabbix-server zabbix-agent2 apache2

# ============================================================
# RESUMO FINAL
# ============================================================
section "RESULTADO FINAL"

check_service() {
    if systemctl is-active --quiet "$1"; then
        echo -e "  $1  : ${GREEN}ativo${NC}"
    else
        echo -e "  $1  : ${RED}INATIVO — verifique os logs!${NC}"
    fi
}

check_service zabbix-server
check_service zabbix-agent2
check_service apache2
check_service mariadb

echo ""
echo -e "  ${CURRENT_VERSION}  →  ${VER_70}  →  ${GREEN}${VER_74}${NC}"
echo ""
echo "  Acesso Web : http://${SERVER_IP}/zabbix"
echo ""
echo "  Backups gerados:"
echo "    ${BACKUP_1}"
echo "    ${BACKUP_2}"
echo ""
echo "  Últimas linhas do log:"
echo "------------------------------------------------------"
tail -20 /var/log/zabbix/zabbix_server.log 2>/dev/null || \
    journalctl -u zabbix-server -n 20 --no-pager
echo "============================================================"
echo ""
warn "Limpe o cache do navegador ao acessar o frontend."
warn "Se houver Zabbix Proxy no ambiente, atualize-o também."
echo ""
