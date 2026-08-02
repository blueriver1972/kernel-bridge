#!/usr/bin/env bash
# ============================================================================
# MI300X 포드 세션 — 단일 진입점 (Phase 3)
#
#   bash scripts/50_pod_session.sh
#
# 유료 GPU 시간을 최소화하는 것이 목적이다. 클론 직후 이 한 줄만 치면
# 빌드 → 검증 → 덤프 → 요약까지 끝나고, 실패해도 어디서 멈췄는지 남는다.
#
# ★ 이 스크립트는 20_hipify.sh 를 부르지 않는다 ★
#   hipify 를 다시 돌리면 02-convert/hipify-out/ 의 수정 11건이 전부 덮어써진다.
#   변환 결과는 이미 저장소에 커밋돼 있으므로 그대로 쓴다.
#
# 환경 자동 감지:
#   - 포드에 ROCm 이 이미 깔려 있으면(대부분) hipcc 를 직접 쓴다
#   - 아니면 docker 로 kernel-bridge/rocm:6.3 을 빌드해 쓴다
#   RunPod 등의 포드는 그 자체가 컨테이너라 docker build 가 막혀 있는 경우가 많다.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# 기준선과 조건을 맞춘다. 어긋나면 비교표가 무효다.
#
#   [A] H100 과 짝지을 때 (본 측정) — 권장
#       원본 그대로. 양쪽 다 bf16 을 지원하고 TDR 제약도 없다.
#         FP32_ONLY=0 LLMC_B=   bash scripts/50_pod_session.sh   # bf16
#         FP32_ONLY=1 LLMC_B=   bash scripts/50_pod_session.sh   # fp32
#
#   [B] GTX 970 기준선과 짝지을 때 (정확도 리허설)
#       970 은 bf16 미지원(sm_52) + Windows TDR 로 B=2 가 한계였다.
#         FP32_ONLY=1 LLMC_B=2  bash scripts/50_pod_session.sh
#
# 기본값은 [B] 다 — 지금 확보된 기준선이 970 뿐이기 때문이다.
# H100 을 측정한 뒤에는 [A] 로 다시 돌린다.
# ---------------------------------------------------------------------------
export FP32_ONLY="${FP32_ONLY:-1}"
export LLMC_B="${LLMC_B:-2}"
if [ -n "$LLMC_B" ]; then
    log "문제 크기 축소: B=$LLMC_B — NVIDIA 쪽도 같은 값이어야 한다"
else
    log "문제 크기: 원본 B=8"
fi

SESSION_LOG="$ROOT/03-verify/raw/session.log"
mkdir -p "$ROOT/03-verify/raw" "$ROOT/report/demo-images"

step() { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*" | tee -a "$SESSION_LOG"; }

{
echo "===== MI300X 세션 시작 $(date -Is) ====="
echo "FP32_ONLY=$FP32_ONLY  LLMC_B=$LLMC_B  AMD_ARCH=$AMD_ARCH"
} >> "$SESSION_LOG"

# --- 0. 환경 확인 -----------------------------------------------------------
step "0. 환경 확인"
command -v rocm-smi >/dev/null 2>&1 \
    && rocm-smi --showproductname 2>&1 | tee -a "$SESSION_LOG" \
    || warn "rocm-smi 없음 — GPU 없는 환경입니까?"

if command -v hipcc >/dev/null 2>&1; then
    RUNNER="native"
    log "ROCm 네이티브 감지 — docker 없이 진행합니다"
    hipcc --version | head -3 | tee -a "$SESSION_LOG"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    RUNNER="docker"
    log "docker 사용 — 이미지 빌드"
    docker build -t kernel-bridge/rocm:6.3 "$ROOT/docker/" 2>&1 | tail -3
else
    die "hipcc 도 docker 도 없습니다. ROCm 이 있는 포드를 고르거나 docker 를 켜세요."
fi

# 컨테이너/네이티브 차이를 흡수한다.
# ★ 빌드와 실행을 분리한다 — 컴파일에는 GPU 장치가 필요 없고,
#   장치 플래그를 붙이면 GPU 없는 환경에서 빌드조차 실패한다 (리허설에서 발생).
run_build() {   # $1 = 저장소 루트 기준 상대경로
    if [ "$RUNNER" = native ]; then
        env FP32_ONLY="$FP32_ONLY" LLMC_B="$LLMC_B" bash "$ROOT/$1"
    else
        docker run --rm -e FP32_ONLY="$FP32_ONLY" -e LLMC_B="$LLMC_B" \
            -v "$ROOT":/w -w /w kernel-bridge/rocm:6.3 bash "/w/$1"
    fi
}

run_gpu() {     # $1 = 저장소 루트 기준 상대경로, 나머지는 스크립트 인자
    local rel="$1"; shift
    if [ "$RUNNER" = native ]; then
        env FP32_ONLY="$FP32_ONLY" LLMC_B="$LLMC_B" bash "$ROOT/$rel" "$@"
    else
        docker run --rm --device=/dev/kfd --device=/dev/dri --group-add video \
            -e FP32_ONLY="$FP32_ONLY" -e LLMC_B="$LLMC_B" \
            -v "$ROOT":/w -w /w kernel-bridge/rocm:6.3 bash "/w/$rel" "$@"
    fi
}

# --- 1. 소스 확보 -----------------------------------------------------------
step "1. llm.c 소스 확보 (고정 SHA)"
bash "$ROOT/scripts/00_fetch_sources.sh" 2>&1 | tail -3 | tee -a "$SESSION_LOG"

# --- 2. 변환 결과 무결성 확인 ------------------------------------------------
step "2. 변환 결과 확인 (hipify 재실행 안 함)"
for f in softmax_forward.hip.cpp attention_forward.hip.cpp \
         flash_attention_simplified.hip.cpp flash_attention_test.hip.cpp \
         common.h cg_reduce_compat.h hip_intrinsics_compat.h; do
    [ -f "$OUT_HIPIFY/$f" ] || die "변환 결과 누락: $f — 저장소가 온전한지 확인하세요."
done
ok_fixes=$(grep -l "FIX-" "$OUT_HIPIFY"/*.hip.cpp "$OUT_HIPIFY"/*.h 2>/dev/null | wc -l)
log "수정 마커(FIX-) 가 있는 파일: ${ok_fixes}개"
[ "$ok_fixes" -ge 3 ] || warn "수정이 유실됐을 수 있습니다. git status 를 확인하세요."

# --- 3. 빌드 ---------------------------------------------------------------
step "3. hipcc 빌드 (FP32_ONLY=$FP32_ONLY)"
# 이전 산출물을 먼저 지운다. 남아 있으면 빌드가 실패해도
# 파일 존재 검사가 통과해 '성공'으로 오인된다 (리허설에서 실제로 발생).
rm -f "$BIN"/softmax_hip "$BIN"/attention_hip "$BIN"/flash_hip
run_build "scripts/21_build_hip.sh" 2>&1 | tee -a "$SESSION_LOG"
missing=0
for b in softmax_hip attention_hip flash_hip; do
    [ -x "$BIN/$b" ] || { warn "빌드 실패: $b"; missing=$((missing+1)); }
done
[ "$missing" -eq 0 ] || die "$missing 개 빌드 실패 — 여기서 멈춥니다. 02-convert/err_*.log 확인."
log "3개 바이너리 확인"

# --- 4. 검증 실행 -----------------------------------------------------------
step "4. MI300X 실행 + 정확도 검증"
run_gpu "scripts/30_verify_mi300x.sh" 2>&1 | tee -a "$SESSION_LOG"

# --- 5. 데모 덤프 -----------------------------------------------------------
step "5. 데모용 출력 덤프 (차이 이미지 재료)"
# ★ 반드시 ROCm 환경 안에서 돌려야 한다. 밖에서 돌리면 hipcc 를 못 찾아
#   nvcc 로 잘못 분기한다 (리허설에서 실제로 발생).
run_gpu "scripts/41_dump_reference.sh" amd_mi300x 1024 2>&1 | tee -a "$SESSION_LOG" \
    || warn "덤프 실패 — 검증 결과 자체는 위에 남아 있습니다"

# --- 6. 요약 ---------------------------------------------------------------
step "6. 요약"
{
    echo "=== 정확도 ==="
    grep -hiE "PASS|FAIL|Mismatch|NOT OK" "$RAW_VERIFY"/*.log 2>/dev/null \
        | sort | uniq -c | sort -rn | head -20
    echo
    echo "=== 실행 시간 ==="
    grep "^2" "$ROOT/logs/auto-time.tsv" | grep "run:" | tail -20
} | tee -a "$SESSION_LOG"

cat <<EOF

────────────────────────────────────────────────────────────
세션 종료. ★ 인스턴스를 지금 끄세요. ★

가져갈 것 (git commit & push 하거나 scp):
  03-verify/raw/            원시 로그 + session.log
  report/demo-images/amd_mi300x.bin   데모 이미지 재료
  logs/auto-time.tsv        시간 기록

로컬에서 이어서:
  python3 scripts/40_demo_images.py \\
      report/demo-images/nvidia_970.bin \\
      report/demo-images/amd_mi300x.bin \\
      --labels NVIDIA MI300X
────────────────────────────────────────────────────────────
EOF
