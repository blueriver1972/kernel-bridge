#!/usr/bin/env bash
# 데모 장치 1 — 출력 덤프 생성 (report/demo-plan.md)
#
#   NVIDIA:  NV_ARCH=sm_52 bash scripts/41_dump_reference.sh nvidia
#   MI300X:  bash scripts/41_dump_reference.sh amd      (ROCm 컨테이너 안에서)
#
# 결과: report/demo-images/<이름>.bin  (raw float32, N x 64)
# 두 개가 모이면 scripts/40_demo_images.py 로 열지도 3장을 만든다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAME="${1:-dump}"
N="${2:-1024}"
OUT="$ROOT/report/demo-images"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# BREAK=1 : 커널에 **진짜 버그**를 주입해 빌드한다 (데모 장치 2 검증용).
#
# online softmax 의 재조정 계수를 1.0 으로 바꾼다. 새 타일의 최댓값이
# 기존보다 클 때 누적값을 새 기준으로 되돌리지 않게 되므로 답이 틀린다.
# 조작된 데이터가 아니라 **실제로 컴파일해 GPU 에서 돌린 잘못된 커널**이다.
#
# 원본은 건드리지 않는다 — 사본에만 sed 를 건다.
# ---------------------------------------------------------------------------
KSRC="$SRC/flash_attention_simplified.cu"
if [ "${BREAK:-0}" = "1" ]; then
    BT="$(mktemp -d)"
    cp "$KSRC" "$BT/broken.cu"
    sed -i 's|float correction = __expf(m - m_new);.*|float correction = 1.0f;  // [DEMO BUG] online softmax 재조정 제거|' "$BT/broken.cu"
    grep -q "DEMO BUG" "$BT/broken.cu" || die "버그 주입 실패 — 원본 구조 확인 필요"
    KSRC="$BT/broken.cu"
    warn "★ 버그 주입 빌드 (BREAK=1) — 일부러 틀린 커널입니다"
fi

if command -v hipcc >/dev/null 2>&1 && [ -d "$OUT_HIPIFY" ] && [ -f "$OUT_HIPIFY/flash_attention_simplified.hip.cpp" ]; then
    # --- AMD 경로 -----------------------------------------------------------
    # dump 소스는 hipify-out 에 없다 (지표 오염 방지로 분리해 뒀다).
    # 여기서만 임시로 변환한다.
    T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
    hipify-perl "$SRC/flash_attention_dump.cu" > "$T/dump.hip.cpp" || die "hipify 실패"
    log "hipcc 로 빌드 (arch=$AMD_ARCH)"
    hipcc -O3 -ffast-math --offload-arch="$AMD_ARCH" \
        "$OUT_HIPIFY/flash_attention_simplified.hip.cpp" "$T/dump.hip.cpp" \
        -o "$BIN/flash_dump" || die "빌드 실패"
elif command -v nvcc >/dev/null 2>&1 || [ -x /usr/local/cuda/bin/nvcc ]; then
    # --- NVIDIA 경로 ---------------------------------------------------------
    export PATH=/usr/local/cuda/bin:$PATH
    log "nvcc 로 빌드 (arch=$NV_ARCH)"
    nvcc -O3 --use_fast_math -arch="$NV_ARCH" -Wno-deprecated-gpu-targets \
        "$KSRC" "$SRC/flash_attention_dump.cu" \
        -o "$BIN/flash_dump" || die "빌드 실패"
else
    die "nvcc 도 hipcc 도 없습니다."
fi

timed "dump:$NAME" "$BIN/flash_dump" "$N" "$OUT/$NAME.bin" || die "실행 실패"
log "완료: report/demo-images/$NAME.bin"
