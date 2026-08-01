# NVIDIA 기준선 (실측)

> 채우는 법: `scripts/10_baseline_nvidia.sh` 실행 후 `01-baseline/raw/*.log` 에서 옮긴다.
> **실측값 없는 칸은 비워 둔다. 추정치를 쓰지 않는다.**

## 환경 (raw/env.txt 에서)

| 항목 | 값 |
|---|---|
| GPU | |
| 드라이버 | |
| CUDA 버전 | |
| nvcc arch | |
| 컴파일 플래그 | `-O3 --use_fast_math -arch=___ -lcublas -lcublasLt` |
| 측정 일시 | |

## softmax_forward.cu

정확도는 `validate_result` (tol 1e-4) 출력 기준. 시간은 `benchmark_kernel` ms.

| 커널 # | 정확도 | ms (fp32) | ms (TF32) | 비고 |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |

## attention_forward.cu

| 커널 # | 정확도 | ms (fp32) | ms (TF32) | 비고 |
|---|---|---|---|---|
| 1 | | | | naive |
| 2 | | | | flash (minimal) |
| 3 | | | | cuBLAS + softmax |
| 4 | | | | online softmax |
| 5 | | | | FP16/BF16 |
| 6 | | | | 5 + permute 생략 |

커널 10·11(cuDNN)은 `ENABLE_CUDNN` 미정의로 빌드에서 제외 — scope.md §1 참조.

## flash_attention_simplified.cu

`[RESULT]` 한 줄에서 그대로 옮긴다.

| N | 정확도 | max_rel_err | ms | GFLOP/s |
|---|---|---|---|---|
| 1024 | | | | |

---

## ⚠ TF32 각주 (반드시 함께 실린다)

llm.c 는 compute capability 8.0 이상에서 cuBLAS TF32 텐서코어 경로를 **자동으로 켠다**
(`common.h:302`, `attention_forward.cu:1287`). 프로그램이 `enable_tf32: 0|1` 을 출력한다.

- **비교표 기준값 = fp32 열.** MI300X 와 동일 정밀도이므로 이 값만 "NVIDIA 대비 %" 에 쓴다.
- TF32 열은 "실전 NVIDIA 설정에서의 성능" 참고값이며 각주로만 인용한다.

측정된 `enable_tf32` 값:
- fp32 빌드: `enable_tf32: ___` (0이어야 정상)
- 기본 빌드: `enable_tf32: ___`
