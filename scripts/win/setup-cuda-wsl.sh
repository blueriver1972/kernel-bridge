#!/usr/bin/env bash
# kernel-bridge — WSL2 안에 CUDA Toolkit 설치 (Phase 1 기준선용)
#
#   bash scripts/win/setup-cuda-wsl.sh
#
# Windows 에 CUDA 를 설치하지 않는다. WSL2 가 Windows 드라이버를 통해
# GPU 를 직접 쓴다 (/dev/dxg + /usr/lib/wsl/lib/libcuda.so).
#
# ★ 중요: WSL 전용 저장소(wsl-ubuntu)를 쓰고 **드라이버는 설치하지 않는다.**
#   'cuda' 나 'cuda-drivers' 를 설치하면 리눅스 드라이버가 들어와
#   WSL 의 GPU 패스스루가 깨진다. cuda-toolkit-* 만 넣는다.
set -uo pipefail

# 드라이버 560.94 = CUDA 12.6 까지 지원. Maxwell(sm_52)은 CUDA 12.x 에서
# deprecated 이지만 아직 지원된다 (13.0 에서 제거).
CUDA_PKG="${CUDA_PKG:-cuda-toolkit-12-6}"

info() { printf '\033[36m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  X   %s\033[0m\n' "$*"; exit 1; }

info "GPU 패스스루 확인"
[ -e /dev/dxg ] || die "/dev/dxg 가 없습니다. WSL2 GPU 패스스루가 동작하지 않습니다."
/usr/lib/wsl/lib/nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader \
    || die "nvidia-smi 실패 — Windows NVIDIA 드라이버를 확인하세요."
ok "GPU 접근 가능"

if command -v nvcc >/dev/null 2>&1; then
    ok "nvcc 이미 설치됨: $(nvcc --version | tail -1)"
else
    info "NVIDIA apt 저장소 등록 (wsl-ubuntu)"
    cd /tmp
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb \
        || die "키링 다운로드 실패"
    sudo dpkg -i cuda-keyring_1.1-1_all.deb >/dev/null || die "키링 설치 실패"
    sudo apt-get update -qq || die "apt update 실패"

    info "$CUDA_PKG 설치 (약 3GB — 시간이 걸립니다)"
    sudo apt-get install -y "$CUDA_PKG" || die "설치 실패"
    ok "설치 완료"
fi

export PATH=/usr/local/cuda/bin:$PATH
command -v nvcc >/dev/null 2>&1 || die "nvcc 를 PATH 에서 찾을 수 없습니다."

info "sm_52 코드 생성 검증"
cat > /tmp/t.cu <<'EOF'
#include <cstdio>
__global__ void k(float* o){ o[threadIdx.x] = 1.0f; }
int main(){
    cudaDeviceProp p; cudaGetDeviceProperties(&p, 0);
    printf("[GPU] %s  sm_%d%d  %.1f GB\n", p.name, p.major, p.minor,
           p.totalGlobalMem / 1073741824.0);
    float* d; cudaMalloc(&d, 128*sizeof(float));
    k<<<1,128>>>(d);
    cudaError_t e = cudaDeviceSynchronize();
    printf("[RUN] %s\n", e == cudaSuccess ? "OK" : cudaGetErrorString(e));
    cudaFree(d);
    return e != cudaSuccess;
}
EOF
nvcc -O3 -arch=sm_52 /tmp/t.cu -o /tmp/t || die "sm_52 컴파일 실패"
/tmp/t || die "커널 실행 실패"
ok "sm_52 컴파일 + 실행 확인"

cat <<EOF

────────────────────────────────────────────────────────────
준비 완료. PATH 에 CUDA 를 추가하세요 (한 번만):

  echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc

그다음 Phase 1:

  NV_ARCH=sm_52 bash scripts/10_baseline_nvidia.sh
────────────────────────────────────────────────────────────
EOF
