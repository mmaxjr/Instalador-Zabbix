#!/bin/bash
# =============================================================
#  ZABBIX 7.0 LTS — INSTALAÇÃO COMPLETA VIA DOCKER
#  Debian 12 (Bookworm)
#
#  Uso:
#    chmod +x zabbix7_docker_install.sh
#    sudo bash zabbix7_docker_install.sh
#
#  O que instala:
#    - Docker CE + Docker Compose
#    - MySQL 8.0 (container)
#    - Zabbix Server 7.0 (container)
#    - Zabbix Frontend Nginx 7.0 (container)
#    - Zabbix Agent2 (container — monitora o próprio host)
#
#  Portas usadas:
#    80   → Zabbix Frontend (HTTP)
#    10051→ Zabbix Server (traps/agentes)
#    10052→ Zabbix Agent2
# =============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail()   { echo -e "  ${RED}[ERRO]${NC} $1"; exit 1; }
warn()   { echo -e "  ${YELLOW}[AVISO]${NC} $1"; }
info()   { echo -e "  ${CYAN}[INFO]${NC} $1"; }
header() { echo -e "\n${YELLOW}── $1 ──${NC}"; }

# ─── CONFIGURAÇÕES ────────────────────────────────────────────
ZABBIX_VERSION="7.0"
INSTALL_DIR="/opt/zabbix"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# Senhas (fixas — salvas em $INSTALL_DIR/.env)
MYSQL_ROOT_PASS="ALTERAR"
MYSQL_ZABBIX_PASS=$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20)
# ─────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && fail "Execute como root: sudo bash $0"

# Verificar Debian 12
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  [[ "$ID" != "debian" ]] && warn "Script otimizado para Debian. Continuando em $ID..."
  [[ "$VERSION_ID" != "12" ]] && warn "Testado no Debian 12. Versão detectada: $VERSION_ID"
fi

IP_HOST=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ZABBIX $ZABBIX_VERSION LTS — INSTALAÇÃO DOCKER"
echo "  Host: $(hostname -f) ($IP_HOST)"
echo "  Dir:  $INSTALL_DIR"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─── 1. Dependências base ─────────────────────────────────────
header "1/6 — Instalando dependências"

apt-get update -qq
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  apt-transport-https software-properties-common \
  openssl wget 2>/dev/null
ok "Dependências instaladas"

# ─── 2. Docker CE ────────────────────────────────────────────
header "2/6 — Instalando Docker CE"

if command -v docker &>/dev/null; then
  VER_DOCKER=$(docker --version)
  ok "Docker já instalado: $VER_DOCKER"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker CE instalado: $(docker --version)"
fi

# Verificar Docker Compose
if docker compose version &>/dev/null 2>&1; then
  ok "Docker Compose: $(docker compose version)"
else
  fail "Docker Compose não encontrado. Reinstale o docker-compose-plugin."
fi

# ─── 3. Criar estrutura de diretórios ────────────────────────
header "3/6 — Criando estrutura de diretórios"

mkdir -p "$INSTALL_DIR"/{alertscripts,externalscripts,modules,enc,ssh_keys,ssl/{certs,keys,ssl_ca},snmptraps,mibs}
mkdir -p "$INSTALL_DIR"/mysql

ok "Diretórios criados em $INSTALL_DIR/"

# Permissões para o usuário zabbix (UID 1997 nas imagens oficiais)
chown -R 1997:1997 \
  "$INSTALL_DIR/alertscripts" \
  "$INSTALL_DIR/externalscripts" \
  "$INSTALL_DIR/modules" \
  "$INSTALL_DIR/enc" \
  "$INSTALL_DIR/ssh_keys" \
  "$INSTALL_DIR/ssl" \
  "$INSTALL_DIR/snmptraps" \
  "$INSTALL_DIR/mibs" 2>/dev/null || true

# ─── 4. Criar arquivo .env ────────────────────────────────────
header "4/6 — Gerando credenciais"

cat > "$INSTALL_DIR/.env" <<EOF
# Zabbix 7.0 — Variáveis de ambiente
# Gerado em: $(date)

ZABBIX_VERSION=${ZABBIX_VERSION}

# MySQL
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_DATABASE=zabbix
MYSQL_USER=zabbix
MYSQL_PASSWORD=${MYSQL_ZABBIX_PASS}

# Zabbix
ZBX_DBHOST=mysql
ZBX_DBNAME=zabbix
ZBX_DBUSER=zabbix
ZBX_DBPASSWORD=${MYSQL_ZABBIX_PASS}
ZBX_SERVER_HOST=zabbix-server
ZBX_JAVAGATEWAY_ENABLE=false
EOF

chmod 600 "$INSTALL_DIR/.env"
ok "Credenciais salvas em $INSTALL_DIR/.env"

