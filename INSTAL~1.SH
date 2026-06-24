#!/bin/bash
# ============================================================
#  Instalação Zabbix 7.4 - Debian 12 + MySQL/MariaDB
#  Syma Solutions - Suporte
# ============================================================
set -e
# --- CONFIGURAÇÕES - AJUSTE ANTES DE EXECUTAR ---------------
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASS="ZabbixPass@2026"        # troque por uma senha forte
DB_ROOT_PASS="RootPass@2026"     # senha root do MySQL (se novo)
ZABBIX_SERVER_IP="127.0.0.1"
TIMEZONE="America/Sao_Paulo"
# ------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }
[ "$EUID" -ne 0 ] && err "Execute como root: sudo bash $0"
echo ""
echo "============================================================"
echo "   Instalação Zabbix 7.4 + MySQL - Debian 12"
echo "============================================================"
echo ""
# ============================================================
# 1. ATUALIZAR SISTEMA
# ============================================================
log "Atualizando sistema..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget gnupg2 lsb-release ca-certificates \
    apt-transport-https software-properties-common
# ============================================================
# 2. INSTALAR MARIADB
# ============================================================
log "Instalando MariaDB..."
apt-get install -y -qq mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb
# Configurar senha root se MariaDB for novo
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';" 2>/dev/null || true
mysql -u root -p"${DB_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
mysql -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
mysql -u root -p"${DB_ROOT_PASS}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
log "MariaDB configurado."
# ============================================================
# 3. OTIMIZAÇÃO DO MARIADB PARA ZABBIX
# ============================================================
log "Aplicando otimizações no MariaDB..."
cat > /etc/mysql/mariadb.conf.d/99-zabbix.cnf << 'EOF'
[mysqld]
# --- Performance para Zabbix ---
innodb_buffer_pool_size         = 1G
innodb_buffer_pool_instances    = 4
innodb_log_file_size            = 256M
innodb_log_buffer_size          = 64M
innodb_flush_log_at_trx_commit  = 2
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = 1
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8
innodb_io_capacity              = 2000
# --- Conexões e cache ---
max_connections                 = 300
max_allowed_packet              = 64M
table_open_cache                = 4096
table_definition_cache          = 2048
key_buffer_size                 = 64M
sort_buffer_size                = 4M
read_buffer_size                = 2M
read_rnd_buffer_size            = 2M
join_buffer_size                = 4M
tmp_table_size                  = 128M
max_heap_table_size             = 128M
# --- Log lento (opcional, útil para diagnóstico) ---
slow_query_log                  = 1
slow_query_log_file             = /var/log/mysql/slow.log
long_query_time                 = 2
# --- Charset ---
character-set-server            = utf8mb4
collation-server                = utf8mb4_bin
EOF
# Ajuste: se o servidor tiver menos de 4GB RAM, reduz buffer pool
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_RAM" -lt 4000000 ]; then
    warn "RAM < 4GB detectada. Reduzindo innodb_buffer_pool_size para 512M..."
    sed -i 's/innodb_buffer_pool_size.*= 1G/innodb_buffer_pool_size         = 512M/' \
        /etc/mysql/mariadb.conf.d/99-zabbix.cnf
    sed -i 's/innodb_buffer_pool_instances.*= 4/innodb_buffer_pool_instances    = 2/' \
        /etc/mysql/mariadb.conf.d/99-zabbix.cnf
fi
systemctl restart mariadb
log "MariaDB otimizado e reiniciado."
# ============================================================
# 4. CRIAR BANCO DE DADOS ZABBIX
# ============================================================
log "Criando banco de dados Zabbix..."
mysql -u root -p"${DB_ROOT_PASS}" << EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
log "Banco '${DB_NAME}' criado com usuário '${DB_USER}'."
# ============================================================
# 5. INSTALAR REPOSITÓRIO ZABBIX 7.4
# ============================================================
log "Adicionando repositório Zabbix 7.4..."
cd /tmp
wget -q https://repo.zabbix.com/zabbix/7.4/debian/pool/main/z/zabbix-release/zabbix-release_latest+debian12_all.deb
dpkg -i zabbix-release_latest+debian12_all.deb
apt-get update -qq
log "Repositório Zabbix 7.4 adicionado."
# ============================================================
# 6. INSTALAR ZABBIX SERVER, FRONTEND E AGENTE
# ============================================================
log "Instalando Zabbix Server, Frontend e Agent..."
apt-get install -y -qq \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent2
log "Pacotes Zabbix instalados."
# ============================================================
# 7. IMPORTAR SCHEMA DO BANCO
# ============================================================
log "Importando schema do banco (pode demorar 1-3 min)..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | \
    mysql --default-character-set=utf8mb4 \
    -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}"
log "Schema importado com sucesso."
# ============================================================
# 8. CONFIGURAR ZABBIX SERVER
# ============================================================
log "Configurando zabbix_server.conf..."
CONF="/etc/zabbix/zabbix_server.conf"
sed -i "s/^# DBPassword=/DBPassword=/" $CONF
sed -i "s/^DBPassword=.*/DBPassword=${DB_PASS}/" $CONF
sed -i "s/^DBName=.*/DBName=${DB_NAME}/" $CONF
sed -i "s/^DBUser=.*/DBUser=${DB_USER}/" $CONF
# Parâmetros de performance
grep -q "^StartPollers=" $CONF && \
    sed -i "s/^StartPollers=.*/StartPollers=10/" $CONF || \
    echo "StartPollers=10" >> $CONF
