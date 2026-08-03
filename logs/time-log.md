# 시간 기록 — "사람 개입 X시간"의 원료

스크립트가 도는 시간은 `logs/auto-time.tsv` 에 자동으로 쌓인다.
이 표에는 **사람이 판단하며 보낸 시간**을 적는다. 스크립트는 그걸 모른다.

| 일시 | 작업 | 소요(분) | 분류(환경/변환/디버깅/검증/문서) | 메모 |
|---|---|---|---|---|
| 2026-08-01 | 계획 검토 · 작업 방향 분석 | | 문서 | 하네스 부재 · GPU 과금 경계 · TF32 · 파일 순서 4건 도출 |
| 2026-08-01 | Phase 0 — git init · 구조 재편 (`00-src`, `scripts`) | | 환경 | 중첩 폴더 평탄화 포함 |
| 2026-08-01 | Phase 0 — flash 정확도/타이밍 하네스 작성 | | 검증 | `00-src/flash_attention_test.cu`, CPU 레퍼런스 double 누적 |
| 2026-08-01 | Phase 0 — llm.c 소스 조사 · 변환 범위 확정 | | 변환 | `02-convert/scope.md`, 리스크 R1~R7 실측 확인 |
| 2026-08-01 | Phase 0 — 단계별 스크립트 작성 | | 환경 | GPU 필요/불필요 분리가 목적 |
| 2026-08-02 | WSL2 설치 (커널 무한 대기 → `--web-download` 우회) | | 환경 | `wsl --update` 가 0.0% 에서 17분 정지 |
| 2026-08-02 | C: 디스크 부족 → WSL 을 D:\wsl 로 이동 | | 환경 | ext4 emergency read-only 복구. C: 0.5→5.4GB |
| 2026-08-02 | ROCm 6.2 링커 SEGV 진단 → 6.3 으로 교체 | | 환경 | 아래 E1 참조. **가장 오래 걸린 환경 문제** |
| 2026-08-02 | Phase 2 — hipify 실행 | | 변환 | 5파일 전부 변환. 잔여 32 가정 30곳 검출 |
| 2026-08-02 | Phase 2 — 컴파일 수정 루프 (5회차에 전부 통과) | | 디버깅 | 이슈 #1~#11 |
| 2026-08-02 | WSL 안에 CUDA 12.6 설치 (GPU 패스스루) | | 환경 | Windows 설치 불필요 |
| 2026-08-02 | TDR 보정 — 문제 크기 B 탐색 | | 검증 | B=8·4 실패, B=2 통과 |
| 2026-08-02 | **Phase 1 기준선 측정 (GTX 970)** | 17 | 검증 | 15/15 PASS. 스크립트 자동 실행 |
| 2026-08-02 | 데모 이미지 도구 작성 · 버그 주입 대조군 검증 | | 문서 | 차이 패널을 데이터 범위가 아니라 **허용오차**로 정규화 |
| 2026-08-02 | 공개 저장소 게시 · 포드 세션 스크립트 리허설 | | 환경 | 리허설에서 스크립트 버그 4건 발견 (아래 E7) |
| 2026-08-03 | 클라우드 확보 시도 (여러 업체 마찰) | | 환경 | 최종적으로 AMD Developer Cloud (DigitalOcean 인프라) |
| 2026-08-03 | **Phase 3 — MI300X 실행 + 런타임 이슈 8건 수정** | | 디버깅 | 이슈 #12~#19. ROCm 7.0.2 |
| 2026-08-03 | **Phase 3 재측정 (녹화용 2회차)** | | 검증 | 같은 값 재현 확인 (`1.815e-06` / `98.8 GFLOP/s`) |
| 2026-08-03 | 두 플랫폼 출력 대조 이미지 생성 | | 검증 | 최대 상대오차 3.783e-07, 차이 패널 검정 |
| 2026-08-03 | 문서 갱신 (summary · README · RUNBOOK · verify) | | 문서 | 성능 비교를 "범위 밖"으로 확정 |
| | | | | |

> 소요(분) 칸은 실제 걸린 시간으로 채운다. 비워둔 채로 보고서에 숫자를 쓰지 않는다.

---

# 이슈 로그 — 총 19건

에러 1건 = 1줄.

