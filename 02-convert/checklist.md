# 02-convert — 변환 체크리스트

범위·리스크의 근거는 [scope.md](scope.md). 여기는 실행 중 체크하는 용도다.

## 절차 (전부 GPU 불필요)
1. `bash scripts/20_hipify.sh` — 원본은 절대 수정하지 않고 `hipify-out/` 으로만 출력
2. `bash scripts/21_build_hip.sh` — `hipcc --offload-arch=gfx942` 컴파일 시도
3. 에러 1건 = 로그 1줄 (아래 분류) → Claude 수정 → 재컴파일 반복
4. **전부 통과한 뒤에야** MI300X 를 켠다 (`scripts/30_verify_mi300x.sh`)

## 사전 조사로 확인된 이슈 (추정 아님 — 소스에서 확인됨)
걸리면 ✓ 와 소요 시간, 그리고 최종 태그를 적는다.

- [ ] **R1** `common.h:8` `#define WARP_SIZE 32U` → 웨이브64 (예상 `[MANUAL]`)
      ⚠ 컴파일도 통과하고 크래시도 안 난다. **정확도 검증만이 방어선**
- [ ] **R2** `cg::reduce` + `thread_block_tile<32>` (attention 9곳, softmax 2곳) (예상 `[MANUAL]`)
- [ ] **R3** `__shfl_*_sync(0xFFFFFFFF, ...)` 32비트 마스크 (총 7곳) (예상 `[LLM]`)
- [ ] **R4** softmax `:510-561` — 런타임 `warpSize` 와 32비트 마스크가 한 파일에 혼재
- [ ] **R5** cuBLASLt → hipBLASLt 매핑, 워크스페이스 32MiB 재검토 (예상 `[LLM]`)
- [ ] **R6** `cuda_bf16.h` / `CUDA_R_16BF` → hip_bf16 / hipBLASLt 데이터타입
- [ ] **R7** flash 커널의 divergent `__syncthreads()` — 원본 결함, 이식과 별개로 기록

## 아직 미확인 (변환 중 나올 수 있는 것)
- [ ] 공유 메모리 크기 상수 (LDS 64KB 초과 여부)
      ※ flash 커널은 32KB(`Kj`+`Vj`)로 여유 있음 — 이 파일은 해당 없음
- [ ] `__expf` 등 intrinsic 정확도/지연 차이
- [ ] 템플릿·매크로 안에 숨은 CUDA 심볼 (hipify 텍스트 치환의 사각지대)
- [ ] `#include "common.h"` 해석 — hipify 출력 헤더도 같은 이름으로 내보내 해결 중

## 에러 분류 태그 (logs/time-log.md 이슈 표에 기록)
- `[AUTO]`   hipify 가 자동 해결 (사람 개입 0)
- `[LLM]`    Claude 제안으로 해결 — **프롬프트 횟수와 시도 횟수를 반드시 적는다**
- `[MANUAL]` 사람 판단 필요 — 이유 한 줄. **이 목록이 보고서의 핵심이다**

> 태그를 관대하게 붙이면 지표가 무의미해진다. Claude가 두 번 이상 틀린 뒤
> 사람이 방향을 정해줬다면 `[LLM]` 이 아니라 `[MANUAL]` 이다.
