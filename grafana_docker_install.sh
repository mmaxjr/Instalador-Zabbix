#!/bin/bash
# =============================================================
#  GRAFANA — INSTALAÇÃO VIA DOCKER
#  Debian 12 — Integrado com Zabbix 7.0
#
#  Uso:
#    chmod +x grafana_docker_install.sh
#    sudo bash grafana_docker_install.sh
#
#  Pré-requisito: Docker instalado (rode primeiro o
#  zabbix7_docker_install.sh ou tenha Docker instalado)
#
#  O que instala:
#    - Grafana OSS (latest) via Docker
#    - Plugin: alexanderzobnin-zabbix-app (integração Zabbix)
#    - Porta: 3000
#
#  Após instalar:
#    Acesse http://IP:3000
#    Login: admin / admin (troque na primeira entrada)
#    Ative o plugin Zabbix em: Plugins → Zabbix → Enable
#    Adicione datasource: Zabbix → URL da API do Zabbix
# =============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()     { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail()   { echo -e "  ${RED}[ERRO]${NC} $1"; exit 1; }
warn()   { echo -e "  ${YELLOW}[AVISO]${NC} $1"; }
info()   { echo -e "  ${CYAN}[INFO]${NC} $1"; }
header() { echo -e "\n${YELLOW}── $1 ──${NC}"; }

# ─── CONFIGURAÇÕES ────────────────────────────────────────────
INSTALL_DIR="/opt/grafana"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
GRAFANA_PORT="3000"
ZABBIX_DIR="/opt/zabbix"   # Diretório do Zabbix (para rede compartilhada)

# Senha admin inicial (troque após o primeiro acesso)
GRAFANA_ADMIN_PASS="Grafana@Syma2024"
# ─────────────────────────────────────────────────────────────

[[ $EUID -ne 0 ]] && fail "Execute como root: sudo bash $0"

command -v docker &>/dev/null || fail "Docker não encontrado. Execute primeiro: zabbix7_docker_install.sh"

IP_HOST=$(hostname -I | awk '{print $1}')
ZABBIX_URL="http://${IP_HOST}/api_jsonrpc.php"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  GRAFANA — INSTALAÇÃO DOCKER"
echo "  Host: $(hostname -f) ($IP_HOST)"
echo "  Dir:  $INSTALL_DIR"
echo "  Porta: $GRAFANA_PORT"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─── 1. Criar diretórios ─────────────────────────────────────
header "1/4 — Criando diretórios"

mkdir -p "$INSTALL_DIR"/{data,provisioning/{datasources,dashboards,notifiers},plugins}

# Grafana roda com UID 472
chown -R 472:472 "$INSTALL_DIR/data" "$INSTALL_DIR/provisioning" 2>/dev/null || true

ok "Diretórios criados em $INSTALL_DIR/"

# ─── 2. Provisioning automático do datasource Zabbix ─────────
header "2/4 — Configurando datasource Zabbix (provisioning)"

cat > "$INSTALL_DIR/provisioning/datasources/zabbix.yml" <<EOF
# Provisioning automático — datasource Zabbix
# Gerado em: $(date)
apiVersion: 1

datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-datasource
    access: proxy
    url: ${ZABBIX_URL}
    jsonData:
      username: Admin
      trends: true
      trendsFrom: "7d"
      trendsRange: "4d"
      cacheTTL: "1h"
      alerting: true
      addThresholds: false
      dbConnectionEnable: false
    secureJsonData:
      password: "ALTERAR SENHA"
    isDefault: true
    editable: true
EOF

ok "Datasource Zabbix configurado em provisioning"

# Dashboard de exemplo (Zabbix host stats)
mkdir -p "$INSTALL_DIR/provisioning/dashboards"
cat > "$INSTALL_DIR/provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1
providers:
  - name: Zabbix Dashboards
    orgId: 1
    folder: Zabbix
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
EOF

mkdir -p "$INSTALL_DIR/data/dashboards"
chown -R 472:472 "$INSTALL_DIR/data" 2>/dev/null || true

ok "Provisioning de dashboards configurado"

# ─── 3. Criar docker-compose.yml ─────────────────────────────
header "3/4 — Criando docker-compose.yml"

# Verificar se a rede do Zabbix existe
ZABBIX_NETWORK=""
if docker network ls | grep -q "zabbix_zabbix-net\|zabbix-net"; then
  ZABBIX_NETWORK="zabbix_zabbix-net"
  info "Rede do Zabbix detectada: $ZABBIX_NETWORK"
  info "Grafana será conectado na mesma rede para acesso direto ao servidor."
fi

cat > "$COMPOSE_FILE" <<COMPOSE
# =============================================================
#  Grafana — Docker Compose
#  Gerado automaticamente pelo grafana_docker_install.sh
# =============================================================

networks:
  grafana-net:
    driver: bridge
$(if [[ -n "$ZABBIX_NETWORK" ]]; then
echo "  zabbix_zabbix-net:"
echo "    external: true"
fi)

