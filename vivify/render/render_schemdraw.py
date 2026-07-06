#!/usr/bin/env python3
"""schemdraw スニペットを SVG 化し、元ソースを <metadata> に埋め込む。

使い方:
    python3 schemdraw.py <out.svg> < snippet
- stdin: スニペット(案A)。スコープに schemdraw / elm / d(Drawing) を用意済み。
  例:  d += elm.Resistor().label('R1')
- 生成 SVG は <svg> 直後に
    <metadata id="diagram-source" data-type="schemdraw"><![CDATA[...source...]]></metadata>
  を挿入（draw.io 方式の round-trip 用）。ブラウザ/GitHub は metadata を無視して描画。
- ローカルプレビュー専用。スニペットは exec する（＝任意コード実行）ので信頼できる入力のみ。
"""
import sys


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: schemdraw.py <out.svg> < snippet\n")
        return 2
    import textwrap
    out_path = sys.argv[1]
    # 一様な先頭インデント(エディタの autoindent / リスト内フェンス等)を除去。
    # 相対インデント(for 本体など)は保持されるので安全。
    source = textwrap.dedent(sys.stdin.read())

    try:
        import schemdraw
        schemdraw.use("svg")
        import schemdraw.elements as elm
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"schemdraw import 失敗: {e}\n(pip install schemdraw)\n")
        return 3

    ns = {"schemdraw": schemdraw, "elm": elm}
    d = schemdraw.Drawing(show=False)
    ns["d"] = d
    try:
        exec(source, ns)  # noqa: S102  (ローカル専用・信頼入力前提)
    except Exception as e:  # noqa: BLE001
        import traceback
        sys.stderr.write("schemdraw スニペット実行エラー:\n")
        traceback.print_exc()
        return 4

    d = ns.get("d", d)
    try:
        svg = d.get_imagedata("svg")
    except Exception as e:  # noqa: BLE001
        import traceback
        sys.stderr.write("SVG 生成エラー:\n")
        traceback.print_exc()
        return 5
    if isinstance(svg, bytes):
        svg = svg.decode("utf-8")

    # CDATA を壊す ]]> を無害化してから埋め込む
    safe = source.replace("]]>", "]]]]><![CDATA[>")
    meta = (
        '<metadata id="diagram-source" data-type="schemdraw">'
        "<![CDATA[" + safe + "]]></metadata>"
    )
    # 最初の '>'(= <svg ...> の閉じ)の直後に挿入
    i = svg.find(">")
    if i == -1:
        sys.stderr.write("SVG が不正(< svg > が見つからない)\n")
        return 6
    svg = svg[: i + 1] + "\n" + meta + "\n" + svg[i + 1:]

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(svg)
    print(out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
