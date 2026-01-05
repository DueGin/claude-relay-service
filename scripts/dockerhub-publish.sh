#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法：
  scripts/dockerhub-publish.sh [选项] [-- <额外docker build参数...>]

示例：
  # 1) 推荐：用 Token 登录并推送（默认 tag 读取 VERSION 文件）
  export DOCKERHUB_USERNAME="你的用户名"
  export DOCKERHUB_TOKEN="你的DockerHub访问令牌"
  ./scripts/dockerhub-publish.sh

  # 2) 指定镜像名与 tag
  ./scripts/dockerhub-publish.sh --image yourname/claude-relay-service --tag 1.1.251

  # 3) 多架构构建并直接推送（需要 buildx）
  ./scripts/dockerhub-publish.sh --platforms linux/amd64,linux/arm64

选项：
  -i, --image        完整镜像名（例如：weishaw/claude-relay-service）
  -u, --username     Docker Hub 用户名/命名空间（用于拼接镜像名）
  -r, --repo         Docker Hub 仓库名（默认：claude-relay-service）
  -t, --tag          版本 tag（默认：读取 VERSION，其次 latest）
      --platforms    走 buildx 多架构（例如：linux/amd64,linux/arm64）
      --[no-]latest  是否同时推送 latest（默认：开启）
      --[no-]alias   是否同时推送 v 前缀/无 v 前缀的别名 tag（默认：开启）
      --no-login     跳过 docker login（默认：不跳过）
      --dry-run      仅打印命令，不执行
  -h, --help         显示帮助

环境变量：
  DOCKERHUB_USERNAME / DOCKERHUB_REPO / DOCKER_IMAGE / TAG / PLATFORMS
  DOCKERHUB_TOKEN（推荐）或 DOCKERHUB_PASSWORD（不推荐）
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

docker_login_password_stdin() {
  local login_user="$1"
  local source_hint="$2"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] docker login -u \"${login_user}\" --password-stdin  # ${source_hint}"
    return 0
  fi

  if [[ "$source_hint" == "from:DOCKERHUB_TOKEN" ]]; then
    printf '%s' "${DOCKERHUB_TOKEN}" | docker login -u "${login_user}" --password-stdin
  else
    printf '%s' "${DOCKERHUB_PASSWORD}" | docker login -u "${login_user}" --password-stdin
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "未找到命令：$1"
}

trim() {
  # 兼容 macOS 自带 bash 3.2：避免 mapfile
  local s="$1"
  # 去掉首尾空白
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_tag_and_digest() {
  local ref="$1"
  ref="${ref%@*}" # 去掉 digest
  local last_part="${ref##*/}"
  if [[ "$last_part" == *:* ]]; then
    printf '%s' "${ref%:*}"
  else
    printf '%s' "$ref"
  fi
}

default_image_from_compose() {
  local compose_file="docker-compose.yml"
  [[ -f "$compose_file" ]] || return 1

  # 优先读取 claude-relay 服务下的 image: 字段；找不到再回退到文件中第一处 image:
  local img=""
  img="$(
    awk '
      /^[[:space:]]*claude-relay:[[:space:]]*$/ { in_service=1; next }
      in_service && $0 ~ /^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/ { in_service=0 }
      in_service && /^[[:space:]]*image:[[:space:]]*/ { print $2; exit }
    ' "$compose_file" 2>/dev/null || true
  )"

  if [[ -z "$img" ]]; then
    img="$(awk '/^[[:space:]]*image:[[:space:]]*/{print $2; exit}' "$compose_file" 2>/dev/null || true)"
  fi

  [[ -n "$img" ]] || return 1
  strip_tag_and_digest "$img"
}

read_default_tag() {
  if [[ -f VERSION ]]; then
    local v
    v="$(trim "$(cat VERSION 2>/dev/null || true)")"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s' "latest"
}

ensure_docker_ready() {
  [[ "${DRY_RUN}" == "true" ]] && return 0
  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker 未启动或不可用（请先启动 Docker Desktop/daemon）"
}

ensure_buildx_ready() {
  [[ "${DRY_RUN}" == "true" ]] && return 0
  docker buildx version >/dev/null 2>&1 || die "需要 docker buildx（请升级 Docker 或启用 buildx）"
  local builder="${BUILDER_NAME}"
  if docker buildx inspect "$builder" >/dev/null 2>&1; then
    run docker buildx use "$builder" >/dev/null
  else
    run docker buildx create --name "$builder" --use >/dev/null
  fi
}

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
CONTEXT="${CONTEXT:-.}"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_REPO="${DOCKERHUB_REPO:-claude-relay-service}"
DOCKER_IMAGE="${DOCKER_IMAGE:-}"
TAG="${TAG:-}"
PLATFORMS="${PLATFORMS:-}"
PUSH_LATEST="${PUSH_LATEST:-true}"
ALIAS_TAGS="${ALIAS_TAGS:-true}"
NO_LOGIN="${NO_LOGIN:-false}"
DRY_RUN="${DRY_RUN:-false}"
BUILDER_NAME="${BUILDER_NAME:-crs-builder}"

