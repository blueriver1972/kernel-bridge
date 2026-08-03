# MI300X 검증 결과 (실측)

측정: **2026-08-03** · AMD Developer Cloud (devcloud.amd.com, DigitalOcean 인프라)
원시 로그: `03-verify/raw/` · 세션 스크립트: `scripts/50_pod_session.sh`

## 환경

| 항목 | 값 |
|---|---|
| GPU | **AMD Instinct MI300X VF** |
| GFX | **gfx942** (CDNA3) |
| `major.minor` / `warpSize` | 9.4 / **64** |
| ROCm | **7.0.2** (HIP 7.14.60850, clang 23.0.0git) |
| 드라이버 | 6.19.14.31400000 |
| 컴파일 플래그 | `-O3 -ffast-math --offload-arch=gfx942 -I/opt/rocm/include` |
| 정밀도 | **fp32 전 구간** (`FP32_ONLY=1`) |
| 문제 크기 | **B=2** (기준선과 동일) |
| 비용 | $1.99/시간 · 총 세션 약 40분 |

---

## 정확도 — **15/15 PASS**

| 대상 | 커널 | 결과 |
|---|---|---|
| softmax_forward | 8 | **8/8 PASS** |
| attention_forward | 6 | **6/6 PASS** |
| flash_attention (자체) | 1 | **PASS** |
| **합계** | **15** | **15/15 PASS** |

NVIDIA 기준선(15/15)과 **동일**하다.

### flash 커널 — 두 플랫폼 직접 대조

| | NVIDIA GTX 970 | **MI300X** |
|---|---|---|
| 판정 | PASS | **PASS** |
| max_rel_err | 1.721e-06 | 1.815e-06 |
| max_abs_err | 1.355e-07 | 1.430e-07 |

**출력 덤프를 직접 비교한 결과:**
```
최대 절대오차 : 2.980e-08
최대 상대오차 : 3.783e-07
판정          : 동일 — 차이 이미지가 검정
```
→ `report/demo-images/real/compare.png` (왼쪽 NVIDIA · 가운데 MI300X · 오른쪽 차이=검정)

입력은 결정적 난수(xorshift32)로 두 플랫폼에서 비트 단위 동일하게 고정했다.

---

## ⚠ 여기까지 오는 데 8건이 더 필요했다

Phase 2(컴파일)에서 11건을 해결했지만, **실제 MI300X 에서 8건이 더 나왔다.**
컴파일이 통과했다는 것이 동작을 뜻하지 않는다는 실증이다.

### A. ROCm 버전 차이 (4건) — 6.3 에서 되던 것이 7.0.2 에서 깨짐

| # | 증상 | 원인 |
|---|---|---|
| 12 | `hip/hip_runtime.h` not found — 3개 전부 빌드 실패 | 이미지 레이아웃 어긋남. `hipcc`·`hipconfig` 가 `core-7.14/include` 를 가리키는데 헤더는 `/opt/rocm/include` 에 있다 |
| 13 | `redefinition of '__syncwarp'` | **7.x 가 직접 제공**. 6.3 에 없어서 우리가 채운 것이 충돌 |
| 14 | `memset` 이 `__device__` 로 해석 | 7.x 가 전역에 `__device__ memset` 추가 → 호스트에서 부르면 깨짐 |
| 15 | `hipblasGemmStridedBatchedEx_v2` 없음 | **7.x 에서 제거**, 접미사 없는 이름으로 통합 (시그니처 동일) |

> **"NVIDIA → AMD" 가 끝이 아니라 "AMD 버전 간" 이식이 또 있다.**
> 13번은 없어서 채웠더니 중복이 됐고, 15번은 있던 API 가 사라졌다 — 방향이 양쪽이다.
> 고객 입장에서는 ROCm 을 올릴 때마다 다시 깨진다는 뜻이다.

### B. ★ 조용히 틀리는 구간 (4건) — 컴파일러가 침묵

| # | 증상 | 어디 |
|---|---|---|
| 16 | `max(float,float)` 가 `int max(int,int)` 로 해석 | **호스트** |
| 17 | CUDA 컴퓨트 능력 검사가 AMD 로 누출 (TF32) | **호스트**, 2곳 |
| 18 | 커널8 `warpsPerBlock = blockDim.x / warpSize` = 0 | 디바이스 |
| 19 | 커널8 `grid = ceil_div(N * 32, block_size)` | **호스트** |

**#16 — 이번 프로젝트에서 가장 좋은 사례**
```c
max_el = max(max_el, out[i]);      // 호스트 코드
```
HIP 호스트에는 `int max(int,int)` 만 보인다. float 가 int 로 변환되고 `-inf` 는 UB 라
쓰레기값(905987520)이 나온다. CUDA 는 호스트에도 float 오버로드가 있어 원본은 정상이다.
실측: 호스트 `is_int=1` / 디바이스 `max(0.5f,0.25f)=0.5` (디바이스는 정상).

