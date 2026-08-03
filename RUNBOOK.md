# RUNBOOK — 어디까지 했고, 다음에 뭘 하는가

최종 갱신: 2026-08-03

## 현재 상태

| | 항목 | 상태 |
|---|---|---|
| ✅ | Phase 0 — 저장소·구조·하네스·변환 범위 확정·스크립트 | 완료 |
| ✅ | WSL2 (2.7.11.0) + Ubuntu-22.04, 디스크를 `D:\wsl` 로 이동 | 완료 |
| ✅ | Phase 2 환경 — docker + `kernel-bridge/rocm:6.3` | 완료 |
| ✅ | **Phase 2 — 3파일 전부 gfx942 컴파일 성공 (GPU 없이)** | 완료 · 이슈 11건 |
| ✅ | CUDA Toolkit 12.6 (WSL 안) — sm_52 컴파일·실행 검증 통과 | 완료 |
| ✅ | **Phase 1 — GTX 970(sm_52) 기준선, `LLMC_B=2`** | 완료 · 15/15 PASS |
| ✅ | 데모 장치 1·2 (차이 이미지 · 버그 주입) — 970 에서 실측 검증 | 완료 |
| ✅ | 공개 저장소 게시 | 완료 |
| ✅ | **Phase 3 — MI300X 검증 (AMD Developer Cloud, ROCm 7.0.2)** | **완료 · 15/15 PASS · 이슈 8건 추가** |
| ✅ | 두 플랫폼 출력 대조 이미지 (상대오차 3.783e-07) | 완료 |
| ✅ | Phase 3 재측정 (녹화 2회차) — 같은 값 재현 | 완료 |
| ⛔ | ~~H100/H200 기준선 재측정~~ | **접음 — 성능 비교는 범위 밖으로 확정** |
| ⬜ | **Phase 4 — 데모 녹화 (클립 1~4·6~8)** | ← **여기부터. 전부 GPU 불필요** |

Phase 1과 Phase 2는 **서로 독립**이다. Phase 3만 "Phase 2 통과 후"라는 제약이 있다 — 이게 예산을 지킨 규칙이다.

### ★ 성능 비교를 하지 않기로 한 이유

기준선이 GTX 970(2014, 3.5 TFLOPS)이고 MI300X 는 163 TFLOPS 다.
동급 NVIDIA(H100/H200)를 빌려 재측정하는 방안은 **비용 대비 얻는 것이 없다고 판단해 접었다.**
이 프로젝트가 증명하는 것은 "AMD 가 빠르다"가 아니라 **"이식이 맞는지 자동으로 검증된다"** 다.
측정된 시간은 `03-verify/comparison.md` 에 참고용으로만 남기고 **발표 자료에 넣지 않는다.**

---

## ⚠ 어느 셸에서 치는가 — 헷갈리면 `command not found` 가 난다

| 프롬프트 | 어디 | 쓸 수 있는 것 |
|---|---|---|
| `PS C:\>` | **Windows PowerShell** | `wsl`, `powershell`, `dir`. `&&` 는 **파서 오류** |
| `<user>@<host>:~$` | **Ubuntu (WSL 안)** | `bash`, `docker`, `apt`, `git`, `&&` |
| `root@rocm-...:~#` | **클라우드 포드 (SSH)** | 위와 같음. 로컬 파일은 없다 |

`wsl` 은 Windows 명령이라 **Ubuntu 안에는 없다.** PowerShell 에서 `wsl` 을 치면 Ubuntu 로 들어간다. 나올 때는 `exit`.

아래에서 `$REPO` 는 이 저장소의 WSL 경로다:
```bash
REPO=$(pwd)          # 저장소 루트에서 실행
```

---

## STEP A — Phase 1: NVIDIA 기준선