grep -q "^StartPingers=" $CONF && \
    sed -i "s/^StartPingers=.*/StartPingers=5/" $CONF || \
    echo "StartPingers=5" >> $CONF
grep -q "^StartTrappers=" $CONF && \
    sed -i "s/^StartTrappers=.*/StartTrappers=10/" $CONF || \
    echo "StartTrappers=10" >> $CONF
grep -q "^CacheSize=" $CONF && \
    sed -i "s/^CacheSize=.*/CacheSize=128M/" $CONF || \
    echo "CacheSize=128M" >> $CONF
grep -q "^HistoryCacheSize=" $CONF && \
    sed -i "s/^HistoryCacheSize=.*/HistoryCacheSize=64M/" $CONF || \
    echo "HistoryCacheSize=64M" >> $CONF
grep -q "^TrendCacheSize=" $CONF && \
    sed -i "s/^TrendCacheSize=.*/TrendCacheSize=32M/" $CONF || \
    echo "TrendCacheSize=32M" >> $CONF
grep -q "^ValueCacheSize=" $CONF && \
    sed -i "s/^ValueCacheSize=.*/ValueCacheSize=64M/" $CONF || \
    echo "ValueCacheSize=64M" >> $CONF
grep -q "^Timeout=" $CONF && \
    sed -i "s/^Timeout=.*/Timeout=30/" $CONF || \
    echo "Timeout=30" >> $CONF
grep -q "^LogSlowQueries=" $CONF && \
    sed -i "s/^LogSlowQueries=.*/LogSlowQueries=3000/" $CONF || \
    echo "LogSlowQueries=3000" >> $CONF
log "zabbix_server.conf configurado."
# ============================================================
# 9. CONFIGURAR PHP / APACHE
# ============================================================
log "Configurando PHP para o Zabbix..."
PHP_INI=$(find /etc/php -name "php.ini" -path "*/apache2/*" 2>/dev/null | head -1)
if [ -n "$PHP_INI" ]; then
    sed -i "s/^max_execution_time.*/max_execution_time = 300/"    $PHP_INI
    sed -i "s/^memory_limit.*/memory_limit = 256M/"               $PHP_INI
    sed -i "s/^post_max_size.*/post_max_size = 32M/"              $PHP_INI
    sed -i "s/^upload_max_filesize.*/upload_max_filesize = 32M/"  $PHP_INI
    sed -i "s|^;date.timezone.*|date.timezone = ${TIMEZONE}|"     $PHP_INI
    sed -i "s|^date.timezone.*|date.timezone = ${TIMEZONE}|"      $PHP_INI
    log "PHP configurado: $PHP_INI"
else
    warn "php.ini não encontrado, configure manualmente o timezone e limites."
fi
# ============================================================
# 10. CONFIGURAR AGENTE2
# ============================================================
log "Configurando Zabbix Agent2..."
cat > /etc/zabbix/zabbix_agent2.conf << EOF
PidFile=/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
Server=${ZABBIX_SERVER_IP}
ServerActive=${ZABBIX_SERVER_IP}
Hostname=$(hostname)
Include=/etc/zabbix/zabbix_agent2.d/*.conf
EOF
log "Agent2 configurado."
# ============================================================
# 11. AJUSTES NO SISTEMA (kernel/limites)
# ============================================================
log "Aplicando ajustes no sistema..."
# Aumentar limites de arquivos abertos
cat >> /etc/security/limits.conf << 'EOF'
zabbix soft nofile 65536
zabbix hard nofile 65536
EOF
# Parâmetros de kernel para performance de rede
cat > /etc/sysctl.d/99-zabbix.conf << 'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-zabbix.conf -q
log "Ajustes de sistema aplicados."
# ============================================================
# 12. HABILITAR E INICIAR SERVIÇOS
# ============================================================
log "Iniciando e habilitando serviços..."
systemctl enable zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2
log "Serviços iniciados."
# ============================================================
# 13. FIREWALL (UFW se instalado)
# ============================================================
if command -v ufw &>/dev/null; then
    log "Configurando UFW..."
    ufw allow 80/tcp    comment "Zabbix Web"
    ufw allow 443/tcp   comment "Zabbix Web HTTPS"
    ufw allow 10050/tcp comment "Zabbix Agent"
    ufw allow 10051/tcp comment "Zabbix Server (trapper)"
    warn "UFW configurado. Verifique com: ufw status"
fi
# ============================================================
# RESUMO FINAL
# ============================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================================"
echo -e "${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo "============================================================"
echo ""
echo "  Acesso Web:    http://${SERVER_IP}/zabbix"
echo "  Usuário:       Admin"
echo "  Senha padrão:  zabbix"
echo ""
echo "  DB Name:       ${DB_NAME}"
echo "  DB User:       ${DB_USER}"
echo "  DB Password:   ${DB_PASS}"
echo "  DB Root Pass:  ${DB_ROOT_PASS}"
echo ""
echo "  PRÓXIMOS PASSOS:"
echo "  1. Acesse http://${SERVER_IP}/zabbix e finalize pelo wizard"
echo "  2. Troque a senha do usuário Admin imediatamente"
echo "  3. Configure housekeeping: Admin > Geral > Housekeeping"
echo "  4. Ative compressão de histórico se usar PostgreSQL (TimescaleDB)"
echo ""
echo "  Verificar status:"
echo "  systemctl status zabbix-server"
echo "  tail -f /var/log/zabbix/zabbix_server.log"
echo "============================================================"