volumes:
  grafana-data:

services:

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    user: "472"
    environment:
      # Admin
      GF_SECURITY_ADMIN_USER:     admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASS}

      # Servidor
      GF_SERVER_HTTP_PORT:        ${GRAFANA_PORT}
      GF_SERVER_DOMAIN:           ${IP_HOST}
      GF_SERVER_ROOT_URL:         "http://${IP_HOST}:${GRAFANA_PORT}"

      # Plugins
      GF_INSTALL_PLUGINS:         "alexanderzobnin-zabbix-app"

      # Configurações gerais
      GF_USERS_ALLOW_SIGN_UP:     "false"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_LOG_LEVEL:               warn

      # Alerting
      GF_ALERTING_ENABLED:        "true"
      GF_UNIFIED_ALERTING_ENABLED: "true"

      # Timezone
      GF_DEFAULT_APP_MODE:        production
      TZ:                         America/Sao_Paulo
    ports:
      - "${GRAFANA_PORT}:${GRAFANA_PORT}"
    volumes:
      - grafana-data:/var/lib/grafana
      - ${INSTALL_DIR}/provisioning:/etc/grafana/provisioning:ro
      - ${INSTALL_DIR}/data/dashboards:/var/lib/grafana/dashboards:rw
    networks:
      - grafana-net
$(if [[ -n "$ZABBIX_NETWORK" ]]; then
echo "      - zabbix_zabbix-net"
fi)
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:${GRAFANA_PORT}/api/health | grep -q ok"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
COMPOSE

ok "docker-compose.yml criado"

# ─── 4. Subir Grafana ─────────────────────────────────────────
header "4/4 — Subindo Grafana"

cd "$INSTALL_DIR"

info "Baixando imagem Grafana..."
docker compose pull

info "Iniciando container..."
docker compose up -d

# Aguardar Grafana ficar saudável
info "Aguardando Grafana inicializar (download do plugin Zabbix incluso)..."
for i in {1..36}; do
  STATUS=$(docker inspect grafana --format='{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    ok "Grafana pronto"
    break
  fi
  # Fallback: verifica se responde na porta
  if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" 2>/dev/null | grep -q "ok"; then
    ok "Grafana respondendo"
    break
  fi
  echo "    Aguardando... ($i/36) — baixando plugins"
  sleep 5
  if [[ $i -eq 36 ]]; then
    warn "Grafana demorou mais que o esperado. Verifique: docker logs grafana"
  fi
done

# Verificar se plugin foi instalado
sleep 5
PLUGIN_OK=$(docker exec grafana grafana cli plugins ls 2>/dev/null | grep -c "zabbix" || echo "0")
if [[ "$PLUGIN_OK" -gt "0" ]]; then
  ok "Plugin Zabbix instalado no Grafana"
else
  warn "Plugin ainda sendo instalado — pode levar alguns minutos"
fi

# ─── Resumo ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  GRAFANA INSTALADO"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  STATUS:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
docker ps --filter "name=grafana" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "  ACESSO:"
echo "  URL:      http://$IP_HOST:$GRAFANA_PORT"
echo "  Usuário:  admin"
echo "  Senha:    $GRAFANA_ADMIN_PASS"
echo ""
echo "  INTEGRAÇÃO COM ZABBIX:"
echo "  O datasource Zabbix já foi configurado automaticamente."
echo "  Passos finais no navegador:"
echo ""
echo "  1. Acesse http://$IP_HOST:$GRAFANA_PORT"
echo "  2. Menu → Connections → Data sources"
echo "     Verifique o datasource 'Zabbix' → Save & test"
echo "  3. Menu → Administration → Plugins"
echo "     Busque 'Zabbix' → Enable"
echo "  4. Crie dashboards em Menu → Dashboards → New"
echo "     Selecione o datasource 'Zabbix'"
echo ""
echo "  DATASOURCE ZABBIX CONFIGURADO:"
echo "  API URL:  $ZABBIX_URL"
echo "  Login:    Admin / zabbix"
echo "  (atualize se a senha do Zabbix for diferente)"
echo ""
echo "  COMANDOS ÚTEIS:"
echo "  cd $INSTALL_DIR"
echo "  docker compose ps              # status"
echo "  docker compose logs -f grafana # logs"
echo "  docker compose restart grafana # reiniciar"
echo "═══════════════════════════════════════════════════════"

# Salvar resumo
cat > "$INSTALL_DIR/INSTALACAO.txt" <<INFO
Grafana — Instalado em $(date)
Host: $(hostname -f) ($IP_HOST)

URL:   http://$IP_HOST:$GRAFANA_PORT
Login: admin / $GRAFANA_ADMIN_PASS

Plugin instalado: alexanderzobnin-zabbix-app
Datasource:       Zabbix → $ZABBIX_URL

Diretório: $INSTALL_DIR/
Compose:   $INSTALL_DIR/docker-compose.yml
INFO
chmod 600 "$INSTALL_DIR/INSTALACAO.txt"
