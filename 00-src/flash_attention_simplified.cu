// ============================================================================
// FlashAttention 단순화 교육용 커널 (Forward만, 개념 전달 목적)
//
// 실제 FlashAttention-2 (Tri Dao) 는 수천 줄 + 템플릿 메타프로그래밍이지만,
// 여기서는 "커스텀 커널 엔지니어가 뭘 하는가"가 보이도록 뼈대만 남겼습니다.
//
// 비교 대상 (naive PyTorch):
//   S = Q @ K^T          -> N x N 행렬을 HBM에 write
//   P = softmax(S)       -> HBM read + write
//   O = P @ V            -> HBM read
//
// 이 커널: 세 단계를 하나의 커널로 융합.
//   N x N 행렬 S, P 는 HBM 에 "존재한 적이 없음".
//   타일 단위로 공유 메모리(SRAM)에서 계산하고,
//   softmax 는 "online softmax" 트릭으로 누적 보정.
// ============================================================================

#include <cuda_runtime.h>
#include <math_constants.h>   // CUDART_INF_F

// ---- 튜닝 파라미터: 바로 이 숫자들이 "하드웨어 종속" 지점 ----------------
// Br x d, Bc x d 타일 3~4개가 SM 의 공유 메모리(예: A100 = 최대 164KB)에
// 들어가도록 정한다. AMD MI300X 는 LDS 64KB + 웨이브 64 이므로
// 이 값과 스레드 배치를 전부 다시 설계해야 성능이 나온다.
#define Br 64        // Q 를 한 번에 처리하는 행(row) 블록 크기
#define Bc 64        // K, V 를 한 번에 처리하는 열(col) 블록 크기
#define HEAD_DIM 64  // d: 어텐션 헤드 차원 (단순화를 위해 고정)

