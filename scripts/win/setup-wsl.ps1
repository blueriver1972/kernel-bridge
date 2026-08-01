# kernel-bridge — WSL2 준비 (★ 관리자 PowerShell 에서 실행 ★)
#
# 목적: Phase 2(hipify + hipcc 컴파일)를 GPU 없이 로컬에서 돌리기 위한 리눅스 환경.
#
# 이 PC 실측 (2026-08-02):
#   - WSL / Virtual Machine Platform 기능: 이미 활성 → Windows 기능 켜기·재부팅 불필요
#   - WSL2 커널: 없음
#   - wsl.exe: inbox 구버전 (--version 미지원)
#   - Windows 10 22H2 (19045)
#   - ★ `wsl --update` 가 Windows Update 경로에서 무한 대기 (17분간 CPU 0.25s)
#     → 이 스크립트는 `--web-download` 로 Store/WU 를 우회한다
#
# 모든 wsl 호출에 타임아웃을 건다. 다시는 조용히 멈추지 않는다.

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = 1
$KernelPath = "$env:SystemRoot\system32\lxss\tools\kernel"

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK  $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  !   $m"   -ForegroundColor Yellow }
function Fail($m) { Write-Host "  X   $m"   -ForegroundColor Red }

# 타임아웃을 건 wsl 실행. 초과하면 죽이고 $false 를 돌려준다.
# 주의: 매개변수 이름으로 $Args 를 쓰면 안 된다 — PowerShell 자동 변수와 충돌해
#       명명된 인수로 넘겨도 빈 값이 된다.
function Invoke-WslTimed {
    param([string[]]$WslArgs, [int]$TimeoutSec = 300, [string]$Label = 'wsl')
    Write-Host "  > wsl $($WslArgs -join ' ')  (최대 $TimeoutSec 초)" -ForegroundColor DarkGray
    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $WslArgs -PassThru -NoNewWindow
    $null = $p.Handle   # ExitCode 를 읽으려면 핸들을 잡아둬야 한다
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Warn "$Label — ${TimeoutSec}초 초과. 중단합니다."
        try { $p.Kill() } catch {}
        return $false
    }
    if ($p.ExitCode -ne 0) { Warn "$Label — 종료 코드 $($p.ExitCode)"; return $false }
    return $true
}

# --- 0. 권한 --------------------------------------------------------------
$pr = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "관리자 권한이 필요합니다. PowerShell 우클릭 > '관리자 권한으로 실행'"
    exit 1
}
Ok "관리자 권한 확인"

# 이전 시도가 남긴 멈춘 프로세스 정리
Get-Process wsl -ErrorAction SilentlyContinue | ForEach-Object {
    Warn "이전 wsl 프로세스(PID $($_.Id)) 종료"
    try { $_.Kill() } catch {}
}

# --- 1. WSL2 커널 ---------------------------------------------------------
Step "WSL2 커널 설치"
if (Test-Path $KernelPath) {
    Ok "커널 이미 있음"
} else {
    # ★ --web-download 를 먼저 쓴다. 이 PC 에서 plain --update 는 멈춘다.
    if (-not (Invoke-WslTimed -WslArgs @('--update','--web-download') -TimeoutSec 420 -Label 'wsl --update --web-download')) {
        Warn "웹 다운로드 실패. 표준 경로로 한 번 더 시도합니다."
        Invoke-WslTimed -WslArgs @('--update') -TimeoutSec 180 -Label 'wsl --update' | Out-Null
    }

    if (Test-Path $KernelPath) {
        Ok "커널 설치 완료"
    } else {
        Fail "커널이 설치되지 않았습니다."
        Write-Host @"

  수동 설치가 필요합니다 (1회, 약 15MB):
    1) https://aka.ms/wsl2kernel  접속
    2) 'WSL2 Linux 커널 업데이트 패키지' MSI 다운로드
    3) 실행 후 이 스크립트를 다시 돌리세요
"@ -ForegroundColor Yellow
        exit 1
    }
}

# --- 2. 기본 버전 2 --------------------------------------------------------
Step "기본 WSL 버전을 2로 설정"
Invoke-WslTimed -WslArgs @('--set-default-version','2') -TimeoutSec 60 -Label 'set-default-version' | Out-Null
Ok "완료 (Docker 는 WSL2 에서만 동작)"

# --- 3. Ubuntu ------------------------------------------------------------
Step "Ubuntu-22.04 설치"
$distro = 'Ubuntu-22.04'
$installed = Invoke-WslTimed -WslArgs @('--install','-d',$distro) -TimeoutSec 900 -Label 'wsl --install'

if (-not $installed) {
    Warn "Store 경유 설치가 실패하거나 멈췄습니다."
    Write-Host @"

  Store 를 우회해 직접 받는 방법 (약 600MB — 직접 판단해서 실행하세요):

    Invoke-WebRequest -Uri https://aka.ms/wslubuntu2204 ``
        -OutFile "`$env:TEMP\ubuntu2204.appx" -UseBasicParsing
    Add-AppxPackage "`$env:TEMP\ubuntu2204.appx"

  설치 후 시작 메뉴에서 Ubuntu 를 한 번 실행하세요.
"@ -ForegroundColor Yellow
    exit 1
}

Write-Host @"

────────────────────────────────────────────────────────────
여기부터는 직접 하셔야 합니다.

1) Ubuntu 창에서 UNIX 사용자명과 비밀번호를 입력하세요.
   (계정 생성은 사람이 합니다 — 대신 만들어 드리지 않습니다)

2) 그다음 ROCm 컨테이너 환경 준비:

     wsl -d $distro -- bash /mnt/d/onedrive/문서/Claude/Projects/kernel-bridge/scripts/win/setup-rocm-container.sh
────────────────────────────────────────────────────────────
"@ -ForegroundColor Cyan
