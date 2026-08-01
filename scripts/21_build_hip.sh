#!/usr/bin/env bash
# Phase 2b — hipcc 컴파일 루프 (★ GPU 불필요 ★)
#
# 이 프로젝트에서 가장 오래 걸리는 구간이다. GPU 과금 밖에서 끝낸다.
# --offload-arch 를 명시하므로 로컬에 AMD GPU 가 없어도 MI300X 코드가 생성된다.
#
#   docker run --rm -it -v "$PWD":/w -w /w rocm/dev-ubuntu-22.04:6.2 \
#       bash scripts/21_build_hip.sh
#
# 에러가 나면 종료하지 않고 전부 모아서 로그로 남긴다 — 에러 1건 = 이슈 로그 1줄.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need hipcc "ROCm 컨테이너(rocm/dev-ubuntu) 안에서 실행하세요."

ERRLOG="$ROOT/02-convert/build-errors.log"
: > "$ERRLOG"
FAILED=0

HIPFLAGS="-O3 -ffast-math --offload-arch=$AMD_ARCH -I$OUT_HIPIFY"

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
    "$OUT_HIPIFY/softmax_forward.hip.cpp"   -lhipblas -lhipblaslt
timed "hipcc:attention" try_build attention_hip \
    "$OUT_HIPIFY/attention_forward.hip.cpp" -lhipblas -lhipblaslt
timed "hipcc:flash"     try_build flash_hip \
    "$OUT_HIPIFY/flash_attention_simplified.hip.cpp" \
    "$OUT_HIPIFY/flash_attention_test.hip.cpp"

echo
if [ "$FAILED" -eq 0 ]; then
    log "전부 컴파일 성공. 이제서야 MI300X 를 켤 차례입니다 → scripts/30_verify_mi300x.sh"
else
    warn "$FAILED 개 실패. 02-convert/build-errors.log 를 보고 수정 루프를 도세요."
    warn "수정 1건 = logs/time-log.md 이슈 표 1줄 ([AUTO]/[LLM]/[MANUAL] 태그 필수)."
    warn "★ 여기서 MI300X 를 켜지 마세요. 컴파일은 GPU 없이 끝냅니다."
fi
exit 0
