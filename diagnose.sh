#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Diagnóstico profundo (somente leitura)
# Docker + WordPress + Nginx + PHP-FPM em Ubuntu
# Author: Luiz Cruz - 01/04/2026
# =========================================================

PROJECT_DIR="${1:-$(pwd)}"
REPORT_BASE="${PROJECT_DIR}/diag_reports"
TS="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="${REPORT_BASE}/wordpress_docker_diag_deep_${TS}.log"

mkdir -p "$REPORT_BASE"
exec > >(tee -a "$REPORT_FILE") 2>&1

# -----------------------------
# Estado / score
# -----------------------------
SCORE=0
declare -a FINDINGS
declare -a ACTIONS_NOW
declare -a ACTIONS_NEXT
declare -a ACTIONS_LATER

add_finding() {
  local severity="$1"
  local msg="$2"
  FINDINGS+=("[$severity] $msg")

  case "$severity" in
    CRIT) SCORE=$((SCORE + 4)) ;;
    HIGH) SCORE=$((SCORE + 3)) ;;
    MED)  SCORE=$((SCORE + 2)) ;;
    LOW)  SCORE=$((SCORE + 1)) ;;
  esac
}

add_action_now() { ACTIONS_NOW+=("$1"); }
add_action_next() { ACTIONS_NEXT+=("$1"); }
add_action_later() { ACTIONS_LATER+=("$1"); }

section() {
  echo
  echo "=================================================================="
  echo "## $1"
  echo "=================================================================="
}

warn() { echo "[WARN] $*"; }
info() { echo "[INFO] $*"; }

run() {
  echo
  echo "+ $*"
  bash -c "$*" || warn "Falha ao executar: $*"
}

exists() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  exists "$1" || warn "Comando não encontrado: $1"
}

