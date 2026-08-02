// ============================================================================
// 데모용 출력 덤프 (report/demo-plan.md 장치 1)
//
// flash_attention_test.cu 와 **일부러 분리**했다.
//   하네스를 건드리면 hipify 재실행이 필요해지고,
//   02-convert/hipify-out/ 의 git diff 가 곧 "사람이 한 수정" 지표라
//   그 측정이 오염된다. 그래서 커널만 공유하는 별도 실행파일로 둔다.
//
// 하는 일: 커널을 한 번 돌려 출력 행렬 O 를 raw float32 로 저장한다.
//   NVIDIA 에서 한 번, MI300X 에서 한 번 떠서 두 파일을 비교하면
//   "두 GPU 가 같은 답을 냈는가"가 그림 한 장으로 나온다.
//
// 빌드:
//   nvcc -O3 --use_fast_math -arch=sm_XX flash_attention_simplified.cu \
//        flash_attention_dump.cu -o flash_dump
//   hipcc -O3 --offload-arch=gfx942 *.hip.cpp -o flash_dump
// 사용:
//   ./flash_dump <N> <출력파일>
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cuda_runtime.h>

#define HEAD_DIM 64      // 원본 커널의 값과 일치해야 한다
#define BLOCK_ROWS 64    // 원본의 Br

void launch_flash_attention(const float* Q, const float* K, const float* V,
                            float* O, int N);

#define CK(expr)                                                               \
    do {                                                                       \
        cudaError_t _e = (expr);                                               \
        if (_e != cudaSuccess) {                                               \
            std::fprintf(stderr, "[FATAL] %s:%d %s\n", __FILE__, __LINE__,     \
                         cudaGetErrorString(_e));                              \
            std::exit(1);                                                      \
        }                                                                      \
    } while (0)

// flash_attention_test.cu 와 **완전히 같은** 난수. 두 플랫폼이 같은 입력을
// 받아야 비교가 의미를 갖는다. libc 의 rand() 는 구현마다 달라 쓸 수 없다.
static unsigned int rng_state = 0x13572468u;
static inline float next_uniform()
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (float)((double)rng_state / 2147483648.0) - 1.0f;
}

int main(int argc, char** argv)
{
    const int   N    = (argc > 1) ? std::atoi(argv[1]) : 1024;
    const char* path = (argc > 2) ? argv[2] : "out.bin";

    if (N % BLOCK_ROWS != 0) {
        std::fprintf(stderr, "[FATAL] N(%d) 은 %d 의 배수여야 합니다.\n", N, BLOCK_ROWS);
        return 1;
    }

    const size_t elems = (size_t)N * HEAD_DIM;
    std::vector<float> hQ(elems), hK(elems), hV(elems), hO(elems);
    for (size_t i = 0; i < elems; ++i) hQ[i] = next_uniform();
    for (size_t i = 0; i < elems; ++i) hK[i] = next_uniform();
    for (size_t i = 0; i < elems; ++i) hV[i] = next_uniform();

    float *dQ, *dK, *dV, *dO;
    CK(cudaMalloc(&dQ, elems * sizeof(float)));
    CK(cudaMalloc(&dK, elems * sizeof(float)));
    CK(cudaMalloc(&dV, elems * sizeof(float)));
    CK(cudaMalloc(&dO, elems * sizeof(float)));
    CK(cudaMemcpy(dQ, hQ.data(), elems * sizeof(float), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dK, hK.data(), elems * sizeof(float), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dV, hV.data(), elems * sizeof(float), cudaMemcpyHostToDevice));

    launch_flash_attention(dQ, dK, dV, dO, N);
    CK(cudaGetLastError());
    CK(cudaDeviceSynchronize());
    CK(cudaMemcpy(hO.data(), dO, elems * sizeof(float), cudaMemcpyDeviceToHost));

    // 헤더 없는 raw float32. 형태는 (N, HEAD_DIM) 이며 렌더러가 인자로 받는다.
    FILE* f = std::fopen(path, "wb");
    if (!f) { std::fprintf(stderr, "[FATAL] 파일 열기 실패: %s\n", path); return 1; }
    std::fwrite(hO.data(), sizeof(float), elems, f);
    std::fclose(f);

    cudaDeviceProp prop;
    CK(cudaGetDeviceProperties(&prop, 0));
    std::printf("[DUMP] device=%s N=%d d=%d -> %s (%zu bytes)\n",
                prop.name, N, HEAD_DIM, path, elems * sizeof(float));

    CK(cudaFree(dQ)); CK(cudaFree(dK)); CK(cudaFree(dV)); CK(cudaFree(dO));
    return 0;
}