### A-1. CUDA Toolkit (WSL 안, 1회, sudo 필요)
```bash
cd "$REPO" && bash scripts/win/setup-cuda-wsl.sh
```
GPU 패스스루 확인 → CUDA 12.6 설치(~3GB) → **sm_52 로 실제 커널을 컴파일·실행해 검증**까지 한다.

> Windows 에 CUDA 를 설치하지 않는다. WSL2 가 Windows 드라이버를 통해 GPU 를 쓴다
> (`/dev/dxg` + `/usr/lib/wsl/lib/libcuda.so`).
> **`cuda` 나 `cuda-drivers` 패키지는 절대 설치하지 않는다** — 리눅스 드라이버가 들어와 패스스루가 깨진다.

### A-2. 기준선 측정
```bash
cd "$REPO" && LLMC_B=2 NV_ARCH=sm_52 bash scripts/10_baseline_nvidia.sh
```
스크립트가 아키텍처를 보고 알아서 분기한다.

| | sm_80 이상 (A100/H100) | sm_80 미만 (GTX 970) |
|---|---|---|
| bf16 | 사용 | **불가** → `ENABLE_BF16` 제거, 전부 fp32 |
| TF32 | 자동 활성 → fp32 강제본과 두 벌 측정 | 하드웨어에 없음 → 한 벌 |

VRAM 부족이나 TDR 로 커널이 죽으면 `LLMC_B` 로 문제 크기를 줄인다.
**이 PC 실측: B=8, B=4 는 TDR 에 걸리고 B=2 가 한계선이다.**
**MI300X 에도 반드시 같은 값을 써야 비교가 성립한다.**

끝나면 `01-baseline/raw/*.log` → `01-baseline/baseline.md` 로 옮긴다.

---

## STEP B — Phase 3: MI300X 검증 (실제로 이렇게 했다)

> ⚠ Phase 2 컴파일이 **전부 통과한 뒤에만** 온다. 그래도 런타임 이슈 8건이 나왔다.

**쓴 곳: AMD Developer Cloud** (devcloud.amd.com · DigitalOcean 인프라 · MI300X 1장 $1.99/시간)
ROCm 7.0.2 가 이미 깔린 이미지라 docker 빌드 없이 네이티브로 돌았다.

```bash
ssh root@<DROPLET_IP>
git clone https://github.com/blueriver1972/kernel-bridge && cd kernel-bridge
bash scripts/50_pod_session.sh
```

**이 한 줄이 전부다.** `50_pod_session.sh` 가 환경 감지 → 빌드 → 검증 → 덤프 → 요약까지 한다.
실측 소요: **약 30~40분** (attention k1·k2 가 naive 구현이라 각 1~2분).

### 이 스크립트가 지키는 것

| 규칙 | 이유 |
|---|---|
| **`20_hipify.sh` 를 부르지 않는다** | 다시 돌리면 수정 19건이 전부 덮어써진다 |
| 빌드(`run_build`)와 실행(`run_gpu`)을 분리 | 컴파일에는 GPU 장치가 필요 없다. 플래그를 붙이면 GPU 없는 환경에서 빌드조차 실패 |
| 이전 바이너리를 먼저 지운다 | 남아 있으면 빌드 실패가 '성공'으로 오인된다 |
| ROCm 6.2 를 감지하면 docker 로 우회 | 6.2 링커가 깨져 있다 (E1) |
| `FP32_ONLY=1` · `LLMC_B=2` 기본값 | 기준선과 조건을 맞춘다. 어긋나면 비교 무효 |

`LLMC_B=` (빈 값)으로 원본 크기 B=8 을 쓸 수 있다. `${LLMC_B-2}` 이므로 콜론이 없다.

### 끝난 뒤 (순서 중요)

```bash
# 1) 포드에서 로그 push — git 신원이 없으면 먼저 설정
git config user.name "..." && git config user.email "...@users.noreply.github.com"
git add -A 03-verify/raw report/demo-images logs/auto-time.tsv
git commit -m "MI300X 세션 로그" && git push
```

