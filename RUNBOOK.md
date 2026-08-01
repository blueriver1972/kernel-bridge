# RUNBOOK — 어디까지 했고, 다음에 뭘 하는가

최종 갱신: 2026-08-02

## 현재 상태

| | 항목 | 상태 |
|---|---|---|
| ✅ | Phase 0 — 저장소·구조·하네스·범위 확정·스크립트 | 완료 |
| ✅ | WSL2 설치 (2.7.11.0 / 커널 6.18.33.2) | 완료 |
| ✅ | Ubuntu-22.04 설치 (VERSION 2, 사용자 생성 완료) | 완료 |
| ✅ | WSL 디스크를 D:\wsl 로 이동 (C: 공간 부족 해결) | 완료 |
| ✅ | Phase 2 환경 — docker + `kernel-bridge/rocm:6.3`, gfx942 컴파일 검증 통과 | 완료 |
| ⬜ | **Phase 2 실행 (hipify + 컴파일 루프)** | ← **여기부터 (STEP 3)** |
| ⬜ | Phase 1 — A100 기준선 | |
| ⬜ | Phase 2 — hipify + 컴파일 수정 루프 | |
| ⬜ | Phase 3 — MI300X 검증 | |
| ⬜ | Phase 4 — 보고서 | |

Phase 1과 Phase 2는 **서로 독립**이다. 어느 쪽을 먼저 해도 된다.
Phase 3만 "Phase 2가 전부 통과한 뒤"라는 순서 제약이 있다 — 이게 예산을 지키는 규칙이다.

---

## STEP 1 — Ubuntu 설치 (관리자 PowerShell)

WSL2는 이미 준비됐으므로 배포판만 남았다.

```powershell
wsl --install -d Ubuntu-22.04
```

설치 후 Ubuntu 창에서 **UNIX 사용자명과 비밀번호를 직접 입력**한다.

확인:
```powershell
wsl --list --verbose
```
`Ubuntu-22.04   Stopped   2` 처럼 **VERSION이 2**로 나와야 한다.

> 이름이 맞지 않으면 `wsl --list --online` 으로 정확한 이름을 확인한다.
> Store 경유가 막히면: `Invoke-WebRequest https://aka.ms/wslubuntu2204 -OutFile "$env:TEMP\u.appx" -UseBasicParsing; Add-AppxPackage "$env:TEMP\u.appx"`

---

## ⚠ 어느 셸에서 치는가 — 이걸 헷갈리면 `command not found` 가 난다

| 프롬프트 모양 | 어디 | 쓸 수 있는 것 |
|---|---|---|
| `PS C:\>` | **Windows PowerShell** | `wsl`, `wsl --list`, `powershell` |
| `k8096@DESKTOP-...:~$` | **Ubuntu (WSL 안)** | `bash`, `docker`, `apt`, `git` |

`wsl` 은 Windows 명령이라 **Ubuntu 안에서는 존재하지 않는다.**
이미 Ubuntu 프롬프트에 들어와 있다면 `wsl -d ... -- bash x.sh` 대신 그냥 `bash x.sh` 를 친다.

---

## STEP 2 — Phase 2 환경 (GPU 불필요, $0)

### 🐧 Ubuntu 프롬프트에서 (`k8096@...$`)

```bash
bash "/mnt/d/onedrive/문서/Claude/Projects/kernel-bridge/scripts/win/setup-rocm-container.sh"
```

### 🪟 Windows PowerShell 에서 시작한다면

```powershell
wsl -d Ubuntu-22.04 -- bash "/mnt/d/onedrive/문서/Claude/Projects/kernel-bridge/scripts/win/setup-rocm-container.sh"
```

둘은 같은 일을 한다: docker.io 설치 → 데몬 기동 → ROCm 개발 이미지 pull →
`hipify-perl`/`hipcc` 존재 확인. sudo 비밀번호를 몇 번 물어본다.
**받아진 이미지 태그를 `02-convert/scope.md`에 기록**할 것.

끝나면 🪟 PowerShell 에서 한 번:
```powershell
wsl --shutdown
```
docker 그룹 반영에 필요하다.