EXTRA_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    -u|--username)
      DOCKERHUB_USERNAME="$2"
      shift 2
      ;;
    -r|--repo)
      DOCKERHUB_REPO="$2"
      shift 2
      ;;
    -t|--tag)
      TAG="$2"
      shift 2
      ;;
    --platforms|--platform)
      PLATFORMS="$2"
      shift 2
      ;;
    --latest)
      PUSH_LATEST="true"
      shift
      ;;
    --no-latest)
      PUSH_LATEST="false"
      shift
      ;;
    --alias)
      ALIAS_TAGS="true"
      shift
      ;;
    --no-alias)
      ALIAS_TAGS="false"
      shift
      ;;
    --no-login)
      NO_LOGIN="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_BUILD_ARGS=("$@")
      break
      ;;
    *)
      die "未知参数：$1（使用 --help 查看用法）"
      ;;
  esac
done

TAG="${TAG:-$(read_default_tag)}"
[[ -n "$TAG" ]] || die "TAG 不能为空"

if [[ -z "$DOCKER_IMAGE" ]]; then
  if img="$(default_image_from_compose)"; then
    DOCKER_IMAGE="$img"
  elif [[ -n "$DOCKERHUB_USERNAME" ]]; then
    DOCKER_IMAGE="${DOCKERHUB_USERNAME}/${DOCKERHUB_REPO}"
  else
    die "未指定镜像名：请设置 DOCKER_IMAGE 或传入 --image，或设置 DOCKERHUB_USERNAME"
  fi
fi

# Docker 镜像名要求小写
DOCKER_IMAGE="$(echo "$DOCKER_IMAGE" | tr '[:upper:]' '[:lower:]')"

TAGS=()
add_tag() {
  local t="$1"
  for existing in "${TAGS[@]+"${TAGS[@]}"}"; do
    [[ "$existing" == "$t" ]] && return 0
  done
  TAGS+=("$t")
}

add_tag "${DOCKER_IMAGE}:${TAG}"

if [[ "$PUSH_LATEST" == "true" && "$TAG" != "latest" ]]; then
  add_tag "${DOCKER_IMAGE}:latest"
fi

if [[ "$ALIAS_TAGS" == "true" ]]; then
  if [[ "$TAG" == v* && "${TAG#v}" != "" ]]; then
    add_tag "${DOCKER_IMAGE}:${TAG#v}"
  elif [[ "$TAG" != v* ]]; then
    add_tag "${DOCKER_IMAGE}:v${TAG}"
  fi
fi

ensure_docker_ready

export DOCKER_BUILDKIT=1

if [[ "$NO_LOGIN" != "true" ]]; then
  # 如果用户没显式提供用户名，则从镜像名推导（namespace）
  login_user="${DOCKERHUB_USERNAME:-${DOCKER_IMAGE%%/*}}"
  if [[ -n "${DOCKERHUB_TOKEN:-}" ]]; then
    docker_login_password_stdin "$login_user" "from:DOCKERHUB_TOKEN"
  elif [[ -n "${DOCKERHUB_PASSWORD:-}" ]]; then
    docker_login_password_stdin "$login_user" "from:DOCKERHUB_PASSWORD"
  else
    # 避免 Docker Desktop 默认走 web-based login（设备码登录）
    run docker login -u "$login_user"
  fi
fi

tag_args=()
for t in "${TAGS[@]}"; do
  tag_args+=(-t "$t")
done

echo "镜像：$DOCKER_IMAGE"
echo "Tags：${TAGS[*]}"
if [[ -n "$PLATFORMS" ]]; then
  echo "平台：${PLATFORMS}（buildx）"
else
  echo "平台：本机架构（docker build）"
fi

if [[ -n "$PLATFORMS" ]]; then
  ensure_buildx_ready
  run docker buildx build \
    -f "$DOCKERFILE" \
    --platform "$PLATFORMS" \
    "${tag_args[@]}" \
    "${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}" \
    --push \
    "$CONTEXT"
else
  run docker build \
    -f "$DOCKERFILE" \
    "${tag_args[@]}" \
    "${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}" \
    "$CONTEXT"
  for t in "${TAGS[@]}"; do
    run docker push "$t"
  done
fi

echo "✅ 完成"
