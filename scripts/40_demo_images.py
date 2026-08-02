#!/usr/bin/env python3
"""
데모 장치 1 — "차이 이미지가 새까맣다" (report/demo-plan.md)

두 GPU 의 출력 덤프를 받아 열지도를 만든다.

    python3 scripts/40_demo_images.py <A.bin> <B.bin> --labels NVIDIA MI300X

  <출력>/a.png        A 의 출력
  <출력>/b.png        B 의 출력
  <출력>/diff.png     |A-B| — **완전한 검정이면 완전히 같다는 뜻**
  <출력>/compare.png  셋을 가로로 붙인 것 (발표용 한 장)

비엔지니어에게 보여주는 것이 목적이다. 세 번째가 새까맣다는 것만 보면 되고,
틀린 버전을 넣으면 거기에 불이 들어온다.

외부 패키지를 쓰지 않는다 (표준 라이브러리만). numpy/PIL 설치가 필요하면
클라우드 인스턴스에서 한 단계 더 막힌다.
"""
import argparse
import os
import struct
import sys
import zlib

# Windows 콘솔 기본 코드페이지(cp949)에서 한글·기호가 깨지거나 예외가 난다.
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except AttributeError:
    pass


# ---------------------------------------------------------------- PNG 쓰기
def _chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data
            + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, rows, width, height):
    """rows: 각 원소가 bytes(r,g,b,...) 인 리스트, 길이 height"""
    raw = b''.join(b'\x00' + r for r in rows)          # 필터 0 (None)
    png = (b'\x89PNG\r\n\x1a\n'
           + _chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
           + _chunk(b'IDAT', zlib.compress(raw, 9))
           + _chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


# ---------------------------------------------------------------- 데이터
def load(path, d):
    with open(path, 'rb') as f:
        raw = f.read()
    n = len(raw) // 4
    if n % d:
        sys.exit(f"[FATAL] {path}: 원소 수 {n} 이 d={d} 로 나누어떨어지지 않습니다.")
    return struct.unpack(f'<{n}f', raw), n // d


def heat(t):
    """t in [0,1] -> (r,g,b). 0 은 검정에 가깝게 — '차이 없음'이 한눈에 보이도록."""
    if t < 0.5:
        u = t * 2.0
        return (int(15 + 55 * u), int(15 + 115 * u), int(50 + 200 * u))
    u = (t - 0.5) * 2.0
    return (int(70 + 185 * u), int(130 - 95 * u), int(250 - 230 * u))


def render(vals, rows, cols, vmin, vmax, scale):
    span = (vmax - vmin) or 1.0
    out = []
    for r in range(rows):
        line = bytearray()
        for c in range(cols):
            t = (vals[r * cols + c] - vmin) / span
            t = 0.0 if t < 0 else (1.0 if t > 1 else t)
            line += bytes(heat(t)) * scale
        for _ in range(scale):
            out.append(bytes(line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('-d', '--head-dim', type=int, default=64)
    ap.add_argument('-o', '--outdir', default='report/demo-images')
    ap.add_argument('--rows', type=int, default=64, help='위에서 몇 행만 그릴지')
    ap.add_argument('--scale', type=int, default=6, help='픽셀 확대 배율')
    ap.add_argument('--labels', nargs=2, default=['A', 'B'])
    ap.add_argument('--tol', type=float, default=1e-3,
                    help='차이 패널의 색 기준(상대). 빨강 = 허용오차 초과')
    args = ap.parse_args()

    A, rowsA = load(args.a, args.head_dim)
    B, _ = load(args.b, args.head_dim)
    if len(A) != len(B):
        sys.exit(f"[FATAL] 크기가 다릅니다: {len(A)} vs {len(B)}")

    rows, d = min(args.rows, rowsA), args.head_dim
    n = rows * d
    a, b = A[:n], B[:n]
    diff = [abs(x - y) for x, y in zip(a, b)]

    max_abs = max(diff)
    ref_max = max(abs(x) for x in A) or 1.0
    rel = max_abs / ref_max

    os.makedirs(args.outdir, exist_ok=True)
    lo, hi = min(min(a), min(b)), max(max(a), max(b))
    s, W, H = args.scale, d * args.scale, rows * args.scale

    ia = render(a, rows, d, lo, hi, s)
    ib = render(b, rows, d, lo, hi, s)

    # 차이 패널의 스케일은 **허용오차**다. 자기 범위로 정규화하면 오차가
    # 0 에 가까워도 화려한 그림이 나와 거짓말이 되고, 데이터 전체 범위로
    # 정규화하면 명백한 오류도 검정으로 보여 데모가 성립하지 않는다.
    #   검정  = 완전 일치
    #   파랑  = 허용오차 이내
    #   빨강  = 허용오차 초과 (= FAIL)
    # 이 기준은 출력에 함께 찍어 캡션으로 쓴다.
    tol_abs = args.tol * ref_max
    idf = render(diff, rows, d, 0.0, tol_abs, s)

    write_png(os.path.join(args.outdir, 'a.png'), ia, W, H)
    write_png(os.path.join(args.outdir, 'b.png'), ib, W, H)
    write_png(os.path.join(args.outdir, 'diff.png'), idf, W, H)

    gap = bytes((25, 25, 30)) * 16
    write_png(os.path.join(args.outdir, 'compare.png'),
              [x + gap + y + gap + z for x, y, z in zip(ia, ib, idf)],
              W * 3 + 32, H)

    ok = rel < args.tol
    print(f"  {args.labels[0]:>12} : {args.a}")
    print(f"  {args.labels[1]:>12} : {args.b}")
    print(f"  최대 절대오차 : {max_abs:.3e}")
    print(f"  최대 상대오차 : {rel:.3e}")
    print(f"  판정          : {'동일 — 차이 이미지가 검정' if ok else '★ 불일치 — 차이 이미지에 불이 들어옴'}")
    print(f"  차이 패널 기준: 검정=일치 · 파랑=허용 이내 · 빨강=허용({args.tol:.0e}) 초과")
    print(f"  이미지        : {args.outdir}/{{a,b,diff,compare}}.png")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
