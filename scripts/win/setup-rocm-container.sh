#!/usr/bin/env bash
# kernel-bridge — WSL2 Ubuntu 안에서 ROCm 컨테이너 환경 준비 (GPU 불필요)
#
#   bash scripts/win/setup-rocm-container.sh
#
# Docker Desktop 을 쓰지 않는다. WSL2 안에 docker.io 만 넣는다.
#   - 추가 관리자 권한 설치 불필요 / 라이선스 동의 불필요
#   - GPU 패스스루 불필요 (hipify 와 컴파일만 하므로)
#
# 마지막에 22_verify_toolchain.sh 로 실제 컴파일까지 확인하고,
# 실패하면 0 이 아닌 코드로 끝난다 — "준비 완료"를 거짓으로 찍지 않는다.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_IMAGE="rocm/dev-ubuntu-22.04:6.3"
IMAGE="kernel-bridge/rocm:6.3"

info() { printf '\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !   %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  X   %s\033[0m\n' "$*"; exit 1; }

# --- 1. docker 설치 ---------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    ok "docker 이미 설치됨: $(docker --version)"
else
    info "docker.io 설치"
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io || die "설치 실패"
    ok "설치 완료"
fi

# --- 2. 데몬 기동 + 권한 ----------------------------------------------------
info "docker 데몬 기동"
sudo service docker start >/dev/null 2>&1
sleep 2
sudo docker info >/dev/null 2>&1 || die "데몬 기동 실패"
ok "데몬 정상"

if ! groups | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    warn "docker 그룹에 추가했습니다. 적용하려면 WSL 재시작이 필요합니다:"
    warn "  (Windows PowerShell 에서) wsl --shutdown  후 다시 접속"
fi

# --- 3. 베이스 이미지 -------------------------------------------------------
# ★ 6.2 를 쓰지 않는 이유는 docker/Dockerfile 주석 참조 (링커가 SEGV 로 죽는다).
info "ROCm 베이스 이미지 pull: $BASE_IMAGE (수 GB — 시간이 걸립니다)"
sudo docker pull "$BASE_IMAGE" >/dev/null 2>&1 || die "pull 실패 — 네트워크를 확인하세요"
ok "받음: $BASE_IMAGE"

# --- 4. 파생 이미지 빌드 (perl 등 누락분 보충) ------------------------------
info "작업용 이미지 빌드: $IMAGE"
sudo docker build -t "$IMAGE" "$ROOT/docker/" >/dev/null 2>&1 || die "빌드 실패"
ok "빌드 완료"

# --- 5. 실제 컴파일까지 검증 -------------------------------------------------
info "툴체인 검증 (실제 gfx942 커널 컴파일)"
if bash "$ROOT/scripts/22_verify_toolchain.sh" "$IMAGE"; then
    cat <<EOF

────────────────────────────────────────────────────────────
준비 완료. Phase 2 를 GPU 없이 돌릴 수 있습니다.

  cd "$ROOT"
  bash scripts/00_fetch_sources.sh
  docker run --rm -it -v "\$PWD":/w -w /w $IMAGE \\
      bash -c 'bash scripts/20_hipify.sh && bash scripts/21_build_hip.sh'

사용 이미지: $IMAGE  (베이스 $BASE_IMAGE)
────────────────────────────────────────────────────────────
EOF
else
    die "툴체인 검증 실패 — 위 항목을 해결한 뒤 다시 실행하세요."
fi
