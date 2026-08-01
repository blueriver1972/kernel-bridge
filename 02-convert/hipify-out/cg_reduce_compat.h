// ============================================================================
// [FIX-2] cooperative_groups/reduce.h 호환 계층  (scope.md R2)
//
// 문제:
//   CUDA 는 <cooperative_groups/reduce.h> 에서 cg::reduce 와 cg::plus /
//   cg::greater 펑터를 제공한다. ROCm 6.3 의 hip_cooperative_groups.h 에는
//   **reduce 가 아예 없다** (헤더 전체에 'reduce' 심볼 0건).
//   hipify-perl 은 include 경로를 그대로 두므로 'file not found' 로 죽는다.
//
// 이 파일이 하는 일:
//   타일의 shfl_down / shfl 만으로 cg::reduce 와 동일한 all-reduce 를 구성한다.
//   (HIP 타일은 shfl, shfl_down, shfl_up 만 제공한다 — shfl_xor 는 없다)
//
// 주의 — 이건 "문법 변환"이 아니라 사람이 판단해서 쓴 대체 구현이다:
//   * op 는 결합·교환법칙을 만족해야 한다. llm.c 가 쓰는 plus / greater /
//     softmax 의 (max,sum) 결합 연산은 모두 만족한다.
//   * __shfl 계열은 int/float 같은 스칼라만 받는다. SumMax 처럼 구조체를
//     넘기려면 word 단위로 쪼개 옮겨야 한다 (아래 shfl_*_any).
//   * cg::reduce 는 타일의 **모든** 스레드에 결과를 남긴다. shfl_down 방식은
//     lane 0 에만 정답이 모이므로 마지막에 브로드캐스트가 필요하다.
//     이걸 빠뜨리면 컴파일도 되고 크래시도 안 나면서 답만 틀린다.
// ============================================================================
#pragma once
#include <hip/hip_cooperative_groups.h>

namespace cooperative_groups {

// ---- CUDA 의 cg::plus / cg::greater 대응 ----------------------------------
template <class T> struct plus {
    __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a + b; }
};
template <class T> struct greater {
    __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a > b ? a : b; }
};
template <class T> struct less {
    __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a < b ? a : b; }
};

namespace kb_detail {

// 임의의 trivially-copyable 타입을 int word 단위로 shuffle 한다.
// float 는 word 1개, SumMax(float2) 는 2개.
template <class Tile, class T>
__device__ __forceinline__ T shfl_down_any(const Tile& t, T v, unsigned delta) {
    constexpr int NW = (int)((sizeof(T) + sizeof(int) - 1) / sizeof(int));
    union U { T val; int w[NW]; __device__ U() {} } u;
    u.val = v;
#pragma unroll
    for (int i = 0; i < NW; ++i) u.w[i] = t.shfl_down(u.w[i], delta);
    return u.val;
}

template <class Tile, class T>
__device__ __forceinline__ T shfl_any(const Tile& t, T v, int src) {
    constexpr int NW = (int)((sizeof(T) + sizeof(int) - 1) / sizeof(int));
    union U { T val; int w[NW]; __device__ U() {} } u;
    u.val = v;
#pragma unroll
    for (int i = 0; i < NW; ++i) u.w[i] = t.shfl(u.w[i], src);
    return u.val;
}

}  // namespace kb_detail

// ---- cg::reduce 대응 (all-reduce) ----------------------------------------
template <class Tile, class T, class Op>
__device__ __forceinline__ T reduce(const Tile& t, T val, Op op) {
    for (unsigned off = t.size() / 2u; off > 0u; off >>= 1)
        val = op(val, kb_detail::shfl_down_any(t, val, off));
    return kb_detail::shfl_any(t, val, 0);   // 모든 레인에 결과를 뿌린다
}

}  // namespace cooperative_groups
