# MI300X 검증 결과 (실측)

> 채우는 법: `scripts/30_verify_mi300x.sh` 실행 후 `03-verify/raw/*.log` 에서 옮긴다.
> NVIDIA 열은 [01-baseline/baseline.md](../01-baseline/baseline.md) 의 **fp32 열**만 쓴다.

## 환경 (raw/env.txt 에서)

| 항목 | 값 |
|---|---|
| GPU | MI300X |
| ROCm 버전 | |
| 드라이버 | |
| offload-arch | gfx942 |
| 컴파일 플래그 | `-O3 -ffast-math --offload-arch=gfx942 -lhipblas -lhipblaslt` |
| 측정 일시 | |
| 클라우드 | RunPod / TensorWave |

## 비교표

상대 성능 % = NVIDIA ms ÷ MI300X ms × 100 (100% 초과 = MI300X 가 빠름)

| 파일 | 커널 # | 정확도 | NVIDIA ms (fp32) | MI300X ms | 상대 성능 % | 비고 |
|---|---|---|---|---|---|---|
| softmax | 1 | | | | | |
| softmax | 2 | | | | | |
| softmax | 3 | | | | | |
| softmax | 4 | | | | | |
| softmax | 5 | | | | | |
| softmax | 6 | | | | | |
| softmax | 7 | | | | | |
| softmax | 8 | | | | | |
| attention | 1 | | | | | |
| attention | 2 | | | | | |
| attention | 3 | | | | | |
| attention | 4 | | | | | |
| attention | 5 | | | | | |
| attention | 6 | | | | | |
| flash | — | | | | | |

정확도 합계: **___ / ___ 항목 PASS**

## 정확도 불일치 항목 (있다면)

`scope.md` R1(WARP_SIZE 32 하드코딩)이 남아 있으면 **컴파일은 통과하고 답만 틀린다.**
불일치가 나오면 먼저 여기를 의심한다.

| 커널 | 증상 | 원인 | 해결 | 태그 |
|---|---|---|---|---|
| | | | | |

## 병목 커널 (rocprof)

| 순위 | 커널명 | 총 시간 | 호출 수 | 비중 % |
|---|---|---|---|---|
| 1 | | | | |

## 튜닝 1건 (선택)

| 항목 | 값 |
|---|---|
| 대상 커널 | |
| 변경 내용 | (블록 크기 / 타일 / 웨이브 정렬) |
| 전 (ms) | |
| 후 (ms) | |
| 개선률 | |
