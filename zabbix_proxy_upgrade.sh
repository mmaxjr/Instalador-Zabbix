#!/bin/bash
# ============================================================
# Upgrade Zabbix Proxy -> 7.4 (sem alterar configurações)
# Syma Solutions - Suporte
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()     { echo -e "${GREEN}[OK]${NC} $1"; }
fail()   { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
header() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

ZABBIX_VERSION="7.4"
CONF_FILE="/etc/zabbix/zabbix_proxy.conf"
BACKUP_DIR="/etc/zabbix/backup_upgrade_$(date +%Y%m%d_%H%M%S)"

# ---- Root check ----
[ "$EUID" -ne 0 ] && fail "Execute como root: sudo bash $0"

echo "============================================================"
echo " Upgrade Zabbix Proxy para $ZABBIX_VERSION"
echo " $(date)"
echo "============================================================"

# ---- Detecta OS ----
header "Detectando sistema operacional"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_VERSION=$VERSION_ID
    OS_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
    ok "Sistema: $PRETTY_NAME"
else
    fail "Não foi possível detectar o sistema operacional"
fi

case "$OS_ID" in
    ubuntu|debian) PKG_MANAGER="apt" ;;
    rhel|centos|rocky|almalinux|ol) PKG_MANAGER="yum" ;;
    *) fail "Sistema não suportado: $OS_ID" ;;
esac

# ---- Versão atual do proxy ----
header "Versão atual do Zabbix Proxy"
CURRENT_VERSION=$(zabbix_proxy --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -n "$CURRENT_VERSION" ]; then
    ok "Versão instalada: $CURRENT_VERSION"
else
    warn "Não foi possível detectar a versão atual (proxy pode estar parado)"
fi

# ---- Detecta banco de dados do proxy ----
header "Detectando banco de dados"
if dpkg -l zabbix-proxy-mysql &>/dev/null 2>&1 || rpm -q zabbix-proxy-mysql &>/dev/null 2>&1; then
    DB_TYPE="mysql"
elif dpkg -l zabbix-proxy-pgsql &>/dev/null 2>&1 || rpm -q zabbix-proxy-pgsql &>/dev/null 2>&1; then
    DB_TYPE="pgsql"
elif dpkg -l zabbix-proxy-sqlite3 &>/dev/null 2>&1 || rpm -q zabbix-proxy-sqlite3 &>/dev/null 2>&1; then
    DB_TYPE="sqlite3"
else
    # Tenta detectar pelo conf
    DB_TYPE="mysql"
    warn "Não detectou pacote DB — assumindo mysql. Ajuste a variável DB_TYPE se necessário."
fi
ok "Banco detectado: $DB_TYPE"

# ---- Backup das configurações ----
header "Backup das configurações"
mkdir -p "$BACKUP_DIR"

if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "$BACKUP_DIR/"
    ok "Backup: $BACKUP_DIR/zabbix_proxy.conf"
else
    warn "Arquivo $CONF_FILE não encontrado — continuando sem backup"
fi

# Backup de configs extras se existirem
[ -d /etc/zabbix/zabbix_proxy.d ] && cp -r /etc/zabbix/zabbix_proxy.d "$BACKUP_DIR/"

# ---- Para o serviço ----
header "Parando Zabbix Proxy"
SVC_NAME="zabbix-proxy"
systemctl stop $SVC_NAME 2>/dev/null && ok "Serviço parado" || warn "Serviço já estava parado"

# ---- Instala repositório Zabbix 7.4 ----
header "Configurando repositório Zabbix $ZABBIX_VERSION"

if [ "$PKG_MANAGER" = "apt" ]; then
    # Detecta codename (ubuntu/debian)
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")

    # Define URL do repo conforme OS
    if [ "$OS_ID" = "ubuntu" ]; then
        REPO_PKG="zabbix-release_latest_${ZABBIX_VERSION}+ubuntu${OS_MAJOR}.04_all.deb"
        REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/${REPO_PKG}"
    else
        REPO_PKG="zabbix-release_latest_${ZABBIX_VERSION}+debian${OS_MAJOR}_all.deb"
        REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/${REPO_PKG}"
    fi

    echo "Baixando: $REPO_URL"
    wget -q "$REPO_URL" -O /tmp/zabbix-release.deb || fail "Falha ao baixar repositório"
    dpkg -i /tmp/zabbix-release.deb || fail "Falha ao instalar pacote do repositório"
    apt-get update -qq
    ok "Repositório configurado"

elif [ "$PKG_MANAGER" = "yum" ]; then
    REPO_PKG="zabbix-release_latest_${ZABBIX_VERSION}+rhel${OS_MAJOR}_all.rpm"
    REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/rhel/${OS_MAJOR}/noarch/${REPO_PKG}"

    echo "Baixando: $REPO_URL"
    rpm -Uvh "$REPO_URL" 2>/dev/null || warn "Repositório já pode estar instalado"
    yum clean all -q
    ok "Repositório configurado"
fi

# ---- Atualiza apenas os pacotes do proxy ----
header "Atualizando Zabbix Proxy para $ZABBIX_VERSION"

PKGS="zabbix-proxy-${DB_TYPE} zabbix-sql-scripts"

if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get install --only-upgrade -y $PKGS || fail "Falha na atualização dos pacotes"
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum update -y $PKGS || fail "Falha na atualização dos pacotes"
fi

NEW_VERSION=$(zabbix_proxy --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)
ok "Versão após upgrade: ${NEW_VERSION:-desconhecida}"

# ---- Restaura configuração (garantia) ----
header "Verificando configuração"
if [ -f "$BACKUP_DIR/zabbix_proxy.conf" ] && [ -f "$CONF_FILE" ]; then
    # Compara se o upgrade sobrescreveu o conf
    if ! diff -q "$CONF_FILE" "$BACKUP_DIR/zabbix_proxy.conf" &>/dev/null; then
        warn "O arquivo de configuração foi alterado pelo upgrade — restaurando backup"
        cp "$BACKUP_DIR/zabbix_proxy.conf" "$CONF_FILE"
        ok "Configuração original restaurada"
    else
        ok "Configuração intacta — nenhuma alteração detectada"
    fi
fi

# ---- Inicia o serviço ----
header "Iniciando Zabbix Proxy"
systemctl enable $SVC_NAME &>/dev/null
systemctl start $SVC_NAME

sleep 3
STATUS=$(systemctl is-active $SVC_NAME)
if [ "$STATUS" = "active" ]; then
    ok "Zabbix Proxy iniciado com sucesso"
else
    fail "Falha ao iniciar — verifique: journalctl -u $SVC_NAME -n 50"
fi

# ---- Resumo ----
echo ""
echo "============================================================"
echo -e " ${GREEN}Upgrade concluído!${NC}"
echo "  Versão anterior : ${CURRENT_VERSION:-desconhecida}"
echo "  Versão atual    : ${NEW_VERSION:-desconhecida}"
echo "  Backup conf     : $BACKUP_DIR/"
echo "  Status serviço  : $STATUS"
echo ""
echo " Logs do proxy:"
echo "   journalctl -u zabbix-proxy -f"
echo "   tail -f /var/log/zabbix/zabbix_proxy.log"
echo "============================================================"
