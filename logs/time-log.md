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
| 2026-08-02 | Phase 2 — 컴파일 수정 루프 (5회차에 전부 통과) | | 디버깅 | 아래 이슈 표 11건 |
| | | | | |

> 소요(분) 칸은 실제 걸린 시간으로 채운다. 비워둔 채로 보고서에 숫자를 쓰지 않는다.

---

# 이슈 로그

에러 1건 = 1줄. 태그 기준은 [02-convert/checklist.md](../02-convert/checklist.md).
전부 Claude 가 수정했으므로 "시도 횟수"는 재컴파일 회차 기준이다.
**태그는 난이도가 아니라 "문법 변환으로 도달 가능한가"로 가른다.**

| # | 파일 | 에러 요약 | 태그 | 회차 |
|---|---|---|---|---|
| 1 | flash | `rsqrtf` 가 HIP 에선 `__device__` 전용 — 호스트 호출 불가 | `[LLM]` | 1 |
| 2 | (환경) | 이미지에 hipBLAS 미설치 (`hipblas.h` 없음) | `환경` | 1 |
| 3 | common.h · attention | hipify 가 ROCm 5.x 평면 경로(`<hipblas.h>`)를 생성. 6.x 는 `<hipblas/hipblas.h>` | `[LLM]` | 2 |
| 4 | softmax · attention | `cooperative_groups/reduce.h` 및 `cg::reduce` 자체가 HIP 에 **없음** | `[MANUAL]` | 2 |
| 5 | common.h · softmax · attention | `__shfl_*_sync` 8곳을 hipify 가 **전혀 변환하지 않음**. 폭(32 vs 64) 결정 필요 | `[MANUAL]` | 3 |
| 6 | softmax | `__syncwarp()` 부재 | `[LLM]` | 3 |
| 7 | common.h · softmax · attention | `__stcs` 전무, `__ldcs` 오버로드 부족 (float/int4/bf16) | `[LLM]` | 3 |
| 8 | softmax | `min(int, unsigned)` 결과가 정수가 아니라 배열 첨자로 못 씀 (4곳) | `[LLM]` | 3 |
| 9 | common.h | 호스트 `isfinite` 오버로드 모호 | `[LLM]` | 3 |
| 10 | attention | `<cuda_bf16.h>` 를 hipify 가 변환하지 못함 (R6) | `[LLM]` | 3 |
| 11 | common.h | `__CUDACC_VER_MAJOR__` 가드 때문에 bf16 `__ldcs`/`__stcs` 정의가 **통째로 비활성** | `[MANUAL]` | 4 |

**집계: 총 11건 — 자동 `[AUTO]` 별도(아래) · LLM 보조 7건 · 사람 판단 3건 · 환경 1건**

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

### 사람이 실제로 쓴 코드
| 항목 | 규모 |
|---|---|
| 변환 산출물 수정 | **51 insert / 27 delete** (주석 포함, 4파일) |
| 신규 호환 계층 | `cg_reduce_compat.h` 73줄 + `hip_intrinsics_compat.h` 61줄 = **134줄** |

### `[MANUAL]` 3건이 왜 문법 변환으로 안 되는가 — 보고서의 핵심
- **#4 `cg::reduce`**: HIP 에 대응 API 가 없어 shuffle 로 재구성해야 한다.
  `__shfl` 은 스칼라만 받으므로 구조체는 word 단위로 쪼개야 하고,
  `cg::reduce` 는 **모든 레인**에 결과를 남기므로 마지막 브로드캐스트가 필요하다.
  이걸 빠뜨리면 컴파일도 되고 크래시도 안 나면서 답만 틀린다.
- **#5 `__shfl_*_sync` 폭 결정**: CUDA 는 폭이 32 로 암묵 고정이지만 AMD 는 웨이브가 64다.
  **같은 파일 안에서 관례가 갈린다** — `warpReduceMax` 는 `offset=16`(32 가정),
  `kernel8` 은 `offset=warpSize/2`(런타임 64). 일괄 치환하면 반드시 틀린다. (R4 실증)
- **#11 `#if` 안에 숨은 정의**: hipify 는 전처리기 조건 내부를 해석하지 않는다.
  CUDA 버전 매크로로 감싼 코드는 HIP 에서 조용히 사라지고,
  에러는 한참 뒤 **사용 지점**에서 엉뚱한 모습으로 나타난다.

### 아직 해결되지 않은 것 (컴파일은 통과함 — Phase 3 에서 검증)
- **R1 `#define WARP_SIZE 32U`** (common.h:9): 32레인 그룹 전제를 유지하는 방향으로
  폭을 32 로 못박아 **일관성**은 맞췄다. 정답 여부는 MI300X 에서 `validate_result` 로 확인한다.
  이 선택은 "이식성 우선" 이며, 웨이브64 로 재설계하는 것은 **성능 최적화 항목**이다.

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