2. **인스턴스를 Destroy 한다.** "Power Off" 는 스토리지 요금이 계속 나간다.
3. 콘솔에서 `Hourly Rate: $0.00` / `No active resources` 확인.

### 로컬에서 이어서

```bash
python3 scripts/40_demo_images.py \
    report/demo-images/nvidia_970.bin \
    report/demo-images/amd_mi300x.bin \
    --labels NVIDIA MI300X --outdir report/demo-images/real
```

**GPU 가 필요 없다.** `.bin` 두 개만 있으면 된다.

---

## STEP C — Phase 4: 보고서 · 데모

- [report/summary.md](report/summary.md) — 측정값이 들어간 실제 요약
- [report/demo-plan.md](report/demo-plan.md) — 데모 장치 설계
- [report/recording-script.md](report/recording-script.md) — 클립별 찍는 순서와 명령
- **남은 클립은 전부 GPU 가 필요 없다.** MI300X 클립(5)은 이미 녹화 완료

---

# 다른 머신에서 재현하기

## 1. 저장소 가져오기

```bash
git clone https://github.com/blueriver1972/kernel-bridge && cd kernel-bridge
bash scripts/00_fetch_sources.sh        # llm.c 를 고정 SHA(f1e2ace6) 로 받는다
```

`vendor/` 와 `bin/` 은 커밋하지 않는다 — 재현은 커밋 SHA 로만 보장한다.

## 2-a. 노트북 (Windows + WSL2) — Phase 2 를 GPU 없이

```powershell
# 관리자 PowerShell (기능이 꺼져 있는 경우에만)
powershell -ExecutionPolicy Bypass -File scripts\win\setup-wsl.ps1
```
```bash
# Ubuntu 안에서
bash scripts/win/setup-rocm-container.sh
```

노트북에 NVIDIA GPU 가 있다면 기준선도 로컬에서:
```bash
bash scripts/win/setup-cuda-wsl.sh
NV_ARCH=sm_XX bash scripts/10_baseline_nvidia.sh
```

## 2-b. 클라우드 MI300X — 리눅스 직접

WSL 이 아니므로 `scripts/win/` 은 쓰지 않는다.

```bash
bash scripts/50_pod_session.sh      # 단일 진입점. 위 STEP B 참조
```

## 3. 반드시 기억할 함정 (전부 실측으로 겪은 것)

