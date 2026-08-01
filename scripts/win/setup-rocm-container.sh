#!/usr/bin/env bash
# kernel-bridge — WSL2 Ubuntu 안에서 ROCm 컨테이너 환경 준비
#
#   wsl -d Ubuntu-22.04 -- bash /mnt/d/.../scripts/win/setup-rocm-container.sh
#
# Docker Desktop 을 쓰지 않습니다. WSL2 안에 docker.io 만 넣습니다.
#   - 추가 관리자 권한 설치 불필요
#   - 라이선스 동의 절차 불필요
#   - GPU 패스스루 불필요 (hipify 와 컴파일만 하므로)
set -uo pipefail

info() { printf '\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !   %s\033[0m\n' "$*"; }

# --- 1. docker 설치 ---------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    ok "docker 이미 설치됨: $(docker --version)"
else
    info "docker.io 설치"
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io || { warn "설치 실패"; exit 1; }
    ok "설치 완료"
fi

# --- 2. 데몬 기동 + 권한 ----------------------------------------------------
info "docker 데몬 기동"
sudo service docker start
sleep 2

if ! groups | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    warn "docker 그룹에 추가했습니다. 적용하려면 WSL 을 재시작해야 합니다:"
    warn "  (Windows 에서) wsl --shutdown  후 다시 접속"
fi

# sudo 로 검증 — 그룹 반영 전에도 확인 가능하도록
sudo docker info >/dev/null 2>&1 && ok "데몬 정상" || { warn "데몬 기동 실패"; exit 1; }

# --- 3. ROCm 개발 이미지 받기 -----------------------------------------------
# 태그는 환경에 따라 다를 수 있어 후보를 순서대로 시도한다.
# 실제로 받아진 태그를 기록해 두는 것이 재현성의 근거가 된다.
info "ROCm 개발 이미지 pull (수 GB — 시간이 걸립니다)"
IMAGE=""
for tag in 6.2 6.2.4 6.1.2 latest; do
    if sudo docker pull "rocm/dev-ubuntu-22.04:$tag" >/dev/null 2>&1; then
        IMAGE="rocm/dev-ubuntu-22.04:$tag"
        ok "받음: $IMAGE"
        break
    fi
    warn "태그 $tag 없음 — 다음 시도"
done
[ -n "$IMAGE" ] || { warn "이미지를 받지 못했습니다. 네트워크/태그를 확인하세요."; exit 1; }

# --- 4. 도구 존재 확인 (GPU 없이 되는지 여기서 판가름) -----------------------
info "컨테이너 안에서 hipify-perl / hipcc 확인"
sudo docker run --rm "$IMAGE" bash -lc '
    export PATH=$PATH:/opt/rocm/bin
    echo "-- ROCm 버전 --"; cat /opt/rocm/.info/version 2>/dev/null || true
    echo "-- hipify-perl --"; command -v hipify-perl || echo "없음"
    echo "-- hipcc --";       command -v hipcc && hipcc --version | head -5 || echo "없음"
'

cat <<EOF

────────────────────────────────────────────────────────────
준비 완료. 이제 Phase 2 를 GPU 없이 돌릴 수 있습니다.

프로젝트 경로에서:

  cd /mnt/d/onedrive/문서/Claude/Projects/kernel-bridge
  docker run --rm -it -v "\$PWD":/w -w /w $IMAGE \\
      bash -lc 'export PATH=\$PATH:/opt/rocm/bin; bash scripts/20_hipify.sh'

받은 이미지: $IMAGE
  → 02-convert/scope.md 에 이 태그를 기록해 두세요 (재현성).
────────────────────────────────────────────────────────────
EOF
