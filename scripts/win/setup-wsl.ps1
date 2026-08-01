# kernel-bridge — WSL2 준비 (★ 관리자 PowerShell 에서 실행 ★)
#
# 목적: Phase 2(hipify + hipcc 컴파일)를 GPU 없이 로컬에서 돌리기 위한 리눅스 환경.
#
# 이 PC 사전 점검 결과 (2026-08-01):
#   - WSL / Virtual Machine Platform 기능: 이미 활성 (LxssManager, vmcompute 서비스 존재)
#     → Windows 기능 켜기와 그에 따른 재부팅은 필요 없음
#   - WSL2 커널: 없음 → wsl --update 필요 (관리자)
#   - wsl.exe: inbox 구버전 (--version 미지원). --install / --update 는 지원
#   - Windows 10 22H2 (19045)
#
# 실행 후 Ubuntu 첫 실행에서 UNIX 사용자명·비밀번호를 물어봅니다.
# 그건 직접 입력하세요 — 계정과 비밀번호는 사람이 만드는 겁니다.

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = 1

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  !   $msg" -ForegroundColor Yellow }

# --- 0. 권한 확인 -----------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "관리자 권한이 필요합니다." -ForegroundColor Red
    Write-Host "시작 메뉴 > PowerShell 우클릭 > '관리자 권한으로 실행' 후 다시 돌리세요."
    exit 1
}
Ok "관리자 권한 확인"

# --- 1. WSL2 커널 설치 ------------------------------------------------------
Step "WSL2 커널 업데이트"
wsl --update
if ($LASTEXITCODE -ne 0) {
    Warn "wsl --update 실패. 수동 설치: https://aka.ms/wsl2kernel"
    Warn "(inbox wsl.exe 라면 --web-download 옵션이 필요할 수 있습니다)"
    exit 1
}
Ok "커널 설치 완료"

# --- 2. 기본 버전을 2로 ------------------------------------------------------
Step "기본 WSL 버전을 2로 설정"
wsl --set-default-version 2
Ok "완료 (Docker 는 WSL2 에서만 동작합니다)"

# --- 3. Ubuntu 설치 ---------------------------------------------------------
Step "설치 가능한 배포판 확인"
wsl --list --online

$distro = 'Ubuntu-22.04'
Step "$distro 설치"
wsl --install -d $distro
if ($LASTEXITCODE -ne 0) {
    Warn "$distro 설치 실패. 위 --list --online 목록의 정확한 이름으로 다시 시도하세요."
    Warn "예: wsl --install -d Ubuntu"
    exit 1
}

Write-Host @"

────────────────────────────────────────────────────────────
여기부터는 직접 하셔야 합니다.

1) Ubuntu 창이 뜨면 UNIX 사용자명과 비밀번호를 입력하세요.
   (계정 생성은 사람이 합니다 — 대신 만들어 드리지 않습니다)

2) 완료되면 아래를 실행해 ROCm 컨테이너 환경을 준비합니다:

     wsl -d $distro -- bash /mnt/d/onedrive/문서/Claude/Projects/kernel-bridge/scripts/win/setup-rocm-container.sh

   (sudo 비밀번호를 몇 번 물어봅니다)

3) 재부팅이 필요하다는 메시지가 나오면 재부팅 후 2)로 돌아오세요.
────────────────────────────────────────────────────────────
"@ -ForegroundColor Cyan