# -----------------------------
# Compose detection
# -----------------------------
find_compose_file() {
  local dir="$1"
  local candidates=(
    "$dir/docker-compose.yml"
    "$dir/docker-compose.yaml"
    "$dir/compose.yml"
    "$dir/compose.yaml"
  )

  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done

  local found
  found="$(find "$dir" -maxdepth 3 \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \) 2>/dev/null | head -n 1 || true)"
  [[ -n "$found" ]] && echo "$found"
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

COMPOSE_BIN="$(compose_cmd)"
COMPOSE_FILE="$(find_compose_file "$PROJECT_DIR" || true)"
COMPOSE_DIR=""

if [[ -n "${COMPOSE_FILE:-}" ]]; then
  COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
fi

compose_run() {
  if [[ -n "${COMPOSE_BIN:-}" && -n "${COMPOSE_FILE:-}" ]]; then
    if [[ "$COMPOSE_BIN" == "docker compose" ]]; then
      docker compose -f "$COMPOSE_FILE" "$@"
    else
      docker-compose -f "$COMPOSE_FILE" "$@"
    fi
  else
    return 1
  fi
}

# -----------------------------
# Container detection fallback
# -----------------------------
detect_container_by_name() {
  local pattern="$1"
  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' | awk -v p="$pattern" '
    BEGIN{IGNORECASE=1}
    $0 ~ p { print $1; exit }
  '
}

detect_container_name() {
  local cid="$1"
  [[ -n "$cid" ]] && docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's#^/##' || true
}

# Prefer compose service resolution; fallback to docker ps patterns
NGINX_CID=""
WP_CID=""
NGINX_NAME=""
WP_NAME=""

if compose_run ps >/dev/null 2>&1; then
  NGINX_CID="$(compose_run ps -q nginx 2>/dev/null || true)"
  WP_CID="$(compose_run ps -q wordpress 2>/dev/null || true)"
fi

[[ -z "$NGINX_CID" ]] && NGINX_CID="$(detect_container_by_name 'nginx')"
[[ -z "$WP_CID" ]] && WP_CID="$(detect_container_by_name 'wordpress|php-fpm|wp-.*wordpress')"

NGINX_NAME="$(detect_container_name "$NGINX_CID")"
WP_NAME="$(detect_container_name "$WP_CID")"

# -----------------------------
# Helpers
# -----------------------------
docker_exec_sh() {
  local cid="$1"
  shift
  docker exec "$cid" sh -lc "$*" 2>/dev/null
}

inspect_value() {
  local cid="$1"
  local fmt="$2"
  docker inspect "$cid" --format "$fmt" 2>/dev/null || true
}

extract_first_number() {
  echo "$1" | grep -Eo '[0-9]+' | head -n 1 || true
}

safe_head() {
  head -n "${2:-200}" "$1" 2>/dev/null || true
}

# -----------------------------
# Start report
# -----------------------------
section "METADADOS"
echo "Data/Hora: $(date)"
echo "Projeto informado: $PROJECT_DIR"
echo "Compose file detectado: ${COMPOSE_FILE:-não encontrado}"
echo "Compose dir: ${COMPOSE_DIR:-n/a}"
echo "Relatório: $REPORT_FILE"
echo "Host: $(hostname)"
echo "Kernel: $(uname -a)"
echo "Uptime: $(uptime -p || true)"

section "PRÉ-CHECAGENS"
need_cmd docker
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd ss
need_cmd free
need_cmd vmstat
need_cmd top
need_cmd df
need_cmd iostat
need_cmd mpstat

run "docker version"
[[ -n "${COMPOSE_BIN:-}" ]] && run "$COMPOSE_BIN version"

section "DESCOBERTA DO AMBIENTE"
echo "Container Nginx ID: ${NGINX_CID:-não encontrado}"
echo "Container Nginx Name: ${NGINX_NAME:-não encontrado}"
echo "Container WordPress ID: ${WP_CID:-não encontrado}"
echo "Container WordPress Name: ${WP_NAME:-não encontrado}"

if [[ -z "$NGINX_CID" ]]; then
  add_finding HIGH "Container Nginx não foi localizado automaticamente."
  add_action_now "Validar nome real do container Nginx ou caminho correto do compose."
fi

if [[ -z "$WP_CID" ]]; then
  add_finding HIGH "Container WordPress/PHP-FPM não foi localizado automaticamente."
  add_action_now "Validar nome real do container WordPress/PHP-FPM ou caminho correto do compose."
fi

section "HOST - CPU / MEMÓRIA / LOAD"
run "uptime"
run "cat /proc/loadavg"
run "nproc"
run "free -h"
run "vmstat 1 5"
run "mpstat -P ALL 1 3 2>/dev/null || true"
run "top -b -n1 | head -n 40"

LOAD1="$(awk '{print $1}' /proc/loadavg)"
CPU_CORES="$(nproc || echo 1)"
MEM_AVAIL_MB="$(free -m | awk '/Mem:/ {print $7}')"
SWAP_FREE_MB="$(free -m | awk '/Swap:/ {print $4}')"

awk -v l="$LOAD1" -v c="$CPU_CORES" 'BEGIN {
  if (l > c*1.5) exit 10;
  else if (l > c) exit 11;
  else exit 0;
}'
RC=$?
if [[ $RC -eq 10 ]]; then
  add_finding HIGH "Load average muito acima da capacidade de CPU do host."
elif [[ $RC -eq 11 ]]; then
  add_finding MED "Load average acima da quantidade de CPUs do host."
fi

if [[ "${MEM_AVAIL_MB:-0}" -lt 300 ]]; then
  add_finding HIGH "Pouca memória disponível no host."
fi

if [[ "${SWAP_FREE_MB:-0}" -lt 128 ]]; then
  add_finding MED "Swap muito baixa; pode indicar pressão de memória."
fi

section "HOST - DISCO / INODES / IO"
run "df -h"
run "df -i"
run "lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,ROTA,TYPE"
run "iostat -xz 1 3 2>/dev/null || true"

DISK_USE_PCT="$(df / | awk 'NR==2 {gsub(/%/,\"\",$5); print $5}')"
INODE_USE_PCT="$(df -i / | awk 'NR==2 {gsub(/%/,\"\",$5); print $5}')"

if [[ "${DISK_USE_PCT:-0}" -ge 90 ]]; then
  add_finding HIGH "Disco raiz acima de 90%."
