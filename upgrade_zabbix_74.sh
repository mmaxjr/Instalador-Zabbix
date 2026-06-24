#!/bin/bash
# ============================================================
#  Upgrade Zabbix 7.0.x → 7.4 - Debian 12 + MariaDB + Apache
#  Syma Solutions - Suporte
# ============================================================
set -e

# --- CONFIGURAÇÕES — ajuste se mudou desde a instalação -----
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="ZabbixPass@2026"
DB_ROOT_PASS="RootPass@2026"
BACKUP_DIR="/root"
TIMEZONE="America/Sao_Paulo"
# ------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && err "Execute como root: sudo bash $0"

CURRENT_VERSION=$(zabbix_server --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "desconhecida")

echo ""
echo "============================================================"
echo "   Upgrade Zabbix → 7.4 | Debian 12 + MariaDB + Apache"
echo "   Syma Solutions - Suporte"
echo "============================================================"
echo "   Versão atual detectada : ${CURRENT_VERSION}"
echo "   Banco                  : MariaDB / ${DB_NAME}"
echo "   Web server             : Apache2"
echo "============================================================"
echo ""
warn "Este script irá:"
warn "  1. Fazer backup do banco ${DB_NAME}"
warn "  2. Parar zabbix-server e zabbix-agent2"
warn "  3. Trocar o repositório para Zabbix 7.4"
warn "  4. Atualizar os pacotes"
warn "  5. Reiniciar e verificar os serviços"
echo ""
read -rp "Confirma o upgrade? [s/N] " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && { echo "Cancelado."; exit 0; }

# ============================================================
# 1. BACKUP DO BANCO
# ============================================================
log "Fazendo backup do banco '${DB_NAME}'..."

BACKUP_FILE="${BACKUP_DIR}/zabbix_backup_${CURRENT_VERSION}_$(date +%Y%m%d_%H%M%S).sql"

mysqldump -u root -p"${DB_ROOT_PASS}" \
    --single-transaction \
    --routines \
    --triggers \
    "${DB_NAME}" > "${BACKUP_FILE}" \
    || err "Falha no backup. Verifique DB_ROOT_PASS no topo do script."

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log "Backup salvo: ${BACKUP_FILE} (${BACKUP_SIZE})"

# ============================================================
# 2. PARAR SERVIÇOS
# ============================================================
log "Parando serviços Zabbix..."

systemctl stop zabbix-server  && log "zabbix-server parado."  || warn "zabbix-server já estava parado."
systemctl stop zabbix-agent2  && log "zabbix-agent2 parado."  || warn "zabbix-agent2 já estava parado."

# ============================================================
# 3. TROCAR REPOSITÓRIO PARA 7.4
# ============================================================
log "Trocando repositório para Zabbix 7.4..."

# Remove repo 7.0
rm -f /etc/apt/sources.list.d/zabbix.list

# Baixa e instala repo 7.4
TMP_DEB=$(mktemp --suffix=.deb)
wget -q --show-progress \
    -O "$TMP_DEB" \
    "https://repo.zabbix.com/zabbix/7.4/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.4+debian12_all.deb" \
    || err "Falha ao baixar repositório. Verifique conectividade."

dpkg -i "$TMP_DEB"
rm -f "$TMP_DEB"
apt-get update -qq

log "Repositório 7.4 configurado."

# ============================================================
# 4. ATUALIZAR PACOTES ZABBIX
# ============================================================
log "Atualizando pacotes Zabbix..."

apt-get install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2 \
    || err "Falha na atualização dos pacotes."

NEW_VERSION=$(zabbix_server --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
log "Pacotes atualizados → versão ${NEW_VERSION}"

# ============================================================
# 5. GARANTIR CONFIGURAÇÕES DO ZABBIX SERVER
# ============================================================
log "Verificando zabbix_server.conf..."

CONF="/etc/zabbix/zabbix_server.conf"

# Função auxiliar para setar ou adicionar parâmetro
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

log "zabbix_server.conf verificado."

# ============================================================
# 6. GARANTIR CONFIGURAÇÕES DO PHP
# ============================================================
PHP_INI=$(find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1)
if [ -n "$PHP_INI" ]; then
    log "Verificando PHP: ${PHP_INI}"
    sed -i "s/^max_execution_time.*/max_execution_time = 300/"   "$PHP_INI"
    sed -i "s/^memory_limit.*/memory_limit = 256M/"              "$PHP_INI"
    sed -i "s/^post_max_size.*/post_max_size = 32M/"             "$PHP_INI"
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 32M/" "$PHP_INI"
    sed -i "s|^;date.timezone.*|date.timezone = ${TIMEZONE}|"    "$PHP_INI"
    sed -i "s|^date.timezone.*|date.timezone = ${TIMEZONE}|"     "$PHP_INI"
    log "PHP configurado."
else
    warn "php.ini não encontrado — verifique o timezone manualmente."
fi

# ============================================================
# 7. INICIAR SERVIÇOS
# ============================================================
# O zabbix-server detecta automaticamente que o schema precisa
# de migração e a executa na primeira inicialização.

log "Iniciando serviços (a migração do banco ocorre automaticamente)..."

systemctl start zabbix-server
systemctl start zabbix-agent2
systemctl restart apache2

systemctl enable zabbix-server zabbix-agent2 apache2

log "Serviços iniciados. Aguardando 30s para a migração do banco..."
sleep 30

# ============================================================
# 8. VERIFICAÇÃO FINAL
# ============================================================
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================"
echo -e "${GREEN}   RESULTADO DO UPGRADE${NC}"
echo "============================================================"

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        echo -e "  ${svc}  : ${GREEN}ativo${NC}"
    else
        echo -e "  ${svc}  : ${RED}INATIVO — verifique os logs!${NC}"
    fi
}

check_service zabbix-server
check_service zabbix-agent2
check_service apache2
check_service mariadb

echo ""
echo "  Versão anterior : ${CURRENT_VERSION}"
echo "  Versão atual    : ${NEW_VERSION}"
echo ""
echo "  Acesso Web : http://${SERVER_IP}/zabbix"
echo ""
echo "  Backup do banco : ${BACKUP_FILE} (${BACKUP_SIZE})"
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
