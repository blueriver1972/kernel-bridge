#!/usr/bin/env bash
# Phase 2a — hipify (★ GPU 불필요 ★)
#
# ROCm 도커 컨테이너 안에서 CPU 만으로 돈다. MI300X 를 켜지 말 것.
#   docker run --rm -it -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 \
#       bash scripts/20_hipify.sh
#
# 원본은 절대 수정하지 않는다. 출력은 02-convert/hipify-out/ 로만 나간다.
# 헤더는 이름을 유지해야 #include "common.h" 가 그대로 해결된다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need hipify-perl "ROCm 컨테이너(rocm/dev-ubuntu) 안에서 실행하세요."
check_vendor

# ---------------------------------------------------------------------------
# ★ 안전장치 ★
# hipify 를 다시 돌리면 02-convert/hipify-out/ 을 통째로 덮어쓴다.
# 거기에는 우리가 손으로 고친 11건이 들어 있고, 그 diff 가 곧 보고서의
# "사람이 한 일" 지표다. 실수로 날리면 되돌리기 전까지 측정이 사라진다.
# (녹화 중에 무심코 돌리는 상황을 실제로 대비한 것이다)
if ls "$OUT_HIPIFY"/* >/dev/null 2>&1 && grep -lq "FIX-" "$OUT_HIPIFY"/* 2>/dev/null; then
    if [ "${FORCE:-0}" != "1" ]; then
        warn "02-convert/hipify-out/ 에 수정 표시(FIX-)가 있는 파일이 있습니다."
        warn "지금 실행하면 그 수정이 전부 덮어써집니다."
        warn ""
        warn "  정말 다시 변환하려면 :  FORCE=1 bash scripts/20_hipify.sh"
        warn "  되돌리려면          :  git checkout -- 02-convert/hipify-out/"
        die  "안전을 위해 중단했습니다."
    fi
    warn "FORCE=1 — 기존 수정을 덮어씁니다."
fi

DIFFS="$ROOT/02-convert/diffs"
mkdir -p "$DIFFS"
STATS="$ROOT/02-convert/hipify-stats.txt"
: > "$STATS"

hipify_one() {  # $1=입력경로 $2=출력파일명
    local in="$1" out="$OUT_HIPIFY/$2" name
    name="$(basename "$1")"
    log "hipify: $name -> $2"
    hipify-perl "$in" > "$out" || die "hipify 실패: $in"
    {
        echo "=== $name -> $2 ==="
        # 변환된 심볼 개수 = "자동으로 해결된 양"의 1차 근사
        diff -u "$in" "$out" | grep -c '^+' || true
    } >> "$STATS"
    diff -u "$in" "$out" > "$DIFFS/$2.diff"
    return 0
}

timed "hipify:common.h"            hipify_one "$VENDOR/common.h"                     "common.h"
timed "hipify:softmax_forward"     hipify_one "$VENDOR/softmax_forward.cu"           "softmax_forward.hip.cpp"
timed "hipify:attention_forward"   hipify_one "$VENDOR/attention_forward.cu"         "attention_forward.hip.cpp"
timed "hipify:flash_kernel"        hipify_one "$SRC/flash_attention_simplified.cu"   "flash_attention_simplified.hip.cpp"
timed "hipify:flash_test"          hipify_one "$SRC/flash_attention_test.cu"         "flash_attention_test.hip.cpp"

echo
log "=== hipify 가 놓쳤을 가능성이 높은 지점 (scope.md R1~R4) ==="
# 자동 변환 이후에도 남아있는 32 가정을 훑는다. 여기 걸리는 것이 [MANUAL] 후보다.
grep -n 'WARP_SIZE\|0xFFFFFFFF\|tiled_partition<32>\|thread_block_tile<32>\|/ 32\|% 32' \
    "$OUT_HIPIFY"/*.hip.cpp "$OUT_HIPIFY/common.h" \
    | tee "$ROOT/02-convert/residual-32-assumptions.txt" || true

echo
log "완료. diff 는 02-convert/diffs/, 잔여 항목은 02-convert/residual-32-assumptions.txt"
log "다음: scripts/21_build_hip.sh (여전히 GPU 불필요)"
