#!/usr/bin/env bash
# Phase 3 — MI300X 실행 검증 (GPU 필요, 2~3시간)
#
# 전제: 21_build_hip.sh 가 GPU 없이 이미 전부 통과한 상태.
# 여기서 처음 마주치는 것은 "런타임" 오류뿐이어야 한다 —
# 그게 이 순서로 짠 이유다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need rocm-smi "MI300X 인스턴스에서 실행하세요."

{
    echo "# MI300X verify 환경"
    echo "date: $(date -Is)"
    echo "offload-arch: $AMD_ARCH"
    hipcc --version
    rocm-smi --showproductname --showdriverversion
} > "$RAW_VERIFY/env.txt" 2>&1
cat "$RAW_VERIFY/env.txt"

run_all() {  # $1=바이너리 $2=커널번호목록
    [ -x "$BIN/$1" ] || { warn "$1 없음 — 건너뜀"; return; }
    for k in $2; do
        log "실행: $1 kernel=$k"
        timed "run:$1:k$k" "$BIN/$1" "$k" 2>&1 | tee "$RAW_VERIFY/$1_k$k.log"
    done
}

run_all softmax_hip   "1 2 3 4 5 6 7 8"
run_all attention_hip "1 2 3 4 5 6"

if [ -x "$BIN/flash_hip" ]; then
    log "실행: flash_hip"
    timed "run:flash_hip" "$BIN/flash_hip" 1024 2>&1 | tee "$RAW_VERIFY/flash_test.log"
fi

# 정확도 판정 요약 — 눈으로 세지 않는다
echo
log "=== 정확도 요약 ==="
grep -h "PASS\|FAIL\|NOT OK\|Mismatch" "$RAW_VERIFY"/*.log \
    | sort | uniq -c | sort -rn | tee "$RAW_VERIFY/accuracy-summary.txt"

# 병목 커널 1개 식별 (03-verify 체크리스트 항목)
if command -v rocprof >/dev/null 2>&1; then
    log "rocprof: 가장 느렸던 경로 1건 프로파일"
    timed "rocprof:attention" rocprof --stats \
        -o "$RAW_VERIFY/rocprof_attention.csv" "$BIN/attention_hip" 4 \
        > "$RAW_VERIFY/rocprof_attention.log" 2>&1 || warn "rocprof 실패 — 로그 확인"
else
    warn "rocprof 없음 — 병목 식별 단계 건너뜀"
fi

log "완료. 03-verify/raw/ 로 verify.md 비교표를 채우세요."
warn "★ GPU 인스턴스를 지금 끄세요. ★"
