# scripts — 실행 순서와 과금 경계

핵심 설계: **GPU가 필요한 구간과 아닌 구간을 분리한다.**
가장 오래 걸리는 컴파일 수정 루프(20·21)는 GPU 없이 돈다.

| # | 스크립트 | GPU | 예상 시간 | 비용 |
|---|---|---|---|---|
| 00 | `00_fetch_sources.sh` | 없음 | 1분 | $0 |
| 10 | `10_baseline_nvidia.sh` | **NVIDIA A100 (sm_80)** | 1~2h | ~$5 |
| 20 | `20_hipify.sh` | 없음 (CPU 컨테이너) | 5분 | $0 |
| 21 | `21_build_hip.sh` | 없음 (CPU 컨테이너) | **수 시간 (수정 루프)** | $0 |
| 30 | `30_verify_mi300x.sh` | **MI300X** | 2~3h | ~$10 |

**21이 전부 통과하기 전에는 30을 실행하지 않는다.** 이 규칙 하나가
원안 대비 MI300X 사용 시간을 6~10h → 2~3h 로 줄인다.

---

## 로컬(Windows) 환경 현황

이 PC에는 `docker` 와 WSL 배포판이 **설치돼 있지 않습니다** (`git`, `python`, `wsl` 실행기만 확인됨).
20·21을 로컬에서 돌리려면 둘 중 하나가 필요합니다.

**A. 로컬 WSL2 + docker.io** (권장 — $0)

점검 결과 이 PC는 **WSL·Virtual Machine Platform 기능이 이미 활성**이고
(`LxssManager`/`vmcompute` 서비스 존재) **WSL2 커널만 없습니다.**
Windows 기능 켜기와 그에 따른 재부팅은 필요 없습니다.

1. **관리자 PowerShell** 에서:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\win\setup-wsl.ps1
   ```
   `wsl --update` → `--set-default-version 2` → `Ubuntu-22.04` 설치까지 합니다.
2. Ubuntu 첫 실행에서 **UNIX 사용자명·비밀번호를 직접 입력**합니다.
3. WSL 안에서:
   ```bash
   bash scripts/win/setup-rocm-container.sh
   ```
   docker.io 설치 + ROCm 개발 이미지 pull + `hipify-perl`/`hipcc` 존재 확인까지 합니다.

Docker Desktop 은 쓰지 않습니다 — 추가 관리자 설치와 라이선스 동의를 피하려는 것이고,
어차피 GPU 패스스루가 필요 없습니다 (hipify 와 컴파일만 하므로).

**B. 저가 CPU 클라우드 인스턴스** (~$0.1/h)
아무 리눅스 VM에 docker 설치 후 위 컨테이너 실행. MI300X 대비 100배 저렴합니다.

> ROCm 을 베어메탈로 설치하지 않습니다 (README 원칙). 컨테이너만 씁니다.

---

## 아키텍처 지정

`--offload-arch` / `-arch` 를 명시하지 않으면 컴파일러가 로컬 GPU를 찾으려 하고,
GPU 없는 머신에서는 실패하거나 엉뚱한 타깃이 나옵니다.

기본값이 확정 구성(**A100 = `sm_80`**, **MI300X = `gfx942`**)이므로 인자 없이 돌리면 됩니다.
다른 GPU 를 잡게 되면 환경변수로 덮어씁니다.

```bash
NV_ARCH=sm_90 bash scripts/10_baseline_nvidia.sh   # H100 으로 바꿀 경우에만
```

## 자동 시간 기록

모든 주요 단계는 `logs/auto-time.tsv` 에 `시각 / 라벨 / 초 / 종료코드` 로 자동 누적됩니다.
`logs/time-log.md` 의 "사람 개입 시간" 은 여기서 집계하되,
**사람이 판단하며 보낸 시간은 손으로 따로 적어야 합니다** (스크립트는 그걸 모릅니다).
