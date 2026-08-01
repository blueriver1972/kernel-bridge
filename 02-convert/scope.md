# 변환 범위 확정 (Phase 0 사전 조사 결과)

조사 일자: 2026-08-01
llm.c 커밋: `f1e2ace651495b74ae22d45d1723443fd00ecd3a` (2025-05-10, master)
※ 재현 시 반드시 이 SHA 로 체크아웃할 것. `vendor/` 는 커밋하지 않는다.

---

## 1. 변환 대상 (확정)

| # | 파일 | 라인 | 하네스 | 비고 |
|---|---|---|---|---|
| 1 | `vendor/llm.c/dev/cuda/softmax_forward.cu` | 732 | 내장 (`validate_result` tol=1e-4, `benchmark_kernel`) | **최우선** — warp 가정이 가장 많음 |
| 2 | `vendor/llm.c/dev/cuda/attention_forward.cu` | 1390 | 내장 (동일) | cuBLAS/cuBLASLt + cg::reduce |
| 3 | `00-src/flash_attention_simplified.cu` | 172 | `00-src/flash_attention_test.cu` (신규 작성) | 자체 커널, 데모용 |
|   | `vendor/llm.c/dev/cuda/common.h` (공통 의존) | 384 | — | 1·2가 함께 끌고 옴 |

합계 **2,294라인** (+ 공통 헤더 384라인).

### 순서 변경 근거
당초 계획은 attention → softmax → flash 순이었으나 **softmax_forward.cu 를 먼저** 한다.
flash 파일은 warp intrinsic / cuBLAS / cooperative_groups 를 하나도 쓰지 않아
거의 자동 변환된다 — 이것부터 하면 "자동화율 95%" 같은 과대평가 지표가 나온다.
지표의 신뢰도는 어려운 파일을 먼저 측정할 때 확보된다.
flash 파일은 **데모에서 성공 장면을 보여주는 용도**로 마지막에 배치.

### 제외 결정
- `attention_forward.cu` 커널 10·11 (cuDNN Flash Attention): 소스 47행이
  `//#define ENABLE_CUDNN` 로 **기본 비활성**이며 `-DENABLE_CUDNN` 없이 컴파일하면
  `#ifdef` 로 자동 배제된다. cuDNN 은 ROCm 에 1:1 대응이 없어(MIOpen 은 API가 다름)
  변환이 아니라 재작성 대상이므로 이번 범위에서 뺀다.
  → 이 사실 자체가 보고서의 "사람이 필요한 구간" 항목이다.
- 대상 커널: attention 1~6, softmax 1~8 (파일 내 전체).

---

## 2. 확인된 이식 리스크 (추정 아님 — 실제 소스에서 확인)

### 🔴 R1. `WARP_SIZE` 32 하드코딩 — 조용히 틀린 답이 나오는 유형
`common.h:8` `#define WARP_SIZE 32U`, `common.h:33` `__shared__ float shared_val[WARP_SIZE]`,
`common.h:34-36` `threadIdx.x % / WARP_SIZE`, `blockDim.x / WARP_SIZE`.

hipify 는 매크로 상수 `32` 를 바꾸지 않는다. AMD 웨이브프런트는 64이므로
리덕션이 64레인 중 32레인만 집계하고 **컴파일도 통과하고 크래시도 안 난다.**
`validate_result` 가 잡아주는 것이 유일한 방어선. → 예상 태그 `[MANUAL]`

### 🔴 R2. `cg::reduce` + `thread_block_tile<32>`
`attention_forward.cu:350,385,388,623,644,659,905,939,942`
`softmax_forward.cu:358,378`
`#include <cooperative_groups/reduce.h>` 의존.

ROCm 의 cooperative_groups 는 `tiled_partition` 은 있으나 `cg::reduce` 와
`cg::plus/greater` 펑터 지원 범위가 CUDA 와 다르다. 타일 크기 `<32>` 도 웨이브64와 충돌.
컴파일 단계에서 터질 가능성이 높다. → 예상 태그 `[MANUAL]` (재작성)