**★ 분류 기준은 난이도가 아니라 "루프에 신호가 있는가" 다.**
19건 **전부 LLM(Claude)이 고쳤다.** 사람이 손으로 고쳐야 하는 건 없었다.
자동화가 멈추는 지점은 어려운 곳이 아니라 **아무도 틀렸다고 알려주지 않는 곳**이다.

| 신호 | 뜻 | 루프가 도는가 |
|---|---|---|
| `컴파일` | 컴파일러가 파일·줄·증상을 알려준다 | ✅ 고치고 재컴파일하면 즉시 판정 |
| `런타임` | 실행 중 에러 코드나 예외가 난다 | ✅ 판정 가능 |
| **`없음`** | **컴파일 통과 · 크래시 없음 · 답만 틀림** | ❌ **정답 대조 장치가 있어야 시작됨** |

## Phase 2 — 컴파일 단계 (11건, ROCm 6.3, 5회차에 전부 통과)

| # | 파일 | 에러 요약 | 신호 | 문법치환 가능 | 회차 |
|---|---|---|---|---|---|
| 1 | flash | `rsqrtf` 가 HIP 에선 `__device__` 전용 — 호스트 호출 불가 | 컴파일 | 예 | 1 |
| 2 | (환경) | 이미지에 hipBLAS 미설치 (`hipblas.h` 없음) | 컴파일 | — | 1 |
| 3 | common.h · attention | hipify 가 ROCm 5.x 평면 경로(`<hipblas.h>`)를 생성. 6.x 는 `<hipblas/hipblas.h>` | 컴파일 | 예 | 2 |
| 4 | softmax · attention | `cooperative_groups/reduce.h` 및 `cg::reduce` 자체가 HIP 에 **없음** | 컴파일 | **아니오** | 2 |
| 5 | common.h · softmax · attention | `__shfl_*_sync` 8곳을 hipify 가 **전혀 변환하지 않음**. 폭(32 vs 64) 결정 필요 | 컴파일 | **아니오** | 3 |
| 6 | softmax | `__syncwarp()` 부재 | 컴파일 | 예 | 3 |
| 7 | common.h · softmax · attention | `__stcs` 전무, `__ldcs` 오버로드 부족 (float/int4/bf16) | 컴파일 | 예 | 3 |
| 8 | softmax | `min(int, unsigned)` 결과가 정수가 아니라 배열 첨자로 못 씀 (4곳) | 컴파일 | 예 | 3 |
| 9 | common.h | 호스트 `isfinite` 오버로드 모호 | 컴파일 | 예 | 3 |
| 10 | attention | `<cuda_bf16.h>` 를 hipify 가 변환하지 못함 (R6) | 컴파일 | 예 | 3 |
| 11 | common.h | `__CUDACC_VER_MAJOR__` 가드 때문에 bf16 `__ldcs`/`__stcs` 정의가 **통째로 비활성** | 컴파일 | **아니오** | 4 |

## Phase 3 — MI300X 실행 단계 (8건, ROCm 7.0.2)

**컴파일이 통과했다는 것이 동작을 뜻하지 않는다는 실증이다.**

### A. ROCm 버전 차이 (4건) — 6.3 에서 되던 것이 7.0.2 에서 깨짐

| # | 증상 | 원인 | 신호 |
|---|---|---|---|
| 12 | `hip/hip_runtime.h` not found — 3개 전부 빌드 실패 | 이미지 레이아웃 어긋남. `hipcc`·`hipconfig` 가 `core-7.14/include` 를 가리키는데 헤더는 `/opt/rocm/include` 에 있다 | 컴파일 |
| 13 | `redefinition of '__syncwarp'` | **7.x 가 직접 제공.** 6.3 에 없어서 우리가 채운 것이 충돌 | 컴파일 |
| 14 | `memset` 이 `__device__` 로 해석 | 7.x 가 전역에 `__device__ memset` 추가 → 호스트에서 부르면 깨짐 | 컴파일 |
| 15 | `hipblasGemmStridedBatchedEx_v2` 없음 | **7.x 에서 제거**, 접미사 없는 이름으로 통합 (시그니처 동일) | 컴파일 |

> **"NVIDIA → AMD" 가 끝이 아니라 "AMD 버전 간" 이식이 또 있다.**
> #13 은 없어서 채웠더니 중복이 됐고, #15 는 있던 API 가 사라졌다 — 방향이 양쪽이다.
> 고객 입장에서는 **ROCm 을 올릴 때마다 다시 깨진다**는 뜻이다.

