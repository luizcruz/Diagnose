#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Diagnóstico de gargalos - Docker WordPress + Nginx + PHP-FPM
# Ambiente alvo:
# - Ubuntu host
# - docker compose com serviços "nginx" e "wordpress"
# - WordPress em PHP-FPM
# - Author: Luiz Cruz - 01/04/2026
# =========================================================

PROJECT_DIR="${1:-$(pwd)}"
REPORT_DIR="${PROJECT_DIR}/diag_reports"
TS="$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="${REPORT_DIR}/wordpress_docker_diag_${TS}.log"

NGINX_SERVICE_NAME="${NGINX_SERVICE_NAME:-nginx}"
WP_SERVICE_NAME="${WP_SERVICE_NAME:-wordpress}"

mkdir -p "$REPORT_DIR"

exec > >(tee -a "$REPORT_FILE") 2>&1

section() {
  echo
  echo "=================================================================="
  echo "## $1"
  echo "=================================================================="
}

warn() {
  echo "[WARN] $*"
}

info() {
  echo "[INFO] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "Comando não encontrado: $1"
    return 1
  }
}

run() {
  echo
  echo "+ $*"
  bash -c "$*" || warn "Falha ao executar: $*"
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

COMPOSE="$(compose_cmd)"

if [[ -z "$COMPOSE" ]]; then
  echo "Docker Compose não encontrado. Instale docker compose plugin ou docker-compose."
  exit 1
fi

cd "$PROJECT_DIR"

section "METADADOS DO DIAGNÓSTICO"
echo "Data/Hora: $(date)"
echo "Projeto: $PROJECT_DIR"
echo "Relatório: $REPORT_FILE"
echo "Usuário: $(whoami)"
echo "Kernel: $(uname -a)"
echo "Uptime: $(uptime -p || true)"

section "PRÉ-CHECAGENS"
need_cmd docker || exit 1
need_cmd awk || true
need_cmd grep || true
need_cmd sed || true
need_cmd ss || true
need_cmd df || true
need_cmd free || true
need_cmd vmstat || true
need_cmd iostat || true
need_cmd mpstat || true
need_cmd top || true
need_cmd curl || true
need_cmd find || true

run "docker version"
run "$COMPOSE version"
run "$COMPOSE ps"

NGINX_CID="$($COMPOSE ps -q "$NGINX_SERVICE_NAME" 2>/dev/null || true)"
WP_CID="$($COMPOSE ps -q "$WP_SERVICE_NAME" 2>/dev/null || true)"

if [[ -z "$NGINX_CID" ]]; then
  warn "Container do serviço '$NGINX_SERVICE_NAME' não encontrado."
fi

if [[ -z "$WP_CID" ]]; then
  warn "Container do serviço '$WP_SERVICE_NAME' não encontrado."
fi

section "HOST - CPU / LOAD / MEMÓRIA / SWAP"
run "uptime"
run "cat /proc/loadavg"
run "nproc"
run "lscpu 2>/dev/null | sed -n '1,25p'"
run "free -h"
run "vmstat 1 5"
run "mpstat -P ALL 1 3 2>/dev/null || true"
run "top -b -n1 | head -n 40"

section "HOST - DISCO / INODES / IO"
run "df -h"
run "df -i"
run "mount | column -t 2>/dev/null || mount"
run "lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,ROTA,TYPE"
run "iostat -xz 1 3 2>/dev/null || true"

section "HOST - PRESSÃO DE MEMÓRIA / OOM / KERNEL"
run "dmesg -T | egrep -i 'killed process|out of memory|oom' | tail -n 50"
run "journalctl -k -n 100 --no-pager 2>/dev/null || true"

section "DOCKER - ESTADO GERAL"
run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
run "docker stats --no-stream"
run "docker system df"
run "docker info"

section "DOCKER - EVENTOS RECENTES"
run "docker events --since 30m --until 0s 2>/dev/null | tail -n 100 || true"

inspect_container() {
  local cid="$1"
  local label="$2"

  if [[ -z "$cid" ]]; then
    warn "Sem container para inspecionar: $label"
    return 0
  fi

  section "CONTAINER - $label"
  run "docker inspect $cid --format 'Name={{.Name}} Status={{.State.Status}} Running={{.State.Running}} RestartCount={{.RestartCount}} OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} StartedAt={{.State.StartedAt}} FinishedAt={{.State.FinishedAt}}'"
  run "docker inspect $cid --format 'Memory={{.HostConfig.Memory}} NanoCPUs={{.HostConfig.NanoCpus}} CpuShares={{.HostConfig.CpuShares}} PidsLimit={{.HostConfig.PidsLimit}}'"
  run "docker inspect $cid --format '{{json .Mounts}}'"
  run "docker inspect $cid --format '{{json .NetworkSettings.Ports}}'"
  run "docker logs --tail 200 $cid 2>&1 | tail -n 200"
}

inspect_container "$NGINX_CID" "NGINX"
inspect_container "$WP_CID" "WORDPRESS"

section "PROCESSOS DENTRO DOS CONTAINERS"

if [[ -n "$NGINX_CID" ]]; then
  run "docker exec $NGINX_CID sh -lc 'ps aux || ps'"
  run "docker exec $NGINX_CID sh -lc 'nginx -T 2>/dev/null | sed -n \"1,220p\"'"
  run "docker exec $NGINX_CID sh -lc 'cat /etc/nginx/conf.d/default.conf 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'ls -lah /var/log/nginx || true'"
  run "docker exec $NGINX_CID sh -lc 'tail -n 100 /var/log/nginx/error.log 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'tail -n 100 /var/log/nginx/access.log 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'ss -s || netstat -s 2>/dev/null || true'"
  run "docker exec $NGINX_CID sh -lc 'ss -tanp 2>/dev/null | head -n 100 || true'"
fi

if [[ -n "$WP_CID" ]]; then
  run "docker exec $WP_CID sh -lc 'ps aux || ps'"
  run "docker exec $WP_CID sh -lc 'php -v'"
  run "docker exec $WP_CID sh -lc 'php -m | sort'"
  run "docker exec $WP_CID sh -lc 'php -i | egrep -i \"memory_limit|max_execution_time|max_input_vars|post_max_size|upload_max_filesize|opcache.enable|opcache.memory_consumption|realpath_cache_size|realpath_cache_ttl\"'"
  run "docker exec $WP_CID sh -lc 'php-fpm -tt 2>/dev/null || php-fpm82 -tt 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'grep -R \"^[^;].*pm\\.\\|^[^;].*request_\\|^[^;].*listen\\|^[^;].*slowlog\\|^[^;].*catch_workers_output\" /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.conf 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'ls -lah /usr/local/etc/php/conf.d /usr/local/etc/php-fpm.d 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html -maxdepth 2 -type f | wc -l'"
  run "docker exec $WP_CID sh -lc 'du -sh /var/www/html 2>/dev/null || true'"
  run "docker exec $WP_CID sh -lc 'find /var/www/html/wp-content -type f 2>/dev/null | wc -l || true'"
fi