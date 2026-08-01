// ============================================================================
// flash_attention_simplified.cu 용 정확도 검증 + 타이밍 하네스
//
// 원본 커널 파일은 수정하지 않는다. 별도 translation unit 으로 두고
// launch_flash_attention 만 extern 링크로 끌어 쓴다.
//   nvcc -O3 flash_attention_simplified.cu flash_attention_test.cu -o flash_test
//   hipcc -O3 *.hip.cpp -o flash_test
//
// 출력은 [RESULT] 한 줄로 고정한다 — 01-baseline/baseline.md 와
// 03-verify/verify.md 를 사람이 옮겨 적을 때 해석 여지를 없애기 위함.
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <cuda_runtime.h>

// 원본 커널의 #define 과 반드시 일치해야 한다 (원본 불변 원칙 때문에 중복 정의).
// 원본에서 값을 바꾸면 여기도 바꾼다.
#define HEAD_DIM 64
#define BLOCK_ROWS 64   // 원본의 Br. N 이 이 값의 배수여야 하는 이유는 아래 주석 참조.

// 원본 파일이 제공하는 유일한 진입점
void launch_flash_attention(const float* Q, const float* K, const float* V,
                            float* O, int N);

#define CUDA_CHECK(expr)                                                       \
    do {                                                                       \
        cudaError_t _e = (expr);                                               \
        if (_e != cudaSuccess) {                                               \
            std::fprintf(stderr, "[FATAL] %s:%d %s -> %s\n", __FILE__,         \
                         __LINE__, #expr, cudaGetErrorString(_e));             \
            std::exit(1);                                                      \
        }                                                                      \
    } while (0)

// ---------------------------------------------------------------------------
// 결정적 난수: rand() 는 libc 구현마다 수열이 달라서 NVIDIA 와 MI300X 가
// "서로 다른 입력"으로 측정되는 사고가 난다. 두 플랫폼에서 비트 단위로
// 동일한 입력을 보장하려고 xorshift32 를 직접 쓴다.
// ---------------------------------------------------------------------------
static unsigned int rng_state = 0x13572468u;
static inline float next_uniform()   // [-1, 1)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (float)((double)rng_state / 2147483648.0) - 1.0f;
}

// ---------------------------------------------------------------------------
// CPU 레퍼런스: 정직한 3단계 attention. 누적은 double 로 한다.
// (fp32 로 누적하면 레퍼런스 자신의 오차가 판정 기준을 흔든다)
// ---------------------------------------------------------------------------
static void attention_reference(const std::vector<float>& Q,
                                const std::vector<float>& K,
                                const std::vector<float>& V,
                                std::vector<double>& O, int N, double scale)
{
    std::vector<double> s((size_t)N);
    for (int i = 0; i < N; ++i) {
        double m = -INFINITY;
        for (int j = 0; j < N; ++j) {
            double dot = 0.0;
            for (int k = 0; k < HEAD_DIM; ++k)
                dot += (double)Q[(size_t)i * HEAD_DIM + k] *
                       (double)K[(size_t)j * HEAD_DIM + k];
            s[j] = dot * scale;
            if (s[j] > m) m = s[j];
        }
        double l = 0.0;
        for (int j = 0; j < N; ++j) { s[j] = std::exp(s[j] - m); l += s[j]; }

        for (int k = 0; k < HEAD_DIM; ++k) {
            double acc = 0.0;
            for (int j = 0; j < N; ++j)
                acc += s[j] * (double)V[(size_t)j * HEAD_DIM + k];
            O[(size_t)i * HEAD_DIM + k] = acc / l;
        }
    }
}

