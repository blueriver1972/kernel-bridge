# 03-verify — MI300X 검증

결과는 [verify.md](verify.md) 에, 원시 로그는 `raw/` 에 들어간다.

## 전제 — 이걸 지켜야 예산이 지켜진다
`scripts/21_build_hip.sh` 가 **GPU 없이 전부 컴파일 통과한 뒤에만** 이 단계로 온다.
여기서 처음 마주치는 것은 런타임 오류뿐이어야 한다.

## 실행
```bash
bash scripts/30_verify_mi300x.sh
```

## 할 일
- [ ] RunPod MI300X + `rocm/pytorch` 이미지 기동, `rocm-smi` / `hipcc --version` 확인
- [ ] `scripts/30_verify_mi300x.sh` 실행
- [ ] 정확도 PASS 여부 기록 → `raw/accuracy-summary.txt`
- [ ] 실행 시간(ms) 을 `verify.md` 비교표로 (NVIDIA 는 **fp32 열**만 사용)
- [ ] rocprof 로 병목 커널 1개 식별 (여유 있으면 튜닝 1건, 전/후 기록)
- [ ] ROCm 버전 / 드라이버 기록
- [ ] 인스턴스 즉시 종료

## ⚠ 정확도 불일치가 나오면 먼저 볼 곳
`common.h` 의 `#define WARP_SIZE 32U` (scope.md R1). 웨이브프런트 64에서
리덕션이 절반만 집계돼도 **컴파일은 통과하고 크래시도 나지 않는다.**
`validate_result` 가 유일한 방어선이다.
