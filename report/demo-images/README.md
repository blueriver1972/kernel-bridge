# demo-images — 무엇이 무엇인가

데모 장치 1("차이 이미지가 새까맣다")의 재료다. 설계 근거는 [../demo-plan.md](../demo-plan.md),
발표할 때 뭐라고 말할지는 [../presenter-guide.md](../presenter-guide.md) §구간 6.

---

## 1. 구조 한눈에

```
report/demo-images/
├── nvidia_970.bin        ← 기준. 세 비교 모두 이 파일이 "왼쪽"이다
├── nvidia_970_again.bin  ← 같은 GPU 에서 한 번 더 뽑은 것
├── broken_demo.bin       ← 일부러 버그를 넣고 뽑은 것
├── amd_mi300x.bin        ← MI300X 에서 뽑은 것
│
├── ok/      = nvidia_970  vs  nvidia_970_again   (같은 GPU 두 번)
├── real/    = nvidia_970  vs  amd_mi300x         ★ 진짜 결과
└── broken/  = nvidia_970  vs  broken_demo        대조군
```

**세 폴더 모두 왼쪽이 `nvidia_970.bin` 으로 고정돼 있다.** 기준을 하나로 두어야
세 그림을 나란히 비교할 수 있다.

## 2. `.bin` 은 무엇인가

그림이 아니라 **계산 결과 숫자 덩어리**다.

| | |
|---|---|
| 크기 | 262,144 바이트 |
| 내용 | float32 65,536개 = **1024행 × 64열 행렬** |
| 형식 | raw little-endian float32, 헤더 없음 |
| 만든 것 | `scripts/41_dump_reference.sh` (내부적으로 `00-src/flash_attention_dump.cu`) |

어텐션 커널의 출력 행렬을 그대로 저장한 것이다.

**입력은 결정적 난수(xorshift32)로 고정한다.** libc `rand()` 는 구현마다 값이 달라서
쓰지 않았다. 그래서 NVIDIA 와 AMD 에 **비트 단위로 동일한 입력**이 들어간다 —
두 출력이 같은 것이 우연이 아니라는 근거다.

## 3. 폴더 안의 PNG 4개

`scripts/40_demo_images.py` 가 `.bin` 두 개를 받아 한 번에 만든다.

| 파일 | 내용 | 크기 |
|---|---|---|
| `a.png` | 왼쪽 `.bin` 의 열지도 | 384 × 384 px |
| `b.png` | 오른쪽 `.bin` 의 열지도 | 384 × 384 px |
| `diff.png` | **두 값의 차이** \|a − b\| | 384 × 384 px |
| `compare.png` | 위 셋을 가로로 붙인 것 | **1184 × 384 px** |

**발표에는 `compare.png` 한 장만 쓴다.** 나머지 셋은 그 재료다.

행렬 1024행 중 **위 64행만** 그린다 (64행 × 64열, 픽셀당 6배 확대 = 384px).
전부 그리면 세로로 16배 길어져 화면에 안 맞는다. `--rows` 로 바꿀 수 있다.

## 4. ★ a·b 와 diff 는 색 기준이 다르다 — 이 도구에서 가장 중요한 결정

| | 색을 무엇에 맞추나 |
|---|---|
| `a.png`, `b.png` | **데이터 범위** (두 파일 전체의 최소~최대) |
| `diff.png` | **허용오차** — 검정=일치 · 파랑=허용 이내 · **빨강=허용 초과** |

`diff.png` 를 데이터 범위로 정규화하면 **명백한 오류도 검정으로 보인다.**
첫 버전이 실제로 그랬고 데모가 성립하지 않았다.
반대로 자기 범위로 정규화하면 오차가 0 에 가까워도 화려한 그림이 나와 **거짓말이 된다.**

→ 허용오차(기본 `1e-3`, llm.c 의 `validate_result` 와 같은 값) 기준으로 고정했다.

## 5. 세 폴더의 실측값

| 폴더 | 비교 대상 | 최대 절대오차 | 최대 상대오차 | 허용오차 대비 | `diff` 패널 |
|---|---|---|---|---|---|
| **`ok/`** | 같은 GPU 두 번 | 0.000e+00 | **0.000e+00** | — | 검정 |
| **`real/`** | NVIDIA vs **MI300X** | 2.980e-08 | **3.783e-07** | **2,600배 여유** | 검정 |
| **`broken/`** | 정상 vs 버그 | 1.666e-02 | **2.116e-01** | **212배 초과** | 불 들어옴 |

`broken` 은 `real` 보다 오차가 **약 56만 배** 크다.

픽셀 단위로 봐도 같은 결론이다:

| 폴더 | `a.png` 와 `b.png` 의 차이 |
|---|---|
| `ok/` | **0개** — 픽셀까지 완전히 동일 |
| `real/` | 36개 서브픽셀이 **1단계**(255 중 1) 차이 — **눈으로 구별 불가** |
| `broken/` | 369,720개 서브픽셀이 최대 **58단계** 차이 — 확실히 보임 |

