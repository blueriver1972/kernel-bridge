#!/usr/bin/env bash
# Phase 2 사전 점검 — 컨테이너 안에 필요한 도구가 실제로 있는지 확인 (GPU 불필요)
#
#   bash scripts/22_verify_toolchain.sh [이미지태그]
#
# 20_hipify.sh / 21_build_hip.sh 를 돌리기 전에 이걸 먼저 통과시킨다.
# 실패하면 0 이 아닌 코드로 끝난다 — 조용히 "준비 완료"를 찍지 않는다.
set -uo pipefail

IMAGE="${1:-kernel-bridge/rocm:6.3}"
FAIL=0

ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  X   %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '\033[36m=== %s ===\033[0m\n' "$*"; }

DOCKER=docker
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

info "docker 데몬"
if $DOCKER info >/dev/null 2>&1; then ok "응답함 ($DOCKER)"; else
    bad "데몬 무응답 — 'sudo service docker start' 후 다시 시도"
    exit 1
fi

info "이미지 $IMAGE"
$DOCKER image inspect "$IMAGE" >/dev/null 2>&1 \
    && ok "로컬에 있음" || bad "없음 — 'docker pull $IMAGE' 필요"

# ---- 컨테이너를 실제로 띄워 도구 존재를 확인한다 --------------------------
# 이전 실패(read-only file system)가 바로 이 지점이었다. 결과를 반드시 판정한다.
info "컨테이너 실행 + 도구 확인"
OUT="$($DOCKER run --rm "$IMAGE" bash -lc '
    export PATH=/opt/rocm/bin:$PATH   # 앞에 붙인다 — /usr/bin/hipcc 가 가려지면 안 된다
    echo "ROCM_VERSION=$(cat /opt/rocm/.info/version 2>/dev/null || echo unknown)"
    echo "HIPIFY=$(command -v hipify-perl || echo MISSING)"
    echo "HIPCC=$(command -v hipcc || echo MISSING)"
    echo "PERL=$(command -v perl || echo MISSING)"

    # 진짜 커널 소스로 컴파일한다. /dev/null 을 소스로 주면 링커가 segfault 한다.
    T=$(mktemp -d)
    printf "#include <hip/hip_runtime.h>\n__global__ void k(float* o){ o[threadIdx.x] = 1.0f; }\n" > "$T/t.hip"
    if hipcc --offload-arch=gfx942 -O3 -c "$T/t.hip" -o "$T/t.o" 2>"$T/err"; then
        echo "GFX=gfx942_OK ($(stat -c%s "$T/t.o") bytes)"
    else
        echo "GFX=gfx942_FAIL"
        sed "s/^/    hipcc: /" "$T/err" | head -8
    fi
    rm -rf "$T"
' 2>&1)"; RC=$?

echo "$OUT" | sed 's/^/    /'

if [ $RC -ne 0 ]; then
    bad "컨테이너 실행 실패 (rc=$RC)"
    echo "$OUT" | grep -qi "read-only file system" && \
        bad "→ WSL 디스크가 읽기 전용입니다. 호스트 디스크 여유 공간을 확인하세요."
else
    ok "컨테이너 실행됨"
    echo "$OUT" | grep -q "HIPIFY=MISSING" && bad "hipify-perl 없음" || ok "hipify-perl 있음"
    echo "$OUT" | grep -q "HIPCC=MISSING"  && bad "hipcc 없음"       || ok "hipcc 있음"
    echo "$OUT" | grep -q "gfx942_FAIL"    && bad "gfx942 코드 생성 실패" || ok "gfx942 코드 생성 가능 (GPU 없이)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m전부 통과. scripts/20_hipify.sh 로 진행하세요.\033[0m\n'
    exit 0
else
    printf '\033[31m%d 건 실패 — 위 항목을 해결한 뒤 다시 실행하세요.\033[0m\n' "$FAIL"
    exit 1
fi
