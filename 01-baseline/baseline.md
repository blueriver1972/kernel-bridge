# NVIDIA 기준선 (실측)

측정 완료: **2026-08-02 09:41 ~ 09:58 (약 17분)**
원시 로그: `01-baseline/raw/` · 재현: `LLMC_B=2 NV_ARCH=sm_52 bash scripts/10_baseline_nvidia.sh`

## 환경

| 항목 | 값 |
|---|---|
| GPU | **NVIDIA GeForce GTX 970** (Maxwell, 2014) |
| Compute capability | **sm_52** |
| VRAM | 4 GB |
| 드라이버 | 560.94 |
| CUDA | 12.6.85 |
| 실행 환경 | WSL2 (Ubuntu 22.04) · GPU 패스스루 |
| 컴파일 플래그 | `-O3 --use_fast_math -arch=sm_52 -Wno-deprecated-gpu-targets` |
| 정밀도 | **fp32 전 구간** |
| 문제 크기 | **B=2** (원본 B=8 에서 축소) |
| llm.c 커밋 | `f1e2ace6` |

### ⚠ 원본과 다른 두 가지 — MI300X 에도 반드시 맞출 것

**1. 정밀도: bf16 제거 → 전부 fp32**
`__nv_bfloat16` 은 sm_80 이상에서만 동작한다. sm_52 에서는 `ENABLE_BF16` 을 끄고
`common.h` 의 `#else` 분기(`floatX = float`)를 탄다.
그 과정에서 llm.c 의 fp32 경로가 **원래 불완전하다**는 것도 드러났다 —
`CUBLAS_LOWP` / `CUBLAS_LOWP_COMPUTE` 가 정의되지 않아 빌드 스크립트에서 `-D` 로 주입했다.
→ MI300X 는 `FP32_ONLY=1` 로 빌드해야 같은 조건이 된다.

**2. 문제 크기: B=8 → B=2**
GTX 970 은 Windows 디스플레이 드라이버 아래에 있어 **TDR** (2초 초과 커널 강제 종료)이 걸린다.
실측: **B=8 ✗ · B=4 ✗(27초 시점) · B=2 ✓**.
데이터센터 GPU 에는 없는 제약이므로 A100/H100 재측정 시에는 원본 B=8 로 돌린다.
→ MI300X 도 `LLMC_B=2` 로 맞춰야 비교가 성립한다.

**3. TF32: 해당 없음**
sm_52 에는 TF32 하드웨어가 없다. 따라서 이번 기준선은 **자동으로 fp32 대 fp32** 다.
(A100/H100 으로 재측정할 때는 TF32 가 자동 활성되므로 fp32 강제본이 필요하다 — 스크립트가 처리한다.)

---

## 정확도 — **전 항목 PASS**

llm.c 내장 `validate_result` (tolerance 1e-4 + 상대 epsilon) 기준.
불일치 시 `Mismatch...` 출력 후 `exit(EXIT_FAILURE)` 하는데,
**어느 로그에도 없고 15개 실행 전부 종료코드 0** 이다.

| 대상 | 커널 수 | 결과 |
|---|---|---|
| softmax_forward | 8 | **8/8 PASS** |
| attention_forward | 6 | **6/6 PASS** |
| flash_attention (자체) | 1 | **PASS** |
| **합계** | **15** | **15/15 PASS** |

---

## softmax_forward.cu

각 커널을 block_size 6종(32~1024)으로 측정한 것 중 **최적값**.

| 커널 | 정확도 | 최적 ms | 최적 block_size | 비고 |
|---|---|---|---|---|
| 1 | PASS | 200.7065 | 32 | naive |
| 2 | PASS | 17.9553 | 1024 | |
| 3 | PASS | 20.9604 | 512 | warp reduction |
| 4 | PASS | 17.8370 | 1024 | |
| 5 | PASS | 125.9372 | 256 | |
| 6 | PASS | 9.9423 | 32 | |
| 7 | PASS | 14.7640 | 1024 | |
| 8 | PASS | **9.8594** | 32 | **최속** |

## attention_forward.cu

block_size 5종으로 측정. 커널 10·11(cuDNN)은 `ENABLE_CUDNN` 미정의로 빌드 제외.

| 커널 | 정확도 | 최적 ms | 최적 block_size | 비고 |
|---|---|---|---|---|
| 1 | PASS | 497.6454 | 32 | naive |
| 2 | PASS | 480.0159 | 512 | flash (minimal) |
| 3 | PASS | 7.3089 | 128 | cuBLAS + softmax |
| 4 | PASS | 4.5708 | 32 | online softmax |
| 5 | PASS | 4.5586 | 32 | 원래 FP16 → 여기서는 fp32 |
| 6 | PASS | **4.2105** | 32 | **최속** · 5 + permute 생략 |

> 커널 5·6 은 원본에서 저정밀 경로다. 이번 측정은 fp32 로 강제됐으므로
> **"FP16 버전"이 아니라 "커널 4의 변형"으로 읽어야 한다.**

## flash_attention_simplified.cu (자체 커널)

자체 하네스(`00-src/flash_attention_test.cu`) — CPU 레퍼런스 double 누적, 결정적 난수.

| N | d | 정확도 | max_rel_err | max_abs_err | ms | GFLOP/s |
|---|---|---|---|---|---|---|
| 1024 | 64 | **PASS** | 1.721e-06 | 1.355e-07 | 0.9941 | 270.0 |

`__expf` 등 fast-math intrinsic 을 쓰고도 상대오차 1.7e-06 — 허용치(1e-3) 대비 충분한 여유.

---

## 이 기준선의 용도 — 반드시 지킬 것

✅ **쓸 수 있는 것: 정확도 기준선.**
"NVIDIA 에서 원본이 올바르게 돈다"가 실측으로 확보됐다.
MI300X 결과가 맞는지 판정할 근거는 이것이다.

❌ **쓰면 안 되는 것: 성능 비교 헤드라인.**
GTX 970 은 2014년 게이밍 카드(~3.5 TFLOPS fp32, 224 GB/s)이고
MI300X 는 데이터센터 칩(~163 TFLOPS, 5.3 TB/s)이다. 24~47배 격차는
**이식 품질이 아니라 하드웨어 세대 차이**다. 이 숫자로 "MI300X 가 N배 빠르다"를
발표하면 보고서 신뢰도가 무너진다.

**→ 2026-08-03 결정: 성능 비교를 아예 하지 않는다.**
동급 NVIDIA(H100/H200) 재측정은 **비용 대비 얻는 것이 없어 접었다.**
이 프로젝트가 증명하는 것은 "AMD 가 빠르다"가 아니라
**"이식이 맞는지 자동으로 검증된다"** 이며, 그 목적에는 이 기준선으로 충분하다.
실제로 MI300X 도 **15/15 PASS** 로 이 기준선과 일치했다 → [03-verify/verify.md](../03-verify/verify.md)

측정된 시간은 `03-verify/comparison.md` 에 기록 보존용으로만 남긴다.

> 훗날 성능 비교가 필요해지면 스크립트에 `NV_ARCH=sm_80`(A100) 또는 `sm_90`(H100) 만
> 주면 bf16·TF32 두 벌 측정으로 자동 전환된다. 코드는 이미 준비돼 있다.