| | |
|---|---|
| 컴파일 | 통과 (경고 한 줄: `argument has type 'int'`) |
| 실행 | 크래시 없음 |
| 결과 | 쓰레기값 |
| 발견 | **원본에 우연히 있던 `assert` 가 유일한 방어선** |

**#17 — CUDA 개념이 AMD 로 새어들어옴**
```c
int enable_tf32 = deviceProp.major >= 8 ? 1 : 0;   // MI300X: major=9 → true!
```
`major` 는 NVIDIA compute capability 개념인데 MI300X 가 9 로 읽혀 조건을 통과한다.
AMD 에 없는 TF32 를 켜려 해 `hipblasSetMathMode` 가 `NOT_SUPPORTED(7)` 를 반환하고
**attention 6개가 전부 시작조차 못 했다.** `common.h` 와 `attention_forward.cu` **두 곳**에 있었다.
(실측: `DEFAULT_MATH → 0` 정상 / `TF32_TENSOR_OP_MATH → 7`)

**#18·#19 — 커널 8: 웨이브 폭 가정이 디바이스·호스트 양쪽에**
```c
// 디바이스
const int warpsPerBlock = blockDim.x / warpSize;   // NVIDIA 32/32=1 · AMD 32/64=0
int row = blockIdx.x * warpsPerBlock + warpId;     // AMD 에서 전부 0
// 호스트
const int grid_size = ceil_div(N * 32, block_size); // "행 하나당 32스레드" 전제
```
둘 중 하나만 고치면 여전히 틀린다. 실제로 첫 수정 후에도 `block_size=64` 에서 실패했다.

### ★★ 일괄 치환이 불가능한 이유 — 가장 명확한 증거

같은 파일, 글자까지 동일한 두 줄인데 **한쪽은 맞고 한쪽은 틀리다.**

```c
void softmax_forward_online2(...) {                     // 커널 6
    const int grid_size = ceil_div(N * 32, block_size);  // ✅ 옳다
}   // 커널 안: cg::tiled_partition<32>  ← 32레인 타일을 명시

void softmax_forward_online8(...) {                     // 커널 8
    const int grid_size = ceil_div(N * 32, block_size);  // ❌ 64 여야 한다
}   // 커널 안: blockDim.x / warpSize   ← 런타임 값 사용
```

어느 쪽이 틀렸는지는 **각 커널이 스레드를 어떻게 배치하는지 읽어야만** 알 수 있다.

---

## 성능 — 이 표를 헤드라인에 쓰지 않는다

`03-verify/comparison.md` 에 표가 있으나 **현재 기준선이 GTX 970(2014)이라 발표 불가**다.

| 대상 | 커널 | GTX 970 ms | MI300X ms | 실제 배속 |
|---|---|---|---|---|
| softmax | 8 (최속) | 9.8594 | **1.5723** | 6.27x |
| attention | 6 (최속) | 4.2105 | **0.8228** | 5.12x |
| flash | — | **0.9941** | 2.7174 | **0.37x** ⚠ |

### 두 가지 주의

**1. 효율이 낮게 나오는 건 워크로드가 작기 때문일 수 있다**
대역폭 비로 계산한 기대 배속은 23.66x 인데 실제는 3~8x 다(효율 0.08~0.36).
**B=2 는 MI300X(304 CU)를 채우기엔 너무 작다** — 970(13 SM)은 포화되고 MI300X 는 놀고 있다.
이식 품질 판정으로 읽으면 안 된다. 원본 B=8 재측정 결과를 봐야 한다.

**2. flash 커널은 MI300X 에서 더 느리다 (0.37x)**
이 커널은 블록 16개 × 64스레드 = **1024 스레드**만 띄운다. 304 CU 를 쓸 방법이 없다.
"작은 커널은 큰 GPU 에서 오히려 느리다"의 교과서적 사례이며, **커널 자체를 재설계해야**
MI300X 를 활용할 수 있다 — 이식으로 해결되는 문제가 아니다.

---

## rocprof

`03-verify/raw/rocprof_attention.*` 에 수집됨 (csv · json · stats · sysinfo).

---

## 조건 일치 확인

- [x] 정밀도 — 양쪽 fp32 (`FP32_ONLY=1`, TF32 없음, bf16 제외)
- [x] 문제 크기 — 양쪽 B=2
- [x] llm.c 커밋 — `f1e2ace6` 동일
- [x] 최적화 플래그 — `-O3` + fast-math 동일
- [ ] **동급 하드웨어 — 미충족.** 성능 비교는 H100/H200 재측정 후에만 발표한다
