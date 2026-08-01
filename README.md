# kernel-bridge

CUDA → ROCm 커널 레벨 변환 데모 (레벨 0.5)

## 목적
"CUDA 코드를 HIPIFY + LLM으로 AMD MI300X에서 실제로 변환·검증하는 과정"을
커널 단위로 끝까지 완주하고, 자동화 가능 구간과 사람이 필요한 구간을 실측한다.

## 변환 대상 (3파일 고정 — 범위 확장 금지)
변환 순서는 **어려운 것부터**다. 쉬운 파일을 먼저 하면 자동화율이 과대평가된다.
근거와 확정 범위는 [02-convert/scope.md](02-convert/scope.md) 참조.

1. llm.c `dev/cuda/softmax_forward.cu` (732줄) — warp32 가정이 가장 많음
2. llm.c `dev/cuda/attention_forward.cu` (1390줄) — cuBLAS/cuBLASLt + `cg::reduce`
3. `00-src/flash_attention_simplified.cu` (172줄) — 자체 교육용 커널, 데모 시연용

llm.c 두 파일은 `validate_result`(tol 1e-4) + `benchmark_kernel` 하네스가 내장돼 있다.
flash 커널에는 없어서 [00-src/flash_attention_test.cu](00-src/flash_attention_test.cu)를 따로 만들었다.

## 폴더 구조
- `00-src/`      자체 작성 소스 (원본 커널 · 하네스). **원본은 수정하지 않는다**
- `vendor/`      llm.c 얕은 클론 (커밋하지 않음 — SHA로만 재현)
- `scripts/`     단계별 실행 스크립트. **GPU 필요/불필요 경계가 여기서 정해진다**
- `01-baseline/` NVIDIA 원본 실행 결과 (정확도 기준선 · ms)
- `02-convert/`  범위 확정 · hipify 출력 · diff · 에러 로그
- `03-verify/`   MI300X 실행 결과 (정확도 PASS · 타이밍)
- `logs/`        시간 기록 · 이슈 로그 (지표의 원료)
- `report/`      요약 1장 + 시연 대본

## 실행 순서 — 과금 경계가 핵심

| Phase | 스크립트 | GPU | 시간 | 비용 |
|---|---|---|---|---|
| 0 | `00_fetch_sources.sh` | 없음 | 1분 | $0 |
| 1 | `10_baseline_nvidia.sh` | A100 (sm_80) | 1~2h | ~$5 |
| 2a | `20_hipify.sh` | **없음** | 5분 | $0 |
| 2b | `21_build_hip.sh` | **없음** | 수 시간 | $0 |
| 3 | `30_verify_mi300x.sh` | MI300X | 2~3h | ~$10 |
| 4 | 보고서 작성 | 없음 | — | $0 |

**hipify와 hipcc 컴파일에는 GPU가 필요 없다.** 가장 오래 걸리는 컴파일 수정 루프를
CPU 컨테이너에서 끝내고, MI300X는 "실행" 단계에서만 켠다.
21이 전부 통과하기 전에 30을 실행하지 않는다 → MI300X 6~10h를 2~3h로 줄인다.

환경 준비는 [scripts/README.md](scripts/README.md) 참조.

## 데모 시나리오 (10분)
1. 원본 CUDA 커널 보여주기 (30초)
2. hipify-perl 실행 → diff (1분)
3. 컴파일 에러 → Claude 수정 루프 (3분, **사전 녹화 백업 필수**)
4. MI300X 실행 → 정확도 PASS + 실행 시간 (2분)
5. 지표 1장: 자동/보조/수작업 비율 · NVIDIA 대비 성능 % (3분)

## 환경
- 클라우드: RunPod MI300X 1장 (백업: TensorWave) — 코딩 중 인스턴스 OFF
- 이미지: Phase 2 는 `docker/Dockerfile` (베이스 `rocm/dev-ubuntu-22.04:**6.3**`),
  Phase 3 는 `rocm/pytorch` 공식 도커 (베어메탈 ROCm 설치 금지)
  ※ **6.2 는 쓰지 않는다** — 링커(`ld.lld`)가 SEGV 로 죽는다. 근거는 `docker/Dockerfile` 주석
- NVIDIA 비교: **A100 (sm_80)** 1~2시간 — 확정. H100 대비 저렴하고 데이터센터급이라
  MI300X 와 대비했을 때 보고서 신뢰도가 유지된다
- 예산: 총 **$15~20**

## 원칙
- 모든 에러·소요 시간을 logs/ 에 기록한다 — 로그가 곧 산출물이다
- 커뮤니티 ROCm 포크는 먼저 보지 않는다. 막혔을 때만 참조하고, 참조 사실을 기록한다
- 실측값 없는 숫자는 보고서에 쓰지 않는다
- **정밀도를 맞추지 않은 성능 비교는 하지 않는다** — llm.c는 A100/H100에서 TF32를
  자동으로 켠다. 비교표 기준값은 fp32 대 fp32다 (scope.md §3)