| # | 증상 | 원인 | 대응 |
|---|---|---|---|
| 1 | `hipcc` 가 `amdgcn-link` 에서 SEGV | **ROCm 6.2 이미지의 링커가 깨져 있다.** `ld.lld --version` 조차 죽는다. 호스트 컴파일과 device IR 생성은 정상이라 코드 문제로 오해하기 쉽다 | **6.3 이상 사용** (`docker/Dockerfile` 에 고정됨) |
| 2 | `docker: read-only file system` | 호스트 디스크가 가득 차 ext4 가 emergency read-only 로 전환 | 이미지 4GB+ 여유 확보. WSL 이면 `wsl --manage <distro> --move D:\wsl` |
| 3 | `File/Spec/Functions.pm did not return a true value` | ROCm 이미지가 hipcc·hipify-perl 을 perl 스크립트로 넣고 full perl 을 누락 | Dockerfile 이 `perl` 설치 (해결됨) |
| 4 | `hipblas.h` not found | dev 이미지에 BLAS 미설치 + hipify 가 ROCm 5.x 평면 경로를 생성 | Dockerfile 이 `hipblas-dev` 설치, 소스는 `<hipblas/hipblas.h>` 로 수정됨 |
| 5 | `CUBLAS_LOWP` undeclared | **llm.c 의 fp32 경로가 원래 불완전하다.** `#else` 분기가 매크로를 정의하지 않는데 11곳에서 쓴다 | 빌드 스크립트가 `-D` 로 주입 (양쪽 모두 해결됨) |
| 6 | `wsl --update` 가 0.0% 에서 정지 | Windows 10 inbox wsl.exe 의 Windows Update 경로 | `wsl --update --web-download` |
| 7 | PowerShell 에서 한글이 깨짐 | PS 5.1 은 BOM 없는 UTF-8 을 코드페이지로 읽는다 | `.ps1` 은 **UTF-8 with BOM** 으로 저장 (적용됨) |
| 8 | `wsl -d ... -- bash` 에서 `VAR=$(...)` 가 빈 값 | Windows→WSL 인자 전달 과정의 문제 | 명령 치환 대입을 피하고 `$PWD` 나 글롭을 쓴다 |
| 9 | `the launch timed out and was terminated` | **Windows TDR** — 디스플레이 드라이버가 2초 넘는 커널을 죽인다. 소비자용 GPU 를 Windows/WSL 에서 쓸 때만 발생하며 데이터센터 GPU 에는 없다 | 문제 크기 축소(`LLMC_B`). 이 PC 는 B=2 가 한계 |
| **10** | **ROCm 7.x 에서 `hip/hip_runtime.h` not found** | `hipcc`·`hipconfig` 가 `core-7.14/include` 를 가리키는데 헤더는 `/opt/rocm/include` 에 있다 | 빌드 스크립트가 `-I/opt/rocm/include` 를 항상 붙인다 (해결됨) |
| **11** | **ROCm 7.x 에서 `__syncwarp` 중복 정의 / `..._v2` API 없음** | 6.3 에 없던 것이 7.x 에 생기고, 있던 것이 사라졌다. **버전 간 이식이 또 필요하다** | 호환 계층이 `__has_include` 와 `HIP_VERSION_MAJOR` 로 분기 (해결됨) |
| **12** | **호스트 `max(float,float)` 가 쓰레기값** | HIP 호스트에는 `int max(int,int)` 만 보인다. **경고 한 줄만 나오고 크래시도 없다** | `fmaxf` 로 명시 (해결됨). ★ 정답 대조 없이는 발견 불가 |
| **13** | **`hipblasSetMathMode` 가 `NOT_SUPPORTED(7)` → attention 6개 전부 실패** | `enable_tf32 = major >= 8` 이 MI300X(major=9)에서 참이 된다. **CUDA 개념이 AMD 로 누출** | `enable_tf32 = 0` 고정, **두 곳** (해결됨) |
| **14** | **커널 8 이 `block_size=64` 에서만 틀림** | 웨이브 폭 가정이 디바이스(`blockDim.x/warpSize`)와 호스트(`ceil_div(N*32,...)`) **양쪽에** 있다. 하나만 고치면 여전히 틀림 | 둘 다 수정 + 블록 크기 가드 (해결됨) |
| 15 | 포드에서 `git commit` 이 `author identity unknown` | 새 머신에 git 신원 미설정 | `git config user.name` / `user.email` (저장소 로컬로 충분) |

**#12·#14 는 컴파일러가 아무 말도 하지 않는다.** 이것이 이 프로젝트의 결론이다 —
[report/summary.md](report/summary.md) 의 "신호가 없는 3건" 참조.

## 4. 조건 일치 체크리스트

- [x] 양쪽 정밀도가 같은가 (`FP32_ONLY=1` / `ENABLE_BF16` 제거 / TF32 없음)
- [x] 문제 크기 `B` 가 같은가 (`LLMC_B=2`)
- [x] llm.c 커밋 SHA 가 같은가 (`f1e2ace6`)
- [x] 컴파일 최적화 플래그가 같은가 (`-O3`, fast-math)
- [ ] **동급 하드웨어 — 미충족.** 그래서 **성능 비교를 발표하지 않는다**

정확도 비교에는 위 네 항목만 필요하고 전부 충족했다.
성능 비교에는 다섯 번째가 필요하고 충족하지 못했으므로 **하지 않는다.**
