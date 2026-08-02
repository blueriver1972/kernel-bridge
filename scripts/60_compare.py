#!/usr/bin/env python3
"""
NVIDIA ↔ AMD 비교표 생성 (Phase 4)

    python3 scripts/60_compare.py --nv-gpu H100 --amd-gpu MI300X

01-baseline/raw/ 와 03-verify/raw/ 의 로그를 읽어 커널별 비교표를 만든다.

────────────────────────────────────────────────────────────────────────
왜 ms 를 그대로 비교하면 안 되는가
────────────────────────────────────────────────────────────────────────
세대가 다른 칩끼리는 ms 차이가 '이식 품질'이 아니라 '하드웨어 차이'다.
MI300X(2023, 5.3 TB/s) 가 H100(2022, 3.4 TB/s) 보다 빠른 건 당연하다.

그래서 정규화한다:

    실제 배속 = NVIDIA 시간 ÷ AMD 시간
    기대 배속 = AMD 대역폭 ÷ NVIDIA 대역폭       (메모리 바운드 가정)
    이식 효율 = 실제 배속 ÷ 기대 배속

    1.0  하드웨어 이점을 그대로 살림 → 이식이 잘 됨
    0.5  절반만 살림                → 튜닝 여지 있음
    >1.0 기대 이상 (연산 바운드이거나 캐시 효과)

바이트 수를 세지 않아도 되는 게 장점이다. 커널마다 메모리 접근량을
손으로 계산하면 틀리기 쉽고, 그 오류가 결론을 바꾼다.

한계: 메모리 바운드 커널에만 유효하다. 연산 바운드 커널(행렬곱 등)은
피크 FLOPS 로 정규화해야 하므로 --compute 로 지정한다.
"""
import argparse
import glob
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except AttributeError:
    pass

# 벤더 공개 스펙 (대략값). 발표 전 스펙시트로 반드시 확인할 것.
SPECS = {
    #            메모리 대역폭 TB/s,  fp32 벡터 TFLOPS
    'GTX970':   (0.224, 3.5),
    'A100':     (2.039, 19.5),
    'H100':     (3.35,  67.0),
    'H200':     (4.8,   67.0),
    'MI300X':   (5.3,   163.4),
}


def best_times(dirname):
    """로그에서 커널별 최적 ms 를 뽑는다."""
    out = {}
    for f in sorted(glob.glob(os.path.join(dirname, '*_k*.log'))):
        m = re.match(r'(.+)_k(\d+)\.log', os.path.basename(f))
        if not m:
            continue
        binname, k = m.group(1), int(m.group(2))
        # 바이너리 이름의 접미사(_fp32 등)를 떼어 대상 이름으로 삼는다
        target = re.sub(r'_(fp32|tf32|hip|bf16)$', '', binname)
        with open(f, encoding='utf-8', errors='replace') as fh:
            txt = fh.read()
        times = [float(t) for t in
                 re.findall(r'block_size\s+\d+\s*\|\s*time\s+([\d.]+)\s*ms', txt)]
        if times:
            out[(target, k)] = min(times)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nv-gpu', default='H100', choices=sorted(SPECS))
    ap.add_argument('--amd-gpu', default='MI300X', choices=sorted(SPECS))
    ap.add_argument('--nv-dir', default='01-baseline/raw')
    ap.add_argument('--amd-dir', default='03-verify/raw')
    ap.add_argument('--compute', nargs='*', default=[],
                    help='연산 바운드로 볼 대상 (예: attention). 피크 FLOPS 로 정규화')
    ap.add_argument('-o', '--out', default='03-verify/comparison.md')
    args = ap.parse_args()

    nv, amd = best_times(args.nv_dir), best_times(args.amd_dir)
    if not nv:
        sys.exit(f"[FATAL] NVIDIA 로그가 없습니다: {args.nv_dir}")
    if not amd:
        sys.exit(f"[FATAL] AMD 로그가 없습니다: {args.amd_dir}\n"
                 f"        Phase 3(MI300X) 를 아직 안 돌렸습니다.")

    nv_bw, nv_fl = SPECS[args.nv_gpu]
    amd_bw, amd_fl = SPECS[args.amd_gpu]

    lines = [
        f"# 커널별 비교 — {args.nv_gpu} vs {args.amd_gpu}",
        "",
        f"- 메모리 대역폭 기대 배속: **{amd_bw / nv_bw:.2f}x** "
        f"({amd_bw} ÷ {nv_bw} TB/s)",
        f"- fp32 연산 기대 배속: **{amd_fl / nv_fl:.2f}x** "
        f"({amd_fl} ÷ {nv_fl} TFLOPS)",
        "",
        "**이식 효율** = 실제 배속 ÷ 기대 배속. 1.0 이면 하드웨어 이점을 그대로 살린 것.",
        "",
        "| 대상 | 커널 | " + f"{args.nv_gpu} ms | {args.amd_gpu} ms | 실제 배속 | 기대 | **이식 효율** |",
        "|---|---|---|---|---|---|---|",
    ]

    rows = 0
    for key in sorted(set(nv) & set(amd)):
        target, k = key
        t_nv, t_amd = nv[key], amd[key]
        actual = t_nv / t_amd
        expect = (amd_fl / nv_fl) if target in args.compute else (amd_bw / nv_bw)
        eff = actual / expect
        flag = '' if eff >= 0.7 else '  ⚠'
        lines.append(f"| {target} | {k} | {t_nv:.4f} | {t_amd:.4f} | "
                     f"{actual:.2f}x | {expect:.2f}x | **{eff:.2f}**{flag} |")
        rows += 1

    only_nv = sorted(set(nv) - set(amd))
    if only_nv:
        lines += ["", "### AMD 결과가 없는 항목", ""]
        lines += [f"- {t} 커널 {k}" for t, k in only_nv]

    lines += [
        "",
        "---",
        "",
        "## 읽는 법",
        "",
        "- **이식 효율 ≥ 1.0** — 하드웨어 성능을 온전히 냈다. 튜닝 불필요",
        "- **0.7 ~ 1.0** — 대체로 정상 범위",
        "- **< 0.7 (⚠)** — 이식은 됐지만 성능을 못 살렸다. **튜닝 대상**",
        "",
        "메모리 바운드 커널은 대역폭 비로, 연산 바운드 커널은 FLOPS 비로 정규화했다.",
        "`--compute` 로 지정하지 않은 대상은 메모리 바운드로 간주한다.",
        "",
        "> 스펙 수치는 벤더 공개값(대략)이다. 발표 전 스펙시트로 확인할 것.",
        "> 정밀도·문제 크기가 양쪽 동일한지 먼저 확인한다 — 어긋나면 이 표는 무효다.",
    ]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(lines) + '\n')

    print('\n'.join(lines))
    print(f"\n→ {args.out} ({rows}개 커널)")


if __name__ == '__main__':
    main()