elif [[ "${DISK_USE_PCT:-0}" -ge 80 ]]; then
  add_finding MED "Disco raiz acima de 80%."
fi

if [[ "${INODE_USE_PCT:-0}" -ge 90 ]]; then
  add_finding HIGH "Uso de inodes acima de 90%."
elif [[ "${INODE_USE_PCT:-0}" -ge 80 ]]; then
  add_finding MED "Uso de inodes acima de 80%."
fi

section "KERNEL / OOM / PRESSÃO"
run "dmesg -T | egrep -i 'killed process|out of memory|oom' | tail -n 50"
OOM_LINES="$(dmesg -T 2>/dev/null | egrep -i 'killed process|out of memory|oom' | tail -n 10 || true)"
if [[ -n "${OOM_LINES:-}" ]]; then
  add_finding HIGH "Há sinais de OOM no kernel."
  add_action_now "Investigar processos mortos por falta de memória e revisar limites do WordPress/PHP-FPM."
fi

section "DOCKER - ESTADO GERAL"
run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
run "docker stats --no-stream"
run "docker system df"
run "docker info"

# -----------------------------
# Docker deep inspection
# -----------------------------
inspect_container_deep() {
  local cid="$1"
  local label="$2"

  [[ -z "$cid" ]] && return 0

  section "CONTAINER - $label"

  run "docker inspect $cid --format 'Name={{.Name}} Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}} StartedAt={{.State.StartedAt}} FinishedAt={{.State.FinishedAt}}'"
  run "docker inspect $cid --format 'Image={{.Config.Image}} User={{.Config.User}} Entrypoint={{json .Config.Entrypoint}} Cmd={{json .Config.Cmd}}'"
  run "docker inspect $cid --format 'Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}} CpuShares={{.HostConfig.CpuShares}} PidsLimit={{.HostConfig.PidsLimit}} RestartPolicy={{json .HostConfig.RestartPolicy}}'"
  run "docker inspect $cid --format 'ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} LogConfig={{json .HostConfig.LogConfig}}'"
  run "docker inspect $cid --format 'Health={{json .State.Health}}'"
  run "docker inspect $cid --format '{{json .Mounts}}'"
  run "docker inspect $cid --format '{{json .NetworkSettings.Networks}}'"
  run "docker logs --tail 200 $cid 2>&1 | tail -n 200"

  local restart_count oom_killed health_status mem_limit pids_limit
  restart_count="$(inspect_value "$cid" '{{.RestartCount}}')"
  oom_killed="$(inspect_value "$cid" '{{.State.OOMKilled}}')"
  health_status="$(inspect_value "$cid" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  mem_limit="$(inspect_value "$cid" '{{.HostConfig.Memory}}')"
  pids_limit="$(inspect_value "$cid" '{{.HostConfig.PidsLimit}}')"

  if [[ "${restart_count:-0}" -gt 0 ]]; then
    add_finding MED "$label reiniciou ${restart_count} vez(es)."
    add_action_now "Verificar motivo dos reinícios de $label nos logs."
  fi

  if [[ "$oom_killed" == "true" ]]; then
    add_finding HIGH "$label sofreu OOMKilled."
    add_action_now "Revisar consumo de memória e limites do container $label."
  fi

  if [[ "$health_status" == "unhealthy" ]]; then
    add_finding HIGH "$label está unhealthy."
    add_action_now "Verificar healthcheck e logs do container $label."
  fi

  if [[ "$mem_limit" == "0" || -z "$mem_limit" ]]; then
    add_finding LOW "$label está sem limite explícito de memória."
  fi

  if [[ "$pids_limit" == "0" || "$pids_limit" == "-1" || -z "$pids_limit" ]]; then
    add_finding LOW "$label está sem limite explícito de PIDs."
  fi
}

inspect_container_deep "$NGINX_CID" "NGINX"
inspect_container_deep "$WP_CID" "WORDPRESS"

section "DOCKER - PROCESSOS E RECURSOS"
run "docker ps --no-trunc"
run "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'"

