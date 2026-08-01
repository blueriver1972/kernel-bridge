#!/usr/bin/env bash
# Phase 1 — NVIDIA 기준선 (GPU 필요)
#
#   NV_ARCH=sm_52 bash scripts/10_baseline_nvidia.sh     # GTX 970 (WSL2)
#   NV_ARCH=sm_80 bash scripts/10_baseline_nvidia.sh     # A100
#
# 아키텍처를 보고 스스로 적응한다. 같은 스크립트로 970 과 A100 을 모두 돌린다.
#
#   sm_80 이상 : bf16 사용 가능 · TF32 자동 활성 → fp32 강제본과 두 벌 측정
#   sm_80 미만 : bf16 불가(__nv_bfloat16 은 sm_80+) · TF32 없음 → fp32 한 벌
#
# 선택 환경변수:
#   LLMC_B=4   문제 크기 B 를 줄인다 (VRAM 부족 시). ★ MI300X 에도 같은 값을 써야 비교가 성립한다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export PATH=/usr/local/cuda/bin:$PATH
need nvcc "CUDA Toolkit 이 필요합니다. scripts/win/setup-cuda-wsl.sh 를 먼저 실행하세요."
check_vendor

ARCH_NUM="${NV_ARCH#sm_}"
if [ "$ARCH_NUM" -ge 80 ] 2>/dev/null; then MODERN=1; else MODERN=0; fi
log "타깃 $NV_ARCH — bf16/TF32 $([ $MODERN -eq 1 ] && echo 사용 || echo 미사용)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$VENDOR"/{attention_forward.cu,softmax_forward.cu,common.h} "$WORK/"
cp "$SRC"/flash_attention_simplified.cu "$SRC"/flash_attention_test.cu "$WORK/"

# --- 문제 크기 축소 (선택) --------------------------------------------------
if [ -n "${LLMC_B:-}" ]; then
    sed -i "s/^    int B = 8;/    int B = $LLMC_B;/" \
        "$WORK/attention_forward.cu" "$WORK/softmax_forward.cu"
    grep -q "int B = $LLMC_B;" "$WORK/softmax_forward.cu" || die "B 축소 패치 실패"
    warn "문제 크기 B=8 → B=$LLMC_B 로 축소. MI300X 에도 반드시 같은 값을 쓸 것."
fi

# --- sm_80 미만: bf16 경로 제거 ---------------------------------------------
# __nv_bfloat16 은 sm_80 이상에서만 동작한다. common.h 의 #else 분기가
# floatX=float 로 떨어지므로 ENABLE_BF16 정의만 지우면 전체가 fp32 가 된다.
if [ $MODERN -eq 0 ]; then
    sed -i 's/^#define ENABLE_BF16/\/\/ [sm_80 미만] bf16 미지원 → fp32 경로 사용\n\/\/#define ENABLE_BF16/' \
        "$WORK/attention_forward.cu"
    grep -q "^//#define ENABLE_BF16" "$WORK/attention_forward.cu" \
        || die "ENABLE_BF16 제거 실패 — 소스 구조 확인 필요"
    log "ENABLE_BF16 제거 — 전 커널 fp32 로 측정"
fi

NVFLAGS="-O3 --use_fast_math -arch=$NV_ARCH -Wno-deprecated-gpu-targets"
BLAS="-lcublas -lcublasLt"

build_nv() {  # $1=출력명 $2=소스디렉토리 $3=파일 $4...=추가플래그
    local name="$1" dir="$2" f="$3"; shift 3
    log "빌드: $name"
    # shellcheck disable=SC2086
    if nvcc $NVFLAGS "$dir/$f" "$@" -o "$BIN/$name" 2>&1 | tee "$RAW_BASE/build_$name.log"; then
        [ -x "$BIN/$name" ] && { log "  OK"; return 0; }
    fi
    warn "  빌드 실패 — $RAW_BASE/build_$name.log"
    return 1
}

# --- fp32 기준 빌드 (비교표의 기준값) ----------------------------------------
# sm_80+ 에서는 TF32 가 자동으로 켜지므로 명시적으로 끈 사본을 만든다.
if [ $MODERN -eq 1 ]; then
    mkdir -p "$WORK/fp32"
    cp "$WORK"/{attention_forward.cu,common.h} "$WORK/fp32/"
    sed -i 's/int enable_tf32 = [^;]*;/int enable_tf32 = 0;/' \
        "$WORK/fp32/common.h" "$WORK/fp32/attention_forward.cu"
    for f in common.h attention_forward.cu; do
        grep -q "int enable_tf32 = 0;" "$WORK/fp32/$f" || die "TF32 강제 패치 실패: $f"
    done
    log "TF32 강제 패치 확인됨"
    ATT_DIR="$WORK/fp32"
else
    # sm_80 미만은 하드웨어에 TF32 자체가 없다 — 원본 그대로가 곧 fp32 다.
    ATT_DIR="$WORK"
fi

timed "nvcc:attention_fp32" build_nv attention_fp32 "$ATT_DIR" attention_forward.cu $BLAS
timed "nvcc:softmax"        build_nv softmax        "$WORK"    softmax_forward.cu   $BLAS
timed "nvcc:flash"          build_nv flash_test     "$WORK"    flash_attention_simplified.cu \
                                    "$WORK/flash_attention_test.cu"

# --- TF32 참고값 (sm_80+ 에서만) ---------------------------------------------
if [ $MODERN -eq 1 ]; then
    timed "nvcc:attention_tf32" build_nv attention_tf32 "$WORK" attention_forward.cu $BLAS
fi

# --- 환경 기록 (비교표의 각주가 된다) ---------------------------------------
{
    echo "# NVIDIA baseline 환경"
    echo "date: $(date -Is)"
    echo "arch: $NV_ARCH"
    echo "bf16/TF32: $([ $MODERN -eq 1 ] && echo enabled || echo 'N/A (sm_80 미만)')"
    echo "LLMC_B: ${LLMC_B:-8 (원본)}"
    nvcc --version
    nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv
} > "$RAW_BASE/env.txt" 2>&1
cat "$RAW_BASE/env.txt"

# --- 실행 ---------------------------------------------------------------------
run_all() {  # $1=바이너리 $2=커널번호목록
    if [ ! -x "$BIN/$1" ]; then warn "$1 없음 — 건너뜀"; return; fi
    for k in $2; do
        log "실행: $1 kernel=$k"
        timed "run:$1:k$k" "$BIN/$1" "$k" 2>&1 | tee "$RAW_BASE/$1_k$k.log"
    done
}

run_all softmax        "1 2 3 4 5 6 7 8"
run_all attention_fp32 "1 2 3 4 5 6"
[ $MODERN -eq 1 ] && run_all attention_tf32 "1 2 3 4 5 6"

if [ -x "$BIN/flash_test" ]; then
    log "실행: flash_test"
    timed "run:flash" "$BIN/flash_test" 1024 2>&1 | tee "$RAW_BASE/flash_test.log"
fi

echo
log "=== 정확도 요약 ==="
grep -h "PASS\|FAIL\|NOT OK\|Mismatch\|out of memory" "$RAW_BASE"/*.log 2>/dev/null \
    | sort | uniq -c | sort -rn | tee "$RAW_BASE/accuracy-summary.txt"

log "완료. 01-baseline/raw/ 를 보고 baseline.md 표를 채우세요."
[ $MODERN -eq 1 ] && warn "GPU 인스턴스를 지금 끄세요."
exit 0