> 경로 확인됨 (2026-08-02): `/mnt/d/onedrive/문서/Claude/Projects/kernel-bridge` 가
> WSL 에서 정상적으로 보인다. 한글 경로는 문제되지 않는다.
> 다만 `/mnt/d` 는 DrvFs 라 느리고 OneDrive 동기화와 겹친다. 빌드가 답답하면
> `cp -r /mnt/d/onedrive/문서/Claude/Projects/kernel-bridge ~/kernel-bridge` 로
> 리눅스 쪽에 복사해 작업하고, 결과 파일만 되돌려 복사한다.

---

## STEP 3 — Phase 2 실행 (GPU 불필요, $0)

WSL 안에서:

```bash
cd /mnt/d/onedrive/문서/Claude/Projects/kernel-bridge
bash scripts/00_fetch_sources.sh
```

그다음 ROCm 컨테이너 안에서 (IMAGE는 STEP 2가 알려준 태그):

```bash
docker run --rm -it -v "$PWD":/w -w /w $IMAGE \
    bash -lc 'export PATH=$PATH:/opt/rocm/bin; bash scripts/20_hipify.sh && bash scripts/21_build_hip.sh'
```

- `20_hipify.sh` → `02-convert/hipify-out/`, diff, **잔여 32 가정 목록**
- `21_build_hip.sh` → 컴파일. 에러가 나면 여기서 수정 루프를 돈다

**이 구간이 프로젝트에서 가장 길다.** 에러 1건마다 `logs/time-log.md` 이슈 표에
`[AUTO]/[LLM]/[MANUAL]` 태그와 시도 횟수를 적는다 — **이 로그가 보고서의 지표 전부다.**

예상 난관은 [02-convert/scope.md](02-convert/scope.md) R1~R7에 미리 정리돼 있다.
특히 **R1(`WARP_SIZE 32`)은 컴파일도 통과하고 크래시도 안 나면서 답만 틀린다.**

---

## STEP 4 — Phase 1: A100 기준선 (GPU 필요, ~$5, 1~2h)

STEP 3과 병행 가능. A100 인스턴스에서:

```bash
git clone <이 저장소> && cd kernel-bridge
bash scripts/00_fetch_sources.sh
bash scripts/10_baseline_nvidia.sh
```

`NV_ARCH` 기본값이 `sm_80`이라 인자가 필요 없다.
fp32/TF32 두 벌을 자동으로 빌드·측정한다.

끝나면:
- `01-baseline/raw/*.log` → `01-baseline/baseline.md` 표로 옮긴다
- `enable_tf32:` 출력이 fp32 빌드에서 `0`인지 확인한다
- **인스턴스를 즉시 끈다**

---

## STEP 5 — Phase 3: MI300X 검증 (GPU 필요, ~$10, 2~3h)

> ⚠ **STEP 3의 컴파일이 전부 통과한 뒤에만 온다.** 여기서 처음 만나는 건 런타임 오류뿐이어야 한다.

RunPod MI300X + `rocm/pytorch` 이미지에서:

```bash
bash scripts/30_verify_mi300x.sh
```

실행 → 정확도 요약 → rocprof 병목 1건까지 자동.
끝나면 `03-verify/verify.md`를 채우고 **인스턴스를 즉시 끈다.**

정확도 불일치가 나오면 R1(`WARP_SIZE`)부터 의심한다.

---

## STEP 6 — Phase 4: 보고서 ($0)

- `report/summary-template.md` 채우기 (실측값 없는 칸은 비워 둔다)
- 데모 대본 + **3단계(컴파일 에러 수정 루프) 사전 녹화** — 라이브 실패 위험이 크다

---

## 막히면

로컬 WSL/docker가 계속 말썽이면 **저가 CPU 클라우드 VM(~$0.1/h)** 에서 STEP 2·3을
그대로 돌릴 수 있다. RunPod을 어차피 쓸 거면 계정이 하나로 끝난다.
MI300X 대비 100배 저렴하므로 Phase 2를 GPU 밖으로 빼는 목적은 그대로 달성된다.
