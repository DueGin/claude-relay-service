#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  scripts/generate-self-signed-cert.sh <主域名> [额外SAN(逗号分隔)] [有效期天数]

示例：
  # 仅为单个域名生成（推荐至少包含你实际访问的域名）
  ./scripts/generate-self-signed-cert.sh fluxcode.duegin.online

  # 同时包含根域名与通配符（可选）
  ./scripts/generate-self-signed-cert.sh fluxcode.duegin.online "duegin.online,*.duegin.online" 365

输出：
  nginx/certs/fullchain.pem  # 自签证书（fullchain 命名便于未来切换 Let's Encrypt）
  nginx/certs/privkey.pem    # 私钥（请妥善保管，勿提交到仓库）

说明：
  - 自签证书浏览器会提示不受信任；如用于公网网站，建议改用 Let's Encrypt。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令：$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

main() {
  local domain="${1:-}"
  local extra_sans="${2:-}"
  local days="${3:-365}"

  [[ -n "$domain" ]] || {
    usage
    exit 2
  }

  need_cmd openssl
  need_cmd mktemp

  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    die "有效期天数必须是数字：$days"
  fi

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local cert_dir="${repo_root}/nginx/certs"
  mkdir -p "$cert_dir"

  local key_file="${cert_dir}/privkey.pem"
  local cert_file="${cert_dir}/fullchain.pem"

  local tmp_conf
  tmp_conf="$(mktemp)"
  trap 'rm -f "$tmp_conf"' EXIT

  # 组装 SAN 列表：第一个必须是主域名
  local -a sans=()
  sans+=("$domain")

  if [[ -n "$extra_sans" ]]; then
    local IFS=','
    read -r -a _extra_arr <<<"$extra_sans"
    local item
    for item in "${_extra_arr[@]}"; do
      item="$(trim "$item")"
      [[ -n "$item" ]] || continue
      sans+=("$item")
    done
  fi

  {
    echo "[req]"
    echo "distinguished_name = dn"
    echo "x509_extensions = v3_req"
    echo "prompt = no"
    echo
    echo "[dn]"
    echo "CN = ${domain}"
    echo
    echo "[v3_req]"
    echo "keyUsage = digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectAltName = @alt_names"
    echo
    echo "[alt_names]"

    local i=1
    local san
    for san in "${sans[@]}"; do
      echo "DNS.${i} = ${san}"
      i=$((i + 1))
    done
  } >"$tmp_conf"

  echo "生成自签证书：CN=${domain}（SAN: ${sans[*]}），有效期 ${days} 天"
  echo "输出路径："
  echo "  - ${cert_file}"
  echo "  - ${key_file}"

  openssl req -x509 -nodes -newkey rsa:2048 -sha256 \
    -days "$days" \
    -keyout "$key_file" \
    -out "$cert_file" \
    -config "$tmp_conf" \
    -extensions v3_req

  chmod 600 "$key_file" || true
  chmod 644 "$cert_file" || true

  echo "完成。接下来启用 nginx profile："
  echo "  docker compose --profile nginx up -d --build"
}

main "$@"

