# RUNBOOK — 어디까지 했고, 다음에 뭘 하는가

최종 갱신: 2026-08-02

## 현재 상태

| | 항목 | 상태 |
|---|---|---|
| ✅ | Phase 0 — 저장소·구조·하네스·변환 범위 확정·스크립트 | 완료 |
| ✅ | WSL2 (2.7.11.0) + Ubuntu-22.04, 디스크를 `D:\wsl` 로 이동 | 완료 |
| ✅ | Phase 2 환경 — docker + `kernel-bridge/rocm:6.3` | 완료 |
| ✅ | **Phase 2 실행 — 3파일 전부 gfx942 컴파일 성공 (GPU 없이)** | 완료 · 이슈 11건 |
| ✅ | CUDA Toolkit 12.6 (WSL 안) — sm_52 컴파일·실행 검증 통과 | 완료 |
| ⏳ | **Phase 1 — GTX 970(sm_52) 기준선, `LLMC_B=2`** | 측정 중 |
| ⬜ | Phase 3 — MI300X 검증 (네오클라우드) | |
| ⬜ | Phase 4 — 보고서 · 데모 자료 | |

Phase 1과 Phase 2는 **서로 독립**이다. Phase 3만 "Phase 2 통과 후"라는 제약이 있다 — 이게 예산을 지키는 규칙이다.

---

## ⚠ 어느 셸에서 치는가 — 헷갈리면 `command not found` 가 난다

| 프롬프트 | 어디 | 쓸 수 있는 것 |
|---|---|---|
| `PS C:\>` | **Windows PowerShell** | `wsl`, `powershell`, `dir` |
| `<user>@<host>:~$` | **Ubuntu (WSL 안)** | `bash`, `docker`, `apt`, `git`, `&&` |

`wsl` 은 Windows 명령이라 **Ubuntu 안에는 없다.** PowerShell 에서 `wsl` 을 치면 Ubuntu 로 들어간다. 나올 때는 `exit`.

아래에서 `$REPO` 는 이 저장소의 WSL 경로다. 저장소를 클론한 위치에 맞춰 한 번 정해 두면 된다:
```bash
REPO=$(pwd)          # 저장소 루트에서 실행
# 또는 예: REPO=/mnt/d/work/kernel-bridge
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

## STEP B — Phase 3: MI300X 검증 (네오클라우드)

> ⚠ Phase 2 컴파일이 **전부 통과한 뒤에만** 온다. 여기서 처음 만나는 건 런타임 오류뿐이어야 한다.

RunPod MI300X (백업: TensorWave) 에서:
```bash
git clone <저장소> kernel-bridge && cd kernel-bridge
bash scripts/00_fetch_sources.sh
docker build -t kernel-bridge/rocm:6.3 docker/
docker run --rm -e FP32_ONLY=1 -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 \
    bash scripts/21_build_hip.sh
LLMC_B=2 bash scripts/30_verify_mi300x.sh
```

**`FP32_ONLY=1` 과 `LLMC_B` 를 빠뜨리지 말 것.** 기준선이 fp32 로 측정됐다면 MI300X 도 fp32 여야 한다.

정확도 불일치가 나오면 **R1(`WARP_SIZE 32`)부터 의심한다.** 끝나면 **인스턴스를 즉시 끈다.**

---

## STEP C — Phase 4: 보고서 · 데모

- `report/summary-template.md` 채우기 (실측값 없는 칸은 비워 둔다)
- 데모 장치 3종 — 자세한 설계는 [report/demo-plan.md](report/demo-plan.md)
- 컴파일 에러 수정 루프는 **사전 녹화 필수** (라이브 실패 위험)

---

# 다른 머신에서 재현하기

노트북이나 클라우드에서 다시 세팅할 때 **오늘 밟은 함정을 다시 밟지 않으려면** 아래를 그대로 따른다.

## 1. 저장소 가져오기

```bash
git clone <원격 저장소> kernel-bridge && cd kernel-bridge
bash scripts/00_fetch_sources.sh        # llm.c 를 고정 SHA 로 받는다
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

## 2-b. 네오클라우드 (RunPod / TensorWave) — 리눅스 직접

WSL 이 아니므로 `scripts/win/` 은 쓰지 않는다. 나머지는 동일하다.

```bash
docker build -t kernel-bridge/rocm:6.3 docker/
docker run --rm -e FP32_ONLY=1 -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 \
    bash -c 'bash scripts/22_verify_toolchain.sh && bash scripts/20_hipify.sh && bash scripts/21_build_hip.sh'
bash scripts/30_verify_mi300x.sh     # GPU 있는 포드에서만
```

NVIDIA 네오클라우드에서 기준선을 다시 잡을 때는 `NV_ARCH` 만 바꾼다 (A100=`sm_80`, H100=`sm_90`).

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

## 4. 조건 일치 체크리스트 (비교표를 쓰기 전에 확인)

- [ ] 양쪽 정밀도가 같은가 (`FP32_ONLY` / `ENABLE_BF16` / TF32)
- [ ] 문제 크기 `B` 가 같은가 (`LLMC_B`)
- [ ] llm.c 커밋 SHA 가 같은가 (`f1e2ace6`)
- [ ] 컴파일 최적화 플래그가 같은가 (`-O3`, fast-math)

**하나라도 어긋나면 성능 숫자는 쓰지 않는다.**