### 🟠 R3. `__shfl_*_sync` 의 32비트 마스크
`attention_forward.cu:238`, `softmax_forward.cu:178,198,545,546,558,559`
전부 `0xFFFFFFFF`. 웨이브64에서는 64비트 마스크가 필요하다.
hipify 는 `__shfl_down_sync` → `__shfl_down` 으로 마스크를 **떨어뜨리는** 경우가 있어
의미가 조용히 바뀐다. → 예상 태그 `[LLM]` 또는 `[MANUAL]`

### 🟠 R4. 같은 파일 안에 가정이 섞여 있음
`softmax_forward.cu:510-561` 은 런타임 `warpSize` 를 쓰고(이식 가능),
같은 루프의 마스크는 `0xFFFFFFFF` 로 32비트 고정이다.
"일관되게 32을 가정한 코드"가 아니라 **부분적으로만 이식 가능한 코드**라서
일괄 치환이 통하지 않는다. 변환 도구의 한계를 보여주는 좋은 사례.

### 🟠 R5. cuBLASLt
`common.h:5,88,298` — hipBLASLt 는 MI300X 를 지원하지만 API 가 1:1이 아니다.
워크스페이스 크기(`common.h:84`, 32MiB)도 재검토 대상. → 예상 태그 `[LLM]`

### 🟡 R6. BF16 경로
`attention_forward.cu:56` `#define ENABLE_BF16`, `<cuda_bf16.h>`,
`common.h:188` `CUBLAS_LOWP = CUDA_R_16BF`. → `hip_bf16.h` / hipBLASLt 데이터타입 매핑.

### 🟡 R7. flash 커널 — divergent `__syncthreads()`
`00-src/flash_attention_simplified.cu:51` 의 `if (row >= N) return;` 이후
`:88`, `:133` 에서 `__syncthreads()` 호출. 블록 일부 스레드만 배리어에 도달하는
정의되지 않은 동작이며, NVIDIA 에서 우연히 통과해도 AMD 에서 같으리란 보장이 없다.
현재는 하네스가 `N % 64 != 0` 을 거부해 회피 중. → 이식과 무관한 **원본 결함**으로 별도 기록.

---

## 3. 🔴 측정 방법론: TF32 (반드시 처리)

`common.h:302-307`, `attention_forward.cu:1287-1290`
```c
int enable_tf32 = deviceProp.major >= 8 ? 1 : 0;   // A100/H100 이면 자동 ON
cublas_compute_type = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;
```

A100/H100 에서는 **아무 설정 없이 TF32 텐서코어 경로가 켜진다.** 이 상태의 ms 를
MI300X 의 fp32 ms 와 나란히 놓으면 하드웨어 차이가 아니라 **연산 정밀도 차이**를
성능 격차로 발표하게 된다. `common.h:304` 에 주석 처리된 `override_enable_tf32` 훅이 있다.

**측정 규칙 — NVIDIA 에서 두 번 잰다:**

| 조건 | 용도 |
|---|---|
| `enable_tf32 = 0` (강제 fp32) | **비교표의 기준값.** MI300X fp32 와 동일 정밀도 |
| `enable_tf32 = 1` (기본값) | 참고값. "실전 NVIDIA 설정" 으로 각주에만 표기 |

두 값 모두 `baseline.md` 에 기록하고, 보고서 헤드라인의 "NVIDIA 대비 %" 는
**fp32 대 fp32** 숫자만 사용한다. 프로그램이 `enable_tf32: %d` 를 출력하므로
로그에 증거가 남는다.

부가: `--use_fast_math` 도 양쪽 컴파일 플래그를 동일하게 맞춘다.

---

## 4. 다음 단계에서 결정해야 할 것

- [x] NVIDIA 비교 GPU 확정 → **A100 (sm_80)**. 2026-08-01 결정.
      H100 대비 저렴하면서 데이터센터급이라 MI300X 와의 대비가 성립한다 (4090 이었다면 성립 안 함).
      A100 은 compute capability 8.0 이므로 **§3 의 TF32 자동 활성 조건에 그대로 해당한다.**
      fp32 강제 측정을 생략할 수 없다.
- [ ] `hipify-perl` vs `hipify-clang` — perl 은 텍스트 치환이라 R1 을 못 잡고,
      clang 은 AST 기반이라 더 잡지만 빌드 환경 요구가 크다.
      **계획대로 perl 로 시작**하되 못 잡은 항목을 로그에 남기는 것이 오히려 지표가 된다.