// ============================================================================
// 커널: 스레드블록 하나가 "Q 의 Br 개 행" 을 담당한다.
//   grid  = (N / Br, num_heads, batch)
//   block = (Br)  -- 단순화: 스레드 1개가 Q 의 행 1개를 맡음
//                    (실전은 워프 단위 협업 + 텐서코어 MMA 지만 개념은 동일)
// ============================================================================
__global__ void flash_attention_fwd(
    const float* __restrict__ Q,   // [N, d]
    const float* __restrict__ K,   // [N, d]
    const float* __restrict__ V,   // [N, d]
    float*       __restrict__ O,   // [N, d]  최종 출력
    int N, float softmax_scale)    // scale = 1/sqrt(d)
{
    // ------------------------------------------------------------------
    // (1) 공유 메모리 확보 -- FlashAttention 의 심장.
    //     K, V 타일을 HBM 에서 "한 번만" 읽어 SRAM 에 올려두고
    //     블록 내 모든 스레드가 재사용한다. (HBM ~2TB/s vs SRAM ~19TB/s)
    // ------------------------------------------------------------------
    __shared__ float Kj[Bc][HEAD_DIM];   // K 타일
    __shared__ float Vj[Bc][HEAD_DIM];   // V 타일

    const int row = blockIdx.x * Br + threadIdx.x;  // 내가 담당하는 Q 의 행
    if (row >= N) return;

    // ------------------------------------------------------------------
    // (2) 내 Q 행 하나를 레지스터에 상주시킴 (루프 내내 재사용)
    // ------------------------------------------------------------------
    float q[HEAD_DIM];
    #pragma unroll
    for (int k = 0; k < HEAD_DIM; ++k)
        q[k] = Q[row * HEAD_DIM + k];

    // ------------------------------------------------------------------
    // (3) online softmax 를 위한 3개의 "누적 상태"
    //     m   : 지금까지 본 점수들의 최댓값 (수치 안정용)
    //     l   : 지금까지의 softmax 분모 (exp 합)
    //     acc : 지금까지의 출력 누적값 (아직 분모로 안 나눈 상태)
    // ------------------------------------------------------------------
    float m = -CUDART_INF_F;
    float l = 0.0f;
    float acc[HEAD_DIM];
    #pragma unroll
    for (int k = 0; k < HEAD_DIM; ++k) acc[k] = 0.0f;

    // ==================================================================
    // (4) 바깥 루프: K/V 를 Bc 짜리 타일로 순회 (시퀀스 방향)
    //     -- naive 구현이라면 이 루프 전체 결과(N x N)를 HBM 에 썼을 것
    // ==================================================================
    for (int tile = 0; tile < N; tile += Bc) {

        // ---- (4a) K, V 타일을 협력 로드: 블록의 스레드들이 나눠서 복사 ----
        for (int i = threadIdx.x; i < Bc; i += blockDim.x) {
            int src = tile + i;
            #pragma unroll
            for (int k = 0; k < HEAD_DIM; ++k) {
                Kj[i][k] = (src < N) ? K[src * HEAD_DIM + k] : 0.0f;
                Vj[i][k] = (src < N) ? V[src * HEAD_DIM + k] : 0.0f;
            }
        }
        __syncthreads();   // 타일 로드 완료 대기 (블록 배리어)

        // ---- (4b) 이 타일에 대한 점수 s_j = q . k_j 를 계산하며
        //           타일 내 최댓값 m_tile 을 구한다 ----
        float s[Bc];
        float m_tile = -CUDART_INF_F;
        for (int j = 0; j < Bc && (tile + j) < N; ++j) {
            float dot = 0.0f;
            #pragma unroll
            for (int k = 0; k < HEAD_DIM; ++k)
                dot += q[k] * Kj[j][k];
            s[j] = dot * softmax_scale;
            m_tile = fmaxf(m_tile, s[j]);
        }

        // ---- (4c) ★ online softmax 보정 -- 이 커널의 수학적 핵심 ★
        //
        // 새 타일의 최댓값이 기존 m 보다 크면, 지금까지 누적한
        // l 과 acc 는 "옛 기준(m)" 으로 계산된 값이므로
        // exp(m - m_new) 를 곱해 새 기준으로 재조정한다.
        //
        //   softmax 항등식:  exp(s - m_old) = exp(s - m_new) * exp(m_new - m_old)
        //
        // 덕분에 행 전체를 다 보기 전에도 부분 결과를 안전하게 누적 가능.
        // 이 트릭이 없으면 softmax 는 행 전체(N개)를 요구하므로
        // N x N 행렬의 물질화(materialization)를 피할 수 없다.
        // ------------------------------------------------------------------
        float m_new = fmaxf(m, m_tile);
        float correction = __expf(m - m_new);   // 기존 누적분 재조정 계수

        l *= correction;
        #pragma unroll
        for (int k = 0; k < HEAD_DIM; ++k)
            acc[k] *= correction;

        // ---- (4d) 이 타일의 기여분을 누적: P 를 저장하지 않고 즉시 V 와 곱함 ----
        for (int j = 0; j < Bc && (tile + j) < N; ++j) {
            float p = __expf(s[j] - m_new);     // softmax 분자 (아직 미정규화)
            l += p;
            #pragma unroll
            for (int k = 0; k < HEAD_DIM; ++k)
                acc[k] += p * Vj[j][k];         // P @ V 를 그 자리에서 융합
        }

        m = m_new;
        __syncthreads();   // 다음 타일이 공유 메모리를 덮어쓰기 전 대기
    }

    // ------------------------------------------------------------------
    // (5) 마지막에 단 한 번, 분모 l 로 나눠 정규화 후 HBM 에 기록.
    //     HBM write 는 여기 "한 번" 뿐이다. (naive 는 3회 왕복)
    // ------------------------------------------------------------------
    float inv_l = 1.0f / l;
    #pragma unroll
    for (int k = 0; k < HEAD_DIM; ++k)
        O[row * HEAD_DIM + k] = acc[k] * inv_l;
}

// ============================================================================
// 호스트 측 실행 예시
// ============================================================================
void launch_flash_attention(const float* Q, const float* K, const float* V,
                            float* O, int N)
{
    dim3 grid((N + Br - 1) / Br);
    dim3 block(Br);
    float scale = rsqrtf((float)HEAD_DIM);
    flash_attention_fwd<<<grid, block>>>(Q, K, V, O, N, scale);
}

// ============================================================================
// [실전과의 차이 -- 이 파일에서 생략한 것들]
//  1. 텐서코어(MMA) 미사용: 실전은 (4b)(4d)의 내적/누적을 워프 단위
//     wmma/mma.sync 명령으로 처리 -> 여기서 다시 5~10배 차이가 남
//  2. 스레드당 1행 배정: 실전은 워프(32스레드)가 행 여러 개를 협업 처리,
//     레지스터 타일링으로 occupancy 와 재사용률을 극한까지 조정
//  3. causal mask, dropout, 가변 시퀀스 길이, backward pass 생략
//  4. half/bfloat16 미사용 (실전은 fp16 로드 + fp32 누적 혼합 정밀도)
//
// [AMD CDNA 포팅 시 재설계가 필요한 지점 -- "문법 변환으로 안 되는" 부분]
//  - Br/Bc 타일 크기: LDS 64KB 기준으로 재산정
//  - 워프 32 가정 -> 웨이브프런트 64 로 스레드 협업 구조 변경
//  - mma.sync -> MFMA (Matrix Core) 명령, 요구하는 행렬 조각 모양이 다름
//  - __expf 등 intrinsic 의 지연시간/처리량 특성 차이에 따른 루프 재배치
// ============================================================================
