#!/usr/bin/env bash
# Phase 1 — NVIDIA 기준선 (GPU 필요, ~1시간)
#
#   NV_ARCH=sm_80 ./scripts/10_baseline_nvidia.sh
#
# scope.md §3 의 TF32 규칙을 코드로 강제한다:
#   llm.c 는 A100/H100 에서 TF32 를 자동으로 켜므로,
#   fp32 강제 빌드와 기본(TF32) 빌드를 둘 다 만들어 둘 다 측정한다.
#   비교표의 기준값은 fp32 쪽이고, TF32 값은 각주로만 쓴다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need nvcc "CUDA Toolkit 이 필요합니다."
check_vendor

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$VENDOR"/{attention_forward.cu,softmax_forward.cu,common.h} "$WORK/"
cp "$SRC"/flash_attention_simplified.cu "$SRC"/flash_attention_test.cu "$WORK/"

# --- fp32 강제 사본 만들기 (원본은 건드리지 않는다) ---
mkdir -p "$WORK/fp32"
cp "$WORK"/{attention_forward.cu,softmax_forward.cu,common.h} "$WORK/fp32/"
sed -i 's/int enable_tf32 = [^;]*;/int enable_tf32 = 0;/' \
    "$WORK/fp32/common.h" "$WORK/fp32/attention_forward.cu" "$WORK/fp32/softmax_forward.cu"
grep -n "int enable_tf32" "$WORK/fp32/common.h" "$WORK/fp32/attention_forward.cu" \
    || die "TF32 강제 패치 실패 — 소스 구조가 바뀌었는지 확인하세요."

NVFLAGS="-O3 --use_fast_math -arch=$NV_ARCH -lcublas -lcublasLt"

build_nv() {  # $1=이름 $2=소스디렉토리 $3=파일
    log "빌드: $1"
    # shellcheck disable=SC2086
    nvcc $NVFLAGS "$2/$3" -o "$BIN/$1" 2>&1 | tee "$RAW_BASE/build_$1.log"
}

timed "nvcc:attention_tf32"  build_nv attention_tf32  "$WORK"      attention_forward.cu
timed "nvcc:attention_fp32"  build_nv attention_fp32  "$WORK/fp32" attention_forward.cu
timed "nvcc:softmax_tf32"    build_nv softmax_tf32    "$WORK"      softmax_forward.cu
timed "nvcc:softmax_fp32"    build_nv softmax_fp32    "$WORK/fp32" softmax_forward.cu

log "빌드: flash (cuBLAS 미사용 — TF32 무관, 1회만)"
timed "nvcc:flash" nvcc -O3 --use_fast_math -arch="$NV_ARCH" \
    "$WORK/flash_attention_simplified.cu" "$WORK/flash_attention_test.cu" \
    -o "$BIN/flash_test" 2>&1 | tee "$RAW_BASE/build_flash.log"

# --- 환경 기록 (비교표의 각주가 된다) ---
{
    echo "# NVIDIA baseline 환경"
    echo "date: $(date -Is)"
    echo "arch: $NV_ARCH"
    nvcc --version
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
} > "$RAW_BASE/env.txt" 2>&1
cat "$RAW_BASE/env.txt"

# --- 실행: 커널 버전별 전수 ---
run_all() {  # $1=바이너리 $2=커널번호목록
    for k in $2; do
        log "실행: $1 kernel=$k"
        timed "run:$1:k$k" "$BIN/$1" "$k" 2>&1 | tee "$RAW_BASE/$1_k$k.log"
    done
}

run_all attention_fp32 "1 2 3 4 5 6"
run_all attention_tf32 "1 2 3 4 5 6"
run_all softmax_fp32   "1 2 3 4 5 6 7 8"
run_all softmax_tf32   "1 2 3 4 5 6 7 8"

log "실행: flash_test"
timed "run:flash" "$BIN/flash_test" 1024 2>&1 | tee "$RAW_BASE/flash_test.log"

log "완료. 01-baseline/raw/ 를 보고 baseline.md 표를 채우세요."
warn "GPU 인스턴스를 지금 끄세요."
