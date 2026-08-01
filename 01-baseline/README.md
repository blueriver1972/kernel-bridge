# 01-baseline — NVIDIA 기준선

결과는 [baseline.md](baseline.md) 에, 원시 로그는 `raw/` 에 들어간다.

## 실행
```bash
NV_ARCH=sm_80 bash scripts/10_baseline_nvidia.sh   # A100. H100 이면 sm_90
```
빌드 → 환경 기록 → 커널 버전 전수 실행까지 한 번에 돈다.

## 할 일
- [ ] NVIDIA GPU 인스턴스 확보 — **A100 또는 H100** (~$3/h × 1~2h)
      4090 은 데이터센터급 MI300X 와 대비했을 때 보고서 신뢰도가 떨어진다
- [ ] `scripts/00_fetch_sources.sh` 로 llm.c 확보 (커밋 SHA 고정)
- [ ] `scripts/10_baseline_nvidia.sh` 실행
- [ ] `raw/*.log` → `baseline.md` 표로 옮기기
- [ ] `raw/env.txt` 의 GPU / 드라이버 / CUDA 버전 기록 (비교표의 각주가 된다)
- [ ] **`enable_tf32:` 출력값 확인** — fp32 빌드가 `0` 으로 나오는지
- [ ] 인스턴스 즉시 종료

## ⚠ 이 단계에서 틀리면 전체가 무의미해지는 것
llm.c 는 A100/H100 에서 cuBLAS TF32 를 자동으로 켠다.
그대로 잰 ms 를 MI300X fp32 와 비교하면 **하드웨어 차이가 아니라 정밀도 차이**를
성능 격차로 발표하게 된다. 스크립트가 fp32 강제 빌드를 따로 만드는 이유다.
자세한 내용은 [02-convert/scope.md](../02-convert/scope.md) §3.
