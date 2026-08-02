#!/usr/bin/env bash
# ============================================================================
# 데모 재현 — "hipify는 성공했다는데 컴파일이 안 된다" (GPU 불필요)
#
#   docker run --rm -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 \
#       bash scripts/70_demo_replay.sh
#
# 녹화용이다. 실제로 겪은 일을 그대로 되돌려 보여준다:
#
#   1) hipify 는 "5개 파일 전부 변환 성공" 이라고 말한다
#   2) 그 결과를 컴파일하면 에러가 쏟아진다
#   3) 수정본으로 컴파일하면 통과한다
#
# 조작이 아니다. 2)는 커밋 78a1a46(수정 전 hipify 출력)을 그대로 꺼내 쓰고,
# 3)은 현재 저장소 상태를 쓴다. 작업 트리는 건드리지 않는다.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need hipcc "ROCm 컨테이너 안에서 실행하세요."
need git   "컨테이너 이미지를 다시 빌드하세요 (docker build -t kernel-bridge/rocm:6.3 docker/)."

# 컨테이너 안에서는 UID 가 달라 git 이 소유권을 의심한다
git config --global --add safe.directory '*' 2>/dev/null || true

PRE="$(git -C "$ROOT" log --all --format='%H' --grep='hipify 원본' | head -1)"
[ -n "$PRE" ] || die "수정 전 기준선 커밋을 찾을 수 없습니다."

BEFORE="$(mktemp -d)"; AFTER="$(mktemp -d)"
trap 'rm -rf "$BEFORE" "$AFTER"' EXIT

hr() { printf '\033[90m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
title() { printf '\n\033[1;97m%s\033[0m\n' "$*"; }

# --- 수정 전 상태 추출 -------------------------------------------------------
for f in softmax_forward.hip.cpp attention_forward.hip.cpp \
         flash_attention_simplified.hip.cpp flash_attention_test.hip.cpp common.h; do
    git -C "$ROOT" show "$PRE:02-convert/hipify-out/$f" > "$BEFORE/$f" 2>/dev/null \
        || die "추출 실패: $f"
done
cp "$OUT_HIPIFY"/* "$AFTER"/ 2>/dev/null

FLAGS="-O3 -ffast-math --offload-arch=$AMD_ARCH"
FLAGS="$FLAGS -DCUBLAS_LOWP=HIP_R_32F -DCUBLAS_LOWP_COMPUTE=HIPBLAS_COMPUTE_32F"

# 기준선과 정밀도를 맞춘다 (bf16 제외)
prep_fp32() {
    sed -i 's|^#define ENABLE_BF16|//#define ENABLE_BF16|' "$1/attention_forward.hip.cpp"
}
prep_fp32 "$BEFORE"; prep_fp32 "$AFTER"

build_one() {   # $1=디렉토리 $2=대상 → 에러 개수를 stdout 으로
    local d="$1" t="$2" extra=""
    case "$t" in
        softmax)   src="$d/softmax_forward.hip.cpp";   extra="-lhipblas -lhipblaslt" ;;
        attention) src="$d/attention_forward.hip.cpp"; extra="-lhipblas -lhipblaslt" ;;
        flash)     src="$d/flash_attention_simplified.hip.cpp $d/flash_attention_test.hip.cpp" ;;
    esac
    # shellcheck disable=SC2086
    hipcc $FLAGS -I"$d" $src $extra -o /dev/null 2> "$d/$t.err"
    # grep -c 는 0건일 때 "0" 을 찍고 종료코드 1 을 낸다.
    # '|| echo 0' 을 붙이면 "0\n0" 이 되어 산술 연산이 깨진다 (실제로 겪었다).
    local n
    n=$(grep -c "error:" "$d/$t.err" 2>/dev/null || true)
    echo "${n:-0}"
}

# ============================================================================
title "1단계 — hipify 결과 (자동 변환기가 '성공'이라고 말한 상태)"
hr
cat "$ROOT/02-convert/hipify-stats.txt" 2>/dev/null | sed 's/^/  /'
printf '  → 5개 파일 전부 변환 완료. 총 164줄 치환.\n'
hr

title "2단계 — 그 결과를 컴파일하면?"
hr
total_before=0
for t in softmax attention flash; do
    n=$(build_one "$BEFORE" "$t")
    total_before=$((total_before + n))
    if [ "$n" -gt 0 ]; then
        printf '  \033[31m✗ %-10s 에러 %2d건\033[0m\n' "$t" "$n"
        grep -oE "error: [^[]*" "$BEFORE/$t.err" | sort -u | head -4 | sed 's/^/       /'
    else
        printf '  \033[32m✓ %-10s 통과\033[0m\n' "$t"
    fi
done
hr
printf '  \033[1;31m변환은 "성공"했지만 빌드는 안 된다 — 총 %d건\033[0m\n' "$total_before"

title "3단계 — 사람/LLM 이 수정한 뒤"
hr
total_after=0
for t in softmax attention flash; do
    n=$(build_one "$AFTER" "$t")
    total_after=$((total_after + n))
    if [ "$n" -gt 0 ]; then
        printf '  \033[31m✗ %-10s 에러 %2d건\033[0m\n' "$t" "$n"
    else
        printf '  \033[32m✓ %-10s 통과\033[0m\n' "$t"
    fi
done
hr

if [ "$total_after" -eq 0 ]; then
    printf '  \033[1;32m전부 통과 — gfx942(MI300X) 바이너리 생성 가능\033[0m\n'
else
    printf '  \033[1;31m아직 %d건 남음\033[0m\n' "$total_after"
fi

title "수정 규모"
hr
git -C "$ROOT" diff --stat "$PRE" HEAD -- 02-convert/hipify-out/ | sed 's/^/  /'
hr
cat <<'EOF'

  자동으로 된 것      164 줄   (hipify)
  도구가 놓친 것       11 건   (컴파일 에러, 5회차 누적)
  ├ 컴파일러가 알려줌   8 건   → LLM 루프가 자동 수렴
  └ 컴파일러가 침묵     3 건   → 실행 검증이 없으면 발견 불가

  ※ 위 2단계에 3건만 보이는 이유: 'file not found' 는 컴파일을
    즉시 중단시켜 파일당 첫 에러만 드러난다. 하나 고치면 다음이
    나오는 식으로 5회차에 걸쳐 총 11건이었다.

EOF
