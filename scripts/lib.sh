#!/usr/bin/env bash
# 공통 설정 — 모든 스크립트가 source 한다.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/llm.c/dev/cuda"
SRC="$ROOT/00-src"
OUT_HIPIFY="$ROOT/02-convert/hipify-out"
RAW_BASE="$ROOT/01-baseline/raw"
RAW_VERIFY="$ROOT/03-verify/raw"
BIN="$ROOT/bin"

# 재현성 고정 — scope.md 에 기록된 커밋
LLM_C_SHA="f1e2ace651495b74ae22d45d1723443fd00ecd3a"

# 아키텍처. 환경에 맞게 덮어쓸 것.
#   A100=sm_80  H100=sm_90   /   MI300X=gfx942
NV_ARCH="${NV_ARCH:-sm_80}"
AMD_ARCH="${AMD_ARCH:-gfx942}"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

# 소요 시간을 자동으로 남긴다 — logs/ 가 곧 산출물이므로 손으로 적지 않는다.
timed() {
    local label="$1"; shift
    local t0 t1 rc
    t0=$(date +%s)
    "$@"; rc=$?
    t1=$(date +%s)
    printf '%s\t%s\t%ss\trc=%d\n' \
        "$(date -Is)" "$label" "$((t1 - t0))" "$rc" >> "$ROOT/logs/auto-time.tsv"
    log "$label — $((t1 - t0))s (rc=$rc)"
    return $rc
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 을 찾을 수 없습니다. $2"; }

check_vendor() {
    [ -d "$VENDOR" ] || die "vendor/llm.c 가 없습니다. scripts/00_fetch_sources.sh 를 먼저 실행하세요."
    local sha
    sha="$(git -C "$ROOT/vendor/llm.c" rev-parse HEAD)"
    [ "$sha" = "$LLM_C_SHA" ] || warn "llm.c HEAD 불일치: $sha (기대: $LLM_C_SHA)"
}

mkdir -p "$ROOT/logs" "$OUT_HIPIFY" "$RAW_BASE" "$RAW_VERIFY" "$BIN"