# -----------------------------
# Nginx analysis
# -----------------------------
if [[ -n "$NGINX_CID" ]]; then
  section "NGINX - CONFIG / PROCESSOS / LOGS"
  run "docker exec $NGINX_CID sh -lc 'ps aux || ps'"
  run "docker exec $NGINX_CID sh -lc 'nginx -T 2>/dev/null | sed -n \"1,260p\"'"
  run "docker exec $NGINX_CID sh -lc 'cat /etc/nginx/conf.d/default.conf 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'ls -lah /var/log/nginx 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'tail -n 200 /var/log/nginx/error.log 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'tail -n 200 /var/log/nginx/access.log 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'ss -s || true'"
  run "docker exec $NGINX_CID sh -lc 'ss -tan 2>/dev/null | head -n 120 || true'"

  NGINX_ERR="$(docker_exec_sh "$NGINX_CID" "tail -n 300 /var/log/nginx/error.log 2>/dev/null || true" || true)"
  if echo "$NGINX_ERR" | grep -Eiq 'upstream timed out|connect\(\) failed|no live upstreams|recv\(\) failed|prematurely closed connection'; then
    add_finding HIGH "Nginx mostra sinais de timeout ou falha com upstream PHP-FPM."
    add_action_now "Revisar PHP-FPM, tempo de resposta do app e timeouts entre Nginx e PHP."
  fi

  if echo "$NGINX_ERR" | grep -Eiq '502|504|bad gateway|gateway timeout'; then
    add_finding HIGH "Há indícios de 502/504 no fluxo do Nginx."
    add_action_now "Investigar saturação do PHP-FPM, lentidão do WordPress ou falha no socket/porta 9000."
  fi

  ACCESS_SAMPLE="$(docker_exec_sh "$NGINX_CID" "tail -n 300 /var/log/nginx/access.log 2>/dev/null || true" || true)"
  if echo "$ACCESS_SAMPLE" | grep -E ' 499 | 500 | 502 | 503 | 504 ' >/dev/null 2>&1; then
    add_finding MED "Access log do Nginx contém erros HTTP recentes."
    add_action_next "Quantificar códigos 499/5xx por janela de tempo."
  fi
fi

