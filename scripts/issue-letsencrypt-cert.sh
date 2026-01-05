#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  scripts/issue-letsencrypt-cert.sh <主域名> <邮箱> [额外域名...]

示例：
  ./scripts/issue-letsencrypt-cert.sh fluxcode.duegin.online admin@duegin.online
  ./scripts/issue-letsencrypt-cert.sh fluxcode.duegin.online admin@duegin.online duegin.online

环境变量（可选）：
  LETSENCRYPT_DOMAIN   主域名（等同第1参数）
  LETSENCRYPT_EMAIL    邮箱（等同第2参数）
  LETSENCRYPT_STAGING  true/false，使用测试环境避免触发速率限制

前置条件：
  - DNS 记录已生效：域名指向当前服务器 IP
  - 服务器防火墙/安全组已放行 80 和 443

说明：
  - 这会通过 Let’s Encrypt 签发受信任证书，浏览器访问将不再出现证书警告
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
  local email="${2:-${LETSENCRYPT_EMAIL:-}}"
  shift $(( $# > 0 ? 1 : 0 )) || true
  shift $(( $# > 0 ? 1 : 0 )) || true
  local -a extra_domains=( "$@" )

  [[ -n "$domain" && -n "$email" ]] || { usage; exit 2; }

  need_cmd docker

  # 确认 Docker daemon 可用
  docker info >/dev/null 2>&1 || die "Docker 未运行或不可用，请先启动 Docker"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$repo_root"

  mkdir -p certbot/www certbot/logs nginx/certs

  # Nginx 启动需要证书文件：若还没有，先生成一个临时自签（仅用于引导签发 Let’s Encrypt）
  if [[ ! -s nginx/certs/fullchain.pem || ! -s nginx/certs/privkey.pem ]]; then
    if [[ -x ./scripts/generate-self-signed-cert.sh ]]; then
      echo "未检测到 TLS 证书，先生成临时自签证书以启动 Nginx（签发成功后会自动替换为 Let’s Encrypt）"
      ./scripts/generate-self-signed-cert.sh "$domain" "" 1 >/dev/null
    else
      die "缺少临时证书且 ./scripts/generate-self-signed-cert.sh 不可执行"
    fi
  fi

  echo "启动 Nginx（仅用于 ACME 校验）..."
  if ! docker compose --profile nginx up -d --no-deps nginx; then
    echo "提示：当前 docker compose 可能不支持 --no-deps，改为正常启动 nginx"
    docker compose --profile nginx up -d nginx
  fi

  local -a certbot_domains=( -d "$domain" )
  local d
  for d in "${extra_domains[@]}"; do
    [[ -n "$d" ]] || continue
    certbot_domains+=( -d "$d" )
  done

  local -a certbot_args=(
    certonly
    --webroot
    -w /var/www/certbot
    "${certbot_domains[@]}"
    --email "$email"
    --agree-tos
    --no-eff-email
    --non-interactive
    --keep-until-expiring
  )

  if [[ "${LETSENCRYPT_STAGING:-false}" == "true" ]]; then
    certbot_args+=( --staging )
  fi

  echo "开始签发证书（Let’s Encrypt）..."
  docker compose --profile nginx run --rm certbot "${certbot_args[@]}"

  local live_dir="nginx/certs/live/${domain}"
  [[ -f "${live_dir}/fullchain.pem" && -f "${live_dir}/privkey.pem" ]] || die "未找到签发结果：${live_dir}"

  # 将证书复制到固定文件名，供 nginx/conf.d/claude-relay.conf 使用
  cp -f "${live_dir}/fullchain.pem" "nginx/certs/fullchain.pem"
  cp -f "${live_dir}/privkey.pem" "nginx/certs/privkey.pem"
  chmod 600 "nginx/certs/privkey.pem" || true

  echo "重新加载 Nginx..."
  docker compose --profile nginx exec nginx nginx -s reload

  echo "完成：请用域名访问（不要用 IP），例如：https://${domain}"
}

main "$@"