### B. ★ 신호가 약하거나 없는 구간 (4건)

| # | 증상 | 어디 | 신호 |
|---|---|---|---|
| 16 | `max(float,float)` 가 `int max(int,int)` 로 해석 | **호스트** | **없음** (경고 한 줄) |
| 17 | CUDA 컴퓨트 능력 검사가 AMD 로 누출 (TF32) | **호스트**, 2곳 | 런타임 (`NOT_SUPPORTED(7)`) |
| 18 | 커널8 `warpsPerBlock = blockDim.x / warpSize` = 0 | 디바이스 | **없음** |
| 19 | 커널8 `grid = ceil_div(N * 32, block_size)` | **호스트** | **없음** |

**#16 — 이번 프로젝트에서 가장 좋은 사례**
```c
max_el = max(max_el, out[i]);      // 호스트 코드
```
HIP 호스트에는 `int max(int,int)` 만 보인다. float 가 int 로 변환되고 `-inf` 는 UB 라
쓰레기값(905987520)이 나온다. CUDA 는 호스트에도 float 오버로드가 있어 **원본은 정상이다.**
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
const int warpsPerBlock = blockDim.x / warpSize;    // NVIDIA 32/32=1 · AMD 32/64=0
int row = blockIdx.x * warpsPerBlock + warpId;      // AMD 에서 전부 0
// 호스트
const int grid_size = ceil_div(N * 32, block_size); // "행 하나당 32스레드" 전제
```
**둘 중 하나만 고치면 여전히 틀린다.** 실제로 첫 수정 후에도 `block_size=64` 에서 실패했다.

---

## 집계

| 구분 | 건수 |
|---|---|
| 컴파일 에러 (신호 있음) | **15** |
| 런타임 에러 코드 (신호 있음) | **1** |
| **★ 신호 없음 — 조용히 틀림** | **3** |
| **합계** | **19** |

문법 치환으로 도달 불가한 것: **#4 · #5 · #11 · #16 · #18 · #19 (6건)**
그중 신호까지 없는 것: **#16 · #18 · #19 (3건)** ← **여기가 제품의 자리**

### `[AUTO]` — hipify 가 자동 해결한 양
`02-convert/hipify-stats.txt` 기준 치환 라인 수:

| 파일 | 자동 변환 |
|---|---|
| common.h | 46 |
| softmax_forward.cu | 14 |
| attention_forward.cu | 68 |
| flash_attention_simplified.cu | 6 |
| flash_attention_test.cu | 30 |
| **합계** | **164** |

### 사람/LLM 이 실제로 쓴 코드
| 항목 | 규모 |
|---|---|
| 변환 산출물 수정 (Phase 2) | **51 insert / 27 delete** (주석 포함, 4파일) |
| 신규 호환 계층 | `cg_reduce_compat.h` 73줄 + `hip_intrinsics_compat.h` 61줄 = **134줄** |
| Phase 3 추가 수정 | 8건 (호환 계층 가드 · 웨이브 폭 · TF32 · `fmaxf`) |

### ★★ 일괄 치환이 불가능한 이유 — 가장 명확한 증거

같은 파일, **글자까지 동일한 두 줄**인데 한쪽은 맞고 한쪽은 틀리다.

```c
void softmax_forward_online2(...) {                      // 커널 6
    const int grid_size = ceil_div(N * 32, block_size);  // ✅ 옳다
}   // 커널 안: cg::tiled_partition<32>  ← 32레인 타일을 명시

