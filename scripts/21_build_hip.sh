#!/usr/bin/env bash
# Phase 2b — hipcc 컴파일 루프 (★ GPU 불필요 ★)
#
# 이 프로젝트에서 가장 오래 걸리는 구간이다. GPU 과금 밖에서 끝낸다.
# --offload-arch 를 명시하므로 로컬에 AMD GPU 가 없어도 MI300X 코드가 생성된다.
#
#   docker run --rm -it -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 \
#       bash scripts/21_build_hip.sh
#
# 에러가 나면 종료하지 않고 전부 모아서 로그로 남긴다 — 에러 1건 = 이슈 로그 1줄.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need hipcc "ROCm 컨테이너(rocm/dev-ubuntu) 안에서 실행하세요."

ERRLOG="$ROOT/02-convert/build-errors.log"
: > "$ERRLOG"
FAILED=0

HIPFLAGS="-O3 -ffast-math --offload-arch=$AMD_ARCH -I$OUT_HIPIFY"

# ---------------------------------------------------------------------------
# FP32_ONLY=1 : bf16 경로를 빼고 전부 fp32 로 빌드한다.
#
# 왜 필요한가 — 비교 조건을 맞추기 위해서다.
#   기준선 GPU 가 sm_80 미만이면 __nv_bfloat16 이 동작하지 않아
#   NVIDIA 쪽은 fp32 로 측정된다 (10_baseline_nvidia.sh 가 자동으로 그렇게 한다).
#   그때 MI300X 만 bf16 으로 돌리면 정밀도가 다른 것끼리 비교하게 된다.
#
# hipify-out/ 은 건드리지 않는다. 사본에만 sed 를 걸어 빌드한다 —
# hipify-out/ 의 git diff 는 "사람이 한 수정" 지표라 오염시키면 안 된다.
# ---------------------------------------------------------------------------
SRC_DIR="$OUT_HIPIFY"
if [ "${FP32_ONLY:-0}" = "1" ]; then
    SRC_DIR="$(mktemp -d)"
    trap 'rm -rf "$SRC_DIR"' EXIT
    cp "$OUT_HIPIFY"/* "$SRC_DIR"/
    sed -i 's|^#define ENABLE_BF16|// [FP32_ONLY] 기준선과 정밀도를 맞추기 위해 비활성\n//#define ENABLE_BF16|' \
        "$SRC_DIR/attention_forward.hip.cpp"
    grep -q "^//#define ENABLE_BF16" "$SRC_DIR/attention_forward.hip.cpp" \
        || die "ENABLE_BF16 제거 실패"
    # ★ llm.c 의 fp32 경로는 그 자체로 불완전하다.
    #   common.h 의 #else(fp32) 분기는 typedef 만 하고 CUBLAS_LOWP /
    #   CUBLAS_LOWP_COMPUTE 를 정의하지 않는데, attention_forward 는 이걸 11곳에서 쓴다.
    #   → ENABLE_BF16 을 끄는 순간 'undeclared identifier' 로 깨진다.
    #   fp32 분기에는 정의가 아예 없으므로 -D 로 넣어도 재정의 충돌이 없다.
    #   (#if CUBLAS_LOWP == HIP_R_16BF 는 #ifdef ENABLE_CUDNN 안이라 평가되지 않는다)
    HIPFLAGS="-O3 -ffast-math --offload-arch=$AMD_ARCH -I$SRC_DIR"
    HIPFLAGS="$HIPFLAGS -DCUBLAS_LOWP=HIP_R_32F -DCUBLAS_LOWP_COMPUTE=HIPBLAS_COMPUTE_32F"
    log "FP32_ONLY — bf16 경로 제외하고 빌드 (기준선과 조건 일치)"
fi

try_build() {  # $1=출력명 $2...=소스들
    local name="$1"; shift
    log "hipcc: $name"
    # shellcheck disable=SC2086
    if hipcc $HIPFLAGS "$@" -o "$BIN/$name" 2> "$ROOT/02-convert/err_$name.log"; then
        log "  OK"
        return 0
    else
        FAILED=$((FAILED + 1))
        warn "  실패 — 02-convert/err_$name.log"
        {
            echo "########## $name ##########"
            cat "$ROOT/02-convert/err_$name.log"
            echo
        } >> "$ERRLOG"
        # 에러 종류별 개수 — 이슈 로그 작성의 출발점
        grep -oP 'error: [^\[]*' "$ROOT/02-convert/err_$name.log" \
            | sort | uniq -c | sort -rn | head -20
        return 1
    fi
}

# 쉬운 것부터가 아니라 scope.md 가 정한 순서대로 간다.
timed "hipcc:softmax"   try_build softmax_hip \
    "$SRC_DIR/softmax_forward.hip.cpp"   -lhipblas -lhipblaslt
timed "hipcc:attention" try_build attention_hip \
    "$SRC_DIR/attention_forward.hip.cpp" -lhipblas -lhipblaslt
timed "hipcc:flash"     try_build flash_hip \
    "$SRC_DIR/flash_attention_simplified.hip.cpp" \
    "$SRC_DIR/flash_attention_test.hip.cpp"

echo
if [ "$FAILED" -eq 0 ]; then
    log "전부 컴파일 성공. 이제서야 MI300X 를 켤 차례입니다 → scripts/30_verify_mi300x.sh"
else
    warn "$FAILED 개 실패. 02-convert/build-errors.log 를 보고 수정 루프를 도세요."
    warn "수정 1건 = logs/time-log.md 이슈 표 1줄 ([AUTO]/[LLM]/[MANUAL] 태그 필수)."
    warn "★ 여기서 MI300X 를 켜지 마세요. 컴파일은 GPU 없이 끝냅니다."
fi
exit 0