# -----------------------------
# WordPress / PHP-FPM analysis
# -----------------------------
if [[ -n "$WP_CID" ]]; then
  section "WORDPRESS / PHP-FPM - PROCESSOS / CONFIG / LOGS"
  run "docker exec $WP_CID sh -lc 'ps aux || ps'"
  run "docker exec $WP_CID sh -lc 'php -v'"
  run "docker exec $WP_CID sh -lc 'php -m | sort'"
  run "docker exec $WP_CID sh -lc 'php -i | egrep -i \"memory_limit|max_execution_time|max_input_vars|post_max_size|upload_max_filesize|opcache.enable|opcache.memory_consumption|opcache.max_accelerated_files|realpath_cache_size|realpath_cache_ttl|display_errors|log_errors|error_log\"'"
  run "docker exec $WP_CID sh -lc 'grep -R \"^[^;].*pm\\.\\|^[^;].*request_\\|^[^;].*listen\\|^[^;].*slowlog\\|^[^;].*catch_workers_output\" /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.conf 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'ls -lah /usr/local/etc/php/conf.d /usr/local/etc/php-fpm.d 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html -maxdepth 2 -type f | wc -l'"
  run "docker exec $WP_CID sh -lc 'du -sh /var/www/html 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html/wp-content -maxdepth 2 -type d 2>/dev/null | head -n 200 || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html/wp-content/plugins -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed \"s|/var/www/html/wp-content/plugins/||\" | sort || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html/wp-content/themes -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed \"s|/var/www/html/wp-content/themes/||\" | sort || true'"
  run "docker exec $WP_CID sh -lc 'grep -E \"WP_DEBUG|WP_CACHE|DISABLE_WP_CRON|AUTOSAVE_INTERVAL|WP_POST_REVISIONS|EMPTY_TRASH_DAYS\" /var/www/html/wp-config.php 2>/dev/null || true'"

  PHP_INFO="$(docker_exec_sh "$WP_CID" "php -i 2>/dev/null | egrep -i 'memory_limit|max_execution_time|opcache.enable|opcache.memory_consumption|opcache.max_accelerated_files|realpath_cache_size|realpath_cache_ttl'" || true)"
  FPM_CFG="$(docker_exec_sh "$WP_CID" "grep -R '^[^;].*pm\\.|^[^;].*request_|^[^;].*listen|^[^;].*slowlog|^[^;].*catch_workers_output' /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.conf 2>/dev/null" || true)"
  WP_CFG="$(docker_exec_sh "$WP_CID" "grep -E 'WP_DEBUG|WP_CACHE|DISABLE_WP_CRON' /var/www/html/wp-config.php 2>/dev/null || true" || true)"
  PHP_PS="$(docker_exec_sh "$WP_CID" "ps aux 2>/dev/null | grep -E 'php-fpm|php' | grep -v grep || ps | grep php || true" || true)"

  if ! echo "$PHP_INFO" | grep -iq 'opcache.enable => On\|opcache.enable => 1'; then
    add_finding HIGH "OPcache parece desativado no PHP."
    add_action_now "Ativar OPcache no php.ini."
  fi

  OPCACHE_MEM="$(echo "$PHP_INFO" | awk -F'=> ' '/opcache.memory_consumption/ {gsub(/ /,"",$2); print $2; exit}' | awk '{print $1}' || true)"
  if [[ -n "${OPCACHE_MEM:-}" ]]; then
    if [[ "$OPCACHE_MEM" =~ ^[0-9]+$ ]] && [[ "$OPCACHE_MEM" -lt 128 ]]; then
      add_finding MED "OPcache com memória possivelmente baixa (${OPCACHE_MEM}MB)."
      add_action_next "Avaliar aumentar opcache.memory_consumption para 128MB ou 256MB."
    fi
  fi

  if ! echo "$FPM_CFG" | grep -q 'pm.max_children'; then
    add_finding HIGH "pm.max_children não foi identificado no PHP-FPM."
    add_action_now "Revisar pool do PHP-FPM e definir pm.max_children."
  fi

  if ! echo "$FPM_CFG" | grep -q 'slowlog'; then
    add_finding MED "slowlog do PHP-FPM não foi identificado."
    add_action_next "Ativar slowlog para capturar requests lentas."
  fi

  if ! echo "$FPM_CFG" | grep -q 'request_slowlog_timeout'; then
    add_finding MED "request_slowlog_timeout não foi identificado."
    add_action_next "Definir request_slowlog_timeout no PHP-FPM."
  fi

  if ! echo "$FPM_CFG" | grep -q 'pm.max_requests'; then
    add_finding LOW "pm.max_requests não foi identificado."
    add_action_later "Definir pm.max_requests para reciclagem de workers."
  fi

  PHP_FPM_COUNT="$(echo "$PHP_PS" | grep -ci 'php-fpm' || true)"
  if [[ "${PHP_FPM_COUNT:-0}" -le 2 ]]; then
    add_finding MED "Poucos processos php-fpm visíveis (${PHP_FPM_COUNT})."
    add_action_next "Verificar se o pool do PHP-FPM está subdimensionado."
  fi

  if ! echo "$WP_CFG" | grep -q 'WP_CACHE'; then
    add_finding MED "WP_CACHE não foi encontrado no wp-config.php."
    add_action_next "Validar se há cache de página efetivamente ativo."
  fi

  if ! echo "$WP_CFG" | grep -q 'DISABLE_WP_CRON'; then
    add_finding MED "DISABLE_WP_CRON não foi encontrado."
    add_action_next "Avaliar desativar wp-cron em request e usar cron do sistema."
  fi

  MEM_LIMIT="$(echo "$PHP_INFO" | awk -F'=> ' '/memory_limit/ {print $2; exit}' | xargs || true)"
  if [[ -n "${MEM_LIMIT:-}" ]]; then
    echo "memory_limit detectado: $MEM_LIMIT"
  fi
fi