그리고 **`real/diff.png` 와 `ok/diff.png` 는 바이트까지 동일하다.** 둘 다 완전한 검정이다.

## 6. `ok/` 가 왜 있는가 — 측정 도구 자체의 검증

처음엔 잉여로 보이지만, **`real/` 을 믿을 수 있게 만드는 것이 `ok/` 다.**

같은 GPU 에서 두 번 뽑으면 오차가 **정확히 0** 이다. 소수점 오차조차 없다. 즉:

> **이 도구는 아무 이유 없이 차이를 만들어내지 않는다.**

그래서 `real/` 의 `3.783e-07` 이 도구의 잡음이 아니라
**NVIDIA 와 AMD 가 소수를 더하는 순서가 달라서 생긴 진짜 값**이라고 말할 수 있다.

`ok/` 가 없으면 이 질문에 답할 수 없다:

> "그 검정이 그냥 도구가 항상 검정으로 그리는 건 아닌가요?"

**답**: "같은 GPU 에서 두 번 뽑아 비교하면 오차가 **정확히 0** 입니다.
도구가 잡음을 만들지 않는다는 확인이고, 그래서 3e-07 이 실제 값입니다."

## 7. `broken/` 은 조작이 아니다

`broken_demo.bin` 은 그림을 수정한 것이 아니라
**커널 코드를 실제로 망가뜨려 GPU 에서 돌린 결과**다.

online softmax 의 재조정 계수를 `correction = 1.0f` 로 고정했다 —
"이전까지 누적한 값을 새 최댓값 기준으로 다시 맞추는" 단계를 없앤 것이고,
**실제로 흔히 나는 실수**다.

```bash
BREAK=1 bash scripts/41_dump_reference.sh broken_demo 1024
```

`41_dump_reference.sh` 가 소스 **복사본**에 sed 로 주입하므로 원본은 건드리지 않는다.

지적당하면: **"조작한 그림이 아니라 실제로 틀리게 만들어 돌린 결과입니다."**

## 8. 발표에서 쓰는 순서 — 이것만은 지킬 것

**① `broken/compare.png` 를 먼저 → ② `real/compare.png` 를 나중에**

`real/` 만 먼저 보여주면 관객은 "원래 검정 아닌가?"라고 생각한다.
**불붙은 걸 먼저 봐야 검정이 "통과"로 읽힌다.**

`ok/` 는 슬라이드에 넣지 않고 **§6의 질문이 나올 때만** 꺼낸다.

## 9. 다시 만들려면

**GPU 가 필요 없다.** `.bin` 두 개만 있으면 된다.

```bash
# 실측 비교
python3 scripts/40_demo_images.py \
    report/demo-images/nvidia_970.bin \
    report/demo-images/amd_mi300x.bin \
    --labels NVIDIA MI300X --outdir report/demo-images/real

# 대조군
python3 scripts/40_demo_images.py \
    report/demo-images/nvidia_970.bin \
    report/demo-images/broken_demo.bin \
    --labels 정상 버그주입 --outdir report/demo-images/broken

# 도구 검증
python3 scripts/40_demo_images.py \
    report/demo-images/nvidia_970.bin \
    report/demo-images/nvidia_970_again.bin \
    --labels NVIDIA NVIDIA재실행 --outdir report/demo-images/ok
```

`40_demo_images.py` 는 **표준 라이브러리만** 쓴다 (PNG 를 zlib + CRC 로 직접 쓴다).
numpy·PIL 설치가 필요하면 클라우드 인스턴스에서 한 단계 더 막히기 때문이다.

종료 코드는 판정과 연동된다 — **일치하면 0, 불일치하면 1.**
자동화 파이프라인에서 그대로 쓸 수 있다.

### 유용한 옵션

| 옵션 | 기본값 | 용도 |
|---|---|---|
| `--tol` | `1e-3` | 차이 패널의 빨강 기준 (llm.c `validate_result` 와 동일) |
| `--rows` | `64` | 위에서 몇 행을 그릴지 |
| `--scale` | `6` | 픽셀 확대 배율 (발표 화면이 크면 올린다) |
| `-d` | `64` | 행렬의 열 수 (head dimension) |

## 10. `.bin` 을 새로 뽑으려면 (GPU 필요)

```bash
bash scripts/41_dump_reference.sh nvidia_970 1024   # NVIDIA 에서
bash scripts/41_dump_reference.sh amd_mi300x 1024   # MI300X 에서 (ROCm 환경 안)
```

두 번째 인자는 행 수(N)다. 스크립트가 플랫폼을 감지해 `nvcc` / `hipcc` 로 분기한다.
**반드시 ROCm 환경 안에서 돌려야 한다** — 밖에서 돌리면 `hipcc` 를 못 찾아
`nvcc` 로 잘못 분기한다 (실제로 겪었다).