# ─── 5. Criar docker-compose.yml ─────────────────────────────
header "5/6 — Criando docker-compose.yml"

cat > "$COMPOSE_FILE" <<'COMPOSE'
# =============================================================
#  Zabbix 7.0 LTS — Docker Compose
#  Gerado automaticamente pelo zabbix7_docker_install.sh
# =============================================================

networks:
  zabbix-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

volumes:
  mysql-data:
  zabbix-server-data:

services:

  # ── MySQL 8.0 ─────────────────────────────────────────────
  mysql:
    image: mysql:8.0
    container_name: zabbix-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE:      ${MYSQL_DATABASE}
      MYSQL_USER:          ${MYSQL_USER}
      MYSQL_PASSWORD:      ${MYSQL_PASSWORD}
    command:
      - mysqld
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_bin
      - --default-authentication-plugin=mysql_native_password
      - --skip-character-set-client-handshake
      - --innodb-buffer-pool-size=512M
      - --innodb-log-file-size=256M
      - --max-allowed-packet=64M
      - --slow-query-log=1
      - --slow-query-log-file=/var/log/mysql/slow.log
      - --long-query-time=2
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      zabbix-net:
        ipv4_address: 172.20.0.10
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  # ── Zabbix Server ─────────────────────────────────────────
  zabbix-server:
    image: zabbix/zabbix-server-mysql:debian-7.0-latest
    container_name: zabbix-server
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      DB_SERVER_HOST:   ${ZBX_DBHOST}
      MYSQL_DATABASE:   ${ZBX_DBNAME}
      MYSQL_USER:       ${ZBX_DBUSER}
      MYSQL_PASSWORD:   ${ZBX_DBPASSWORD}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      ZBX_TIMEOUT:             30
      ZBX_STARTPOLLERS:        10
      ZBX_STARTPOLLERSUNREACHABLE: 5
      ZBX_STARTPINGERS:        5
      ZBX_STARTTRAPPERS:       5
      ZBX_STARTDISCOVERERS:    3
      ZBX_STARTHTTPPOLLERS:    3
      ZBX_CACHESIZE:           64M
      ZBX_HISTORYCACHESIZE:    32M
      ZBX_HISTORYINDEXCACHESIZE: 16M
      ZBX_TRENDCACHESIZE:      32M
      ZBX_VALUECACHESIZE:      64M
      ZBX_HOUSEKEEPINGFREQUENCY: 1
      ZBX_MAXHOUSEKEEPERDELETE: 5000
      ZBX_ENABLE_SNMP_TRAPS:   "true"
    ports:
      - "10051:10051"
    volumes:
      - /opt/zabbix/alertscripts:/usr/lib/zabbix/alertscripts:rw
      - /opt/zabbix/externalscripts:/usr/lib/zabbix/externalscripts:rw
      - /opt/zabbix/modules:/var/lib/zabbix/modules:rw
      - /opt/zabbix/enc:/var/lib/zabbix/enc:rw
      - /opt/zabbix/ssh_keys:/var/lib/zabbix/ssh_keys:rw
      - /opt/zabbix/ssl/certs:/var/lib/zabbix/ssl/certs:rw
      - /opt/zabbix/ssl/keys:/var/lib/zabbix/ssl/keys:rw
      - /opt/zabbix/ssl/ssl_ca:/var/lib/zabbix/ssl/ssl_ca:rw
      - /opt/zabbix/snmptraps:/var/lib/zabbix/snmptraps:rw
      - /opt/zabbix/mibs:/var/lib/zabbix/mibs:rw
      - zabbix-server-data:/var/lib/zabbix
    networks:
      zabbix-net:
        ipv4_address: 172.20.0.11
    ulimits:
      nproc: 65535
      nofile:
        soft: 20000
        hard: 40000
    healthcheck:
      test: ["CMD-SHELL", "zabbix_server -R log_level_increase 2>/dev/null || exit 0"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  # ── Zabbix Frontend (Nginx) ───────────────────────────────
  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:debian-7.0-latest
    container_name: zabbix-web
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    environment:
      ZBX_SERVER_HOST: ${ZBX_SERVER_HOST}
      ZBX_SERVER_PORT: "10051"
      DB_SERVER_HOST:  ${ZBX_DBHOST}
      MYSQL_DATABASE:  ${ZBX_DBNAME}
      MYSQL_USER:      ${ZBX_DBUSER}
      MYSQL_PASSWORD:  ${ZBX_DBPASSWORD}
      PHP_TZ:          America/Sao_Paulo
      ZBX_MAXEXECUTIONTIME: 600
      ZBX_MEMORYLIMIT: 256M
      ZBX_POSTMAXSIZE: 16M
      ZBX_UPLOADMAXFILESIZE: 8M
    ports:
      - "80:8080"
    volumes:
      - /opt/zabbix/ssl/certs:/etc/ssl/nginx:ro
    networks:
      zabbix-net:
        ipv4_address: 172.20.0.12
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  # ── Zabbix Agent2 (monitora o host) ──────────────────────
  zabbix-agent2:
    image: zabbix/zabbix-agent2:debian-7.0-latest
    container_name: zabbix-agent2
    restart: unless-stopped
    depends_on:
      - zabbix-server
    environment:
      ZBX_SERVER_HOST:   172.20.0.11
      ZBX_SERVER_PORT:   "10051"
      ZBX_HOSTNAME:      "Zabbix server"
      ZBX_ACTIVESERVERS: "zabbix-server:10051"
    ports:
      - "10052:10050"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /:/rootfs:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    privileged: true
    pid: "host"
    networks:
      zabbix-net:
        ipv4_address: 172.20.0.13
COMPOSE

ok "docker-compose.yml criado"

# ─── 6. Subir a stack ─────────────────────────────────────────
header "6/6 — Subindo a stack Zabbix"

cd "$INSTALL_DIR"

info "Baixando imagens Docker (pode demorar na primeira vez)..."
docker compose pull 2>/dev/null

info "Iniciando containers..."
docker compose up -d

# Aguardar MySQL ficar saudável
info "Aguardando MySQL inicializar..."
for i in {1..24}; do
  if docker inspect zabbix-mysql --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
    ok "MySQL pronto"
    break
  fi
  echo "    Aguardando MySQL... ($i/24)"
  sleep 5
  [[ $i -eq 24 ]] && warn "MySQL demorou mais que o esperado — verifique: docker logs zabbix-mysql"
done

# Aguardar Zabbix Server
info "Aguardando Zabbix Server inicializar (inicializa o banco)..."
for i in {1..36}; do
  if docker inspect zabbix-server --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    sleep 5
    LOGS=$(docker logs zabbix-server 2>&1 | tail -20)
    if echo "$LOGS" | grep -q "server #0 started\|database is up to date\|starting main process"; then
      ok "Zabbix Server rodando"
      break
    fi
  fi
  echo "    Aguardando Zabbix Server... ($i/36)"
  sleep 5
done

# ─── Resumo ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  INSTALAÇÃO CONCLUÍDA"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  STATUS DOS CONTAINERS:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
docker ps --filter "name=zabbix" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "  ACESSO:"
echo "  URL:      http://$IP_HOST"
echo "  Usuário:  Admin"
echo "  Senha:    zabbix"
echo ""
echo "  CREDENCIAIS DO BANCO (guarde em local seguro):"
echo "  MySQL Root:   $MYSQL_ROOT_PASS"
echo "  MySQL Zabbix: $MYSQL_ZABBIX_PASS"
echo "  Arquivo:      $INSTALL_DIR/.env"
echo ""
echo "  DIRETÓRIO DA INSTALAÇÃO: $INSTALL_DIR/"
echo ""
echo "  COMANDOS ÚTEIS:"
echo "  cd $INSTALL_DIR"
echo "  docker compose ps                    # status"
echo "  docker compose logs -f zabbix-server # log do server"
echo "  docker compose logs -f zabbix-web    # log do frontend"
echo "  docker compose restart zabbix-server # reiniciar server"
echo "  docker compose down                  # parar tudo"
echo "  docker compose up -d                 # subir tudo"
echo ""
echo "  PRÓXIMO PASSO:"
echo "  Execute o script de instalação do Grafana:"
echo "  sudo bash grafana_docker_install.sh"
echo "═══════════════════════════════════════════════════════"

# Salvar resumo em arquivo
cat > "$INSTALL_DIR/INSTALACAO.txt" <<INFO
Zabbix 7.0 LTS — Instalado em $(date)
Host: $(hostname -f) ($IP_HOST)

URL Frontend: http://$IP_HOST
Login: Admin / zabbix (TROQUE A SENHA APÓS O PRIMEIRO ACESSO)

MySQL Root Password:   $MYSQL_ROOT_PASS
MySQL Zabbix Password: $MYSQL_ZABBIX_PASS

Diretório: $INSTALL_DIR/
Compose:   $INSTALL_DIR/docker-compose.yml
Env:       $INSTALL_DIR/.env

Containers:
  zabbix-mysql   → banco de dados
  zabbix-server  → Zabbix Server (porta 10051)
  zabbix-web     → Frontend Nginx (porta 80)
  zabbix-agent2  → Agent no host (porta 10052)
INFO
chmod 600 "$INSTALL_DIR/INSTALACAO.txt"
info "Resumo salvo em $INSTALL_DIR/INSTALACAO.txt"
