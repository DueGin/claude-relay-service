#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  scripts/renew-letsencrypt-cert.sh <主域名>

示例：
  ./scripts/renew-letsencrypt-cert.sh fluxcode.duegin.online

说明：
  - 续期会更新 /etc/letsencrypt 下的证书；脚本会同步到 nginx/certs/{fullchain,privkey}.pem 并 reload nginx
  - 建议配合 crontab 每天跑一次（Let’s Encrypt 证书 90 天有效）
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令：$1"
}

main() {
  local domain="${1:-${LETSENCRYPT_DOMAIN:-}}"
  [[ -n "$domain" ]] || { usage; exit 2; }

  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker 未运行或不可用，请先启动 Docker"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$repo_root"

  echo "尝试续期证书（Let’s Encrypt）..."
  docker compose --profile nginx run --rm certbot renew --non-interactive

  local live_dir="nginx/certs/live/${domain}"
  [[ -f "${live_dir}/fullchain.pem" && -f "${live_dir}/privkey.pem" ]] || die "未找到证书：${live_dir}"

  cp -f "${live_dir}/fullchain.pem" "nginx/certs/fullchain.pem"
  cp -f "${live_dir}/privkey.pem" "nginx/certs/privkey.pem"
  chmod 600 "nginx/certs/privkey.pem" || true

  echo "重新加载 Nginx..."
  docker compose --profile nginx exec nginx nginx -s reload

  echo "完成。"
}

main "$@"

