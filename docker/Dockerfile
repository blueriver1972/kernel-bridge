# kernel-bridge Phase 2 빌드 환경 (GPU 불필요)
#
# 빌드:
#   docker build -t kernel-bridge/rocm:6.3 docker/
# 사용:
#   docker run --rm -it -v "$PWD":/w -w /w kernel-bridge/rocm:6.3 bash scripts/20_hipify.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# 왜 6.3 인가 (2026-08-02 실측, i7-6700K / WSL2 / docker)
#
# rocm/dev-ubuntu-22.04:**6.2** 는 이 환경에서 쓸 수 없다. LLVM 링커가 깨져 있다:
#     $ /opt/rocm/lib/llvm/bin/ld.lld --version
#     Segmentation fault
#   llvm-link, opt 도 같은 증상. 그 결과 device 코드 링크 단계에서 죽는다:
#     clang++: error: amdgcn-link command failed due to signal
#   호스트 C++ 컴파일과 device IR 생성(-emit-llvm)까지는 멀쩡히 되기 때문에
#   원인을 찾기 전까지 "HIP 코드가 잘못됐나" 로 오해하기 쉽다.
#
# **6.3** 은 동일 환경에서 전부 정상이고 gfx942 커널이 실제로 컴파일된다.
#     ld.lld OK / llvm-link OK / opt OK / gfx942 오브젝트 15312 bytes 생성
#
# 참고로 6.2 는 hipcc·hipify-perl 을 perl 스크립트로 넣고도 full perl 패키지를
# 빼먹어서 그것부터 걸린다 (File/Spec/Functions.pm did not return a true value).
# 아래 perl 설치는 그 대비이자 hipify-perl 을 위한 보험이다.
# ─────────────────────────────────────────────────────────────────────────────

FROM rocm/dev-ubuntu-22.04:6.3

# perl: hipify-perl 이 실제로 요구하는 것
# file, ca-certificates: 진단·다운로드 시 필요
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        perl \
        file \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# hipcc 를 PATH 앞쪽에 둔다 — /usr/bin/hipcc 에 가려지면 안 된다
ENV PATH=/opt/rocm/bin:/opt/rocm/llvm/bin:$PATH

# MI300X 기본 타깃 (GPU 없이 코드 생성만 하므로 반드시 명시해야 한다)
ENV AMD_ARCH=gfx942

WORKDIR /w