int main(int argc, char** argv)
{
    int    N        = (argc > 1) ? std::atoi(argv[1]) : 1024;
    double tol      = (argc > 2) ? std::atof(argv[2]) : 1e-3;   // 상대 오차 허용치
    int    iters    = (argc > 3) ? std::atoi(argv[3]) : 50;
    const int warmup = 10;

    // 원본 커널은 `if (row >= N) return;` 뒤에 __syncthreads() 를 호출한다.
    // 블록 일부 스레드만 배리어에 도달하는 형태라 N 이 BLOCK_ROWS 의 배수가
    // 아니면 정의되지 않은 동작이다. NVIDIA 에서 우연히 통과하더라도
    // AMD 웨이브프런트에서 같으리라는 보장이 없으므로 여기서 막는다.
    // (이 제약 자체가 이식 시 [MANUAL] 로 기록되어야 할 항목이다 — logs/ 참조)
    if (N % BLOCK_ROWS != 0) {
        std::fprintf(stderr,
            "[FATAL] N(%d) 은 %d 의 배수여야 합니다 "
            "(커널의 divergent __syncthreads() 제약).\n", N, BLOCK_ROWS);
        return 1;
    }

    int dev = 0;
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDevice(&dev));
    CUDA_CHECK(cudaGetDeviceProperties(&prop, dev));

    const size_t elems = (size_t)N * HEAD_DIM;
    const double scale = 1.0 / std::sqrt((double)HEAD_DIM);

    std::vector<float> hQ(elems), hK(elems), hV(elems), hO(elems);
    for (size_t i = 0; i < elems; ++i) hQ[i] = next_uniform();
    for (size_t i = 0; i < elems; ++i) hK[i] = next_uniform();
    for (size_t i = 0; i < elems; ++i) hV[i] = next_uniform();

    float *dQ, *dK, *dV, *dO;
    CUDA_CHECK(cudaMalloc(&dQ, elems * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dK, elems * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dV, elems * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&dO, elems * sizeof(float)));
    CUDA_CHECK(cudaMemcpy(dQ, hQ.data(), elems * sizeof(float), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dK, hK.data(), elems * sizeof(float), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(dV, hV.data(), elems * sizeof(float), cudaMemcpyHostToDevice));

    // ---- 정확도 -----------------------------------------------------------
    launch_flash_attention(dQ, dK, dV, dO, N);
    CUDA_CHECK(cudaGetLastError());          // 런치 실패를 조용히 넘기지 않는다
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaMemcpy(hO.data(), dO, elems * sizeof(float), cudaMemcpyDeviceToHost));

    std::vector<double> refO(elems);
    attention_reference(hQ, hK, hV, refO, N, scale);

    double max_abs = 0.0, ref_absmax = 0.0;
    size_t worst = 0;
    for (size_t i = 0; i < elems; ++i) {
        double d = std::fabs((double)hO[i] - refO[i]);
        if (d > max_abs) { max_abs = d; worst = i; }
        double a = std::fabs(refO[i]);
        if (a > ref_absmax) ref_absmax = a;
    }
    // 원소별 상대오차는 참값이 0 근처일 때 폭발하므로 출력 스케일로 정규화한다.
    double max_rel = (ref_absmax > 0.0) ? (max_abs / ref_absmax) : max_abs;
    const bool pass = (max_rel <= tol) && std::isfinite(max_rel);

    // ---- 타이밍 -----------------------------------------------------------
    cudaEvent_t ev0, ev1;
    CUDA_CHECK(cudaEventCreate(&ev0));
    CUDA_CHECK(cudaEventCreate(&ev1));
    for (int i = 0; i < warmup; ++i) launch_flash_attention(dQ, dK, dV, dO, N);
    CUDA_CHECK(cudaDeviceSynchronize());

    CUDA_CHECK(cudaEventRecord(ev0));
    for (int i = 0; i < iters; ++i) launch_flash_attention(dQ, dK, dV, dO, N);
    CUDA_CHECK(cudaEventRecord(ev1));
    CUDA_CHECK(cudaEventSynchronize(ev1));
    float total_ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&total_ms, ev0, ev1));
    const double ms = total_ms / iters;

    // QK^T 와 P@V 각각 2*N*N*d flop
    const double gflops = (4.0 * (double)N * N * HEAD_DIM) / (ms * 1e-3) / 1e9;

    std::printf("[DEVICE] %s\n", prop.name);
    std::printf("[CONFIG] N=%d d=%d Br=%d iters=%d tol=%.1e\n",
                N, HEAD_DIM, BLOCK_ROWS, iters, tol);
    std::printf("[RESULT] kernel=flash_attention_fwd status=%s "
                "max_rel_err=%.3e max_abs_err=%.3e time_ms=%.4f gflops=%.1f\n",
                pass ? "PASS" : "FAIL", max_rel, max_abs, ms, gflops);
    if (!pass) {
        std::printf("[DEBUG] worst idx=%zu row=%zu col=%zu got=%.8f ref=%.8f\n",
                    worst, worst / HEAD_DIM, worst % HEAD_DIM,
                    (double)hO[worst], refO[worst]);
    }

    CUDA_CHECK(cudaEventDestroy(ev0));
    CUDA_CHECK(cudaEventDestroy(ev1));
    CUDA_CHECK(cudaFree(dQ)); CUDA_CHECK(cudaFree(dK));
    CUDA_CHECK(cudaFree(dV)); CUDA_CHECK(cudaFree(dO));
    return pass ? 0 : 1;
}