void softmax_forward_online8(...) {                      // 커널 8
    const int grid_size = ceil_div(N * 32, block_size);  // ❌ 64 여야 한다
}   // 커널 안: blockDim.x / warpSize   ← 런타임 값 사용
```

어느 쪽이 틀렸는지는 **각 커널이 스레드를 어떻게 배치하는지 읽어야만** 알 수 있다.
`sed` 로 일괄 처리하면 **맞는 쪽을 망가뜨린다.**

### R1 의 결말 (Phase 2 에서 미결로 남겼던 항목)

**R1 `#define WARP_SIZE 32U`** (common.h:9) — 32레인 그룹 전제를 유지하는 방향으로
폭을 32 로 못박아 일관성을 맞췄다. **MI300X 실측 결과 이 선택이 맞았다** (15/15 PASS).
단, 커널 8 처럼 `warpSize` 를 런타임으로 읽는 커널은 이 전제와 충돌해
**따로 고쳐야 했다** (#18·#19). 웨이브64 로 재설계하는 것은 성능 최적화 항목이며
이번 범위 밖이다.

---

# 외부 참조 기록

원칙: 커뮤니티 ROCm 포크는 **먼저 보지 않는다.** 막혔을 때만 보고, 본 사실을 여기 남긴다.

| 일시 | 막힌 지점 | 참조한 곳 | 가져온 것 |
|---|---|---|---|
| — | — | 없음 (전 구간 자체 진단) | — |

---

# 환경 이슈 로그 (변환과 무관하지만 시간을 먹은 것들)

| # | 증상 | 원인 | 해결 |
|---|---|---|---|
| E1 | `hipcc` 가 `amdgcn-link` 단계에서 SEGV | **ROCm 6.2 이미지의 LLVM 링커가 깨져 있음** — `ld.lld --version` 조차 SEGV. 호스트 컴파일과 device IR 생성은 정상이라 코드 문제로 오해하기 쉽다 | 6.3 으로 교체 |
| E2 | `docker: read-only file system` | WSL 가상디스크가 C: 에 있고 C: 여유 0.5GB. 이미지 pull 중 가득 차 ext4 가 emergency read-only 로 전환 | `wsl --manage --move D:\wsl` |
| E3 | `wsl --update` 가 0.0% 에서 17분 정지 | Windows 10 inbox wsl.exe 의 Windows Update 경로 문제 | `--web-download` |
| E4 | `File/Spec/Functions.pm did not return a true value` | ROCm 이미지가 hipcc·hipify-perl 을 perl 스크립트로 넣고 full perl 패키지를 누락 | Dockerfile 에서 `perl` 설치 |
| E5 | `the launch timed out and was terminated` | **Windows TDR** — 디스플레이 드라이버가 2초 넘는 커널을 죽인다. 소비자용 GPU + Windows/WSL 조합에서만 발생 | 문제 크기 축소 (B=2) |
| E6 | `CUBLAS_LOWP` undeclared (fp32 빌드) | **llm.c 의 fp32 경로가 원래 불완전하다.** `#else` 분기가 매크로를 정의하지 않는데 11곳에서 쓴다. bf16 을 끄는 순간 드러난다 | 빌드 스크립트가 `-D` 로 주입 (NVIDIA·AMD 양쪽) |
| E7 | 포드 세션 스크립트 버그 4건 (로컬 리허설에서 발견) | ① 빌드 단계에 GPU 장치 플래그를 붙여 GPU 없는 환경에서 실패 ② 이전 바이너리가 남아 빌드 실패가 '성공'으로 오인 ③ 호스트 경로를 컨테이너에 그대로 전달 ④ 덤프가 컨테이너 밖에서 돌아 nvcc 로 오분기 | `50_pod_session.sh` 에서 `run_build`/`run_gpu` 분리 · 산출물 선삭제 · 상대경로 통일 |
| E8 | `LLMC_B=` 로 원본 크기(B=8)를 못 씀 | `${LLMC_B:-2}` 는 **빈 값도 미설정으로 보고** 기본값을 넣는다 | `${LLMC_B-2}` (콜론 제거) |
| E9 | CRLF↔LF 변환으로 diff 가 51줄 → 2531줄로 부풀음 | 변환 산출물이 CRLF 인데 편집 도구가 LF 로 저장 | CRLF 복원. **이 diff 가 곧 "사람이 한 일" 지표라 오염되면 안 된다** |
| E10 | PowerShell 에서 한글이 깨짐 | PS 5.1 은 BOM 없는 UTF-8 을 코드페이지로 읽는다 | `.ps1` 은 UTF-8 with BOM 으로 저장 |
| E11 | `grep -c` 가 "0" 을 출력하면서 exit 1 → `|| echo 0` 이 "0\n0" 생성 | grep 의 종료코드 규약 | `$(grep -c ... \|\| true)` + `${n:-0}` |
| E12 | 포드에서 `git commit` 실패 — `author identity unknown` | 새 머신에 git 신원 미설정 | `git config user.name/user.email` (저장소 로컬로) |
