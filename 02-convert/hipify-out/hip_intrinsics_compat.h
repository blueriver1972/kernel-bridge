// ============================================================================
// [FIX-4] CUDA 인트린식 호환 계층  (scope.md R3)
//
// hipify-perl 이 변환하지 못하고 그대로 남긴 것들을 채운다.
// 확인 결과 hipify 는 __shfl_*_sync / __syncwarp / __stcs 를 **손대지 않는다.**
//
// 이 헤더가 채우는 것:
//   __syncwarp()          HIP 에 없음
//   __stcs(...)           HIP 에 없음 (non-temporal store 로 대체)
//   __ldcs(const int4*)   HIP 에 스칼라용은 있으나 int4 오버로드가 없음
//
// __shfl_*_sync 는 **일부러 여기서 처리하지 않는다.**
//   CUDA 판은 (mask, var, lane) 3인자이고 폭이 항상 32로 암묵 고정이다.
//   AMD 는 웨이브가 64라 폭을 반드시 정해야 하는데, 그 값은 호출부마다 다르다
//   (같은 softmax_forward.cu 안에 32 가정 코드와 warpSize 사용 코드가 공존한다 — R4).
//   따라서 얇은 래퍼로 감추면 조용히 틀린 답이 나온다.
//   호출부에서 __shfl_xor(var, lane, width) 형태로 폭을 직접 적게 두었다.
//   → 이 판단이 이 프로젝트가 말하는 "사람이 필요한 구간"의 실물이다.
// ============================================================================
#pragma once
#include <hip/hip_runtime.h>

// ---- 워프 동기화 -----------------------------------------------------------
// CUDA 의 __syncwarp() 는 Volta 이후 독립 스레드 스케줄링 때문에 필요하다.
// AMD 웨이브프런트는 lock-step 이라 의미상 필요 없지만, 컴파일러가 메모리
// 연산 순서를 바꾸지 않도록 wave barrier 를 남겨 둔다.
__device__ __forceinline__ void __syncwarp() { __builtin_amdgcn_wave_barrier(); }
__device__ __forceinline__ void __syncwarp(unsigned) { __builtin_amdgcn_wave_barrier(); }

// ---- 캐시 스트리밍 store (CUDA __stcs) --------------------------------------
// "이 데이터는 재사용 안 하니 캐시를 오염시키지 말라"는 힌트.
// HIP 대응은 __builtin_nontemporal_store.
__device__ __forceinline__ void __stcs(float* p, float v)  { __builtin_nontemporal_store(v, p); }
__device__ __forceinline__ void __stcs(unsigned short* p, unsigned short v) { __builtin_nontemporal_store(v, p); }
__device__ __forceinline__ void __stcs(int* p, int v)      { __builtin_nontemporal_store(v, p); }

__device__ __forceinline__ void __stcs(int4* p, int4 v) {
    int* q = reinterpret_cast<int*>(p);
    __builtin_nontemporal_store(v.x, q + 0);
    __builtin_nontemporal_store(v.y, q + 1);
    __builtin_nontemporal_store(v.z, q + 2);
    __builtin_nontemporal_store(v.w, q + 3);
}

// ---- 캐시 스트리밍 load ------------------------------------------------------
// HIP 은 __half 용만 제공한다. float / int4 는 직접 채운다.
__device__ __forceinline__ float __ldcs(const float* p) { return __builtin_nontemporal_load(p); }
__device__ __forceinline__ int   __ldcs(const int* p)   { return __builtin_nontemporal_load(p); }
__device__ __forceinline__ unsigned short __ldcs(const unsigned short* p) {
    return __builtin_nontemporal_load(p);
}

__device__ __forceinline__ int4 __ldcs(const int4* p) {
    const int* q = reinterpret_cast<const int*>(p);
    int4 r;
    r.x = __builtin_nontemporal_load(q + 0);
    r.y = __builtin_nontemporal_load(q + 1);
    r.z = __builtin_nontemporal_load(q + 2);
    r.w = __builtin_nontemporal_load(q + 3);
    return r;
}