# -----------------------------
# Mounts / overlay / docker storage
# -----------------------------
section "DOCKER STORAGE / MOUNTS"
run "docker system df -v 2>/dev/null || docker system df"

if [[ -n "$WP_CID" ]]; then
  MOUNTS_JSON="$(inspect_value "$WP_CID" '{{json .Mounts}}')"
  echo "Mounts WordPress: ${MOUNTS_JSON:-n/a}"
  if echo "$MOUNTS_JSON" | grep -q '"/var/www/html"'; then
    add_finding LOW "WordPress usa mount para /var/www/html; isso merece atenção em produção se houver muitos arquivos pequenos."
    add_action_later "Avaliar impacto de I/O e estratégia de deploy/storage para /var/www/html."
  fi
fi

# -----------------------------
# Network / sockets
# -----------------------------
section "REDE / SOCKETS"
run "ss -lntp"
run "ss -s"
run "docker network ls"
run "docker inspect $NGINX_CID --format '{{json .NetworkSettings.Networks}}' 2>/dev/null || true"
run "docker inspect $WP_CID --format '{{json .NetworkSettings.Networks}}' 2>/dev/null || true"

# -----------------------------
# Compose data, if available
# -----------------------------
if [[ -n "${COMPOSE_FILE:-}" ]]; then
  section "COMPOSE DETECTADO"
  run "sed -n '1,260p' '$COMPOSE_FILE'"
fi

# -----------------------------
# Final verdict
# -----------------------------
section "ACHADOS CONSOLIDADOS"

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
  echo "[OK] Nenhum achado relevante foi identificado nesta coleta."
else
  for f in "${FINDINGS[@]}"; do
    echo "$f"
  done
fi

section "VEREDITO FINAL"

echo "Score total: $SCORE"

if [[ $SCORE -ge 12 ]]; then
  VEREDICT="INDÍCIOS FORTES DE FALHAS A OBSERVAR"
elif [[ $SCORE -ge 7 ]]; then
  VEREDICT="INDÍCIOS RELEVANTES DE GARGALO"
elif [[ $SCORE -ge 3 ]]; then
  VEREDICT="ATENÇÃO"
else
  VEREDICT="SEM INDÍCIOS FORTES"
fi

echo "Veredito: $VEREDICT"

echo
case "$VEREDICT" in
  "INDÍCIOS FORTES DE FALHAS A OBSERVAR")
    echo "Resumo: há sinais consistentes de configuração incompleta, erros no fluxo Nginx -> PHP-FPM, pressão operacional ou ausência de otimizações essenciais."
    ;;
  "INDÍCIOS RELEVANTES DE GARGALO")
    echo "Resumo: o ambiente tem sinais importantes que merecem ação, ainda que o host possa aparentar folga."
    ;;
  "ATENÇÃO")
    echo "Resumo: não há evidência clara de colapso, mas existem pontos de configuração e observabilidade que precisam ser melhorados."
    ;;
  *)
    echo "Resumo: nesta coleta não apareceram sinais fortes de gargalo do host ou falha operacional clara."
    ;;
esac

section "AÇÕES RECOMENDADAS - FAZER AGORA"
if [[ ${#ACTIONS_NOW[@]} -eq 0 ]]; then
  echo "- Nenhuma ação crítica imediata inferida automaticamente."
else
  printf -- "- %s\n" "${ACTIONS_NOW[@]}"
fi

section "AÇÕES RECOMENDADAS - PRÓXIMO PASSO"
if [[ ${#ACTIONS_NEXT[@]} -eq 0 ]]; then
  echo "- Nenhuma ação de segundo nível inferida automaticamente."
else
  printf -- "- %s\n" "${ACTIONS_NEXT[@]}"
fi

section "AÇÕES RECOMENDADAS - DEPOIS"
if [[ ${#ACTIONS_LATER[@]} -eq 0 ]]; then
  echo "- Nenhuma ação posterior inferida automaticamente."
else
  printf -- "- %s\n" "${ACTIONS_LATER[@]}"
fi

section "FIM"
echo "Relatório salvo em: $REPORT_FILE"