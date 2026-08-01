#!/usr/bin/env bash
# Phase 0 — llm.c 소스 확보 (GPU 불필요)
# vendor/ 는 커밋하지 않는다. 재현성은 커밋 SHA 로만 보장한다.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need git "git 을 설치하세요."

if [ -d "$ROOT/vendor/llm.c/.git" ]; then
    log "vendor/llm.c 이미 존재 — SHA 확인만 합니다."
else
    log "llm.c 얕은 클론 (dev/cuda 만)"
    git clone --depth 1 --filter=blob:none --no-checkout \
        https://github.com/karpathy/llm.c.git "$ROOT/vendor/llm.c"
    git -C "$ROOT/vendor/llm.c" sparse-checkout set --no-cone dev/cuda
    git -C "$ROOT/vendor/llm.c" checkout
fi

check_vendor
ls -la "$VENDOR"/{attention_forward.cu,softmax_forward.cu,common.h}
log "완료. 대상 파일 확인됨."
