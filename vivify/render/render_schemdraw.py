#!/usr/bin/env python3
"""schemdraw スニペットを SVG 化し、元ソースを <metadata> に埋め込む。

- CLI:   python3 render_schemdraw.py <out.svg> < snippet    （nvim の :DiagramRender 用）
- module: from render_schemdraw import render               （studio.py 用）
           svg, err = render(source)

生成 SVG は <svg> 直後に
    <metadata id="diagram-source" data-type="schemdraw"><![CDATA[...source...]]></metadata>
を挿入（draw.io 方式の round-trip 用）。ブラウザ/GitHub は metadata を無視して描画。
スニペットは exec する（＝任意コード実行）ので信頼できる入力のみ（ローカル専用）。
スコープに schemdraw / elm / d(Drawing, show=False) を用意済み。例: d += elm.Resistor().label('R1')
"""
import sys
import textwrap


def _brief(e):
    """例外を「種別: メッセージ (line N)」の1行に整形（全トレース非表示）。"""
    if isinstance(e, SyntaxError):
        loc = f" (line {e.lineno})" if e.lineno else ""
        return f"{type(e).__name__}: {e.msg}{loc}"
    import traceback
    line = None
    for fr in traceback.extract_tb(e.__traceback__):
        if fr.filename == "<string>":
            line = fr.lineno
    loc = f" (line {line})" if line else ""
    return f"{type(e).__name__}: {e}{loc}"


def render(source):
    """Python スニペット → (svg_str, None) または (None, error_msg)。

    方式: namespace に `out`(一時 .svg パス)だけ渡す。スニペットは自己完結（import 含む）で
    `out` に SVG を書く。ライブラリ非依存で何でも可:
        d.save(out) / plt.savefig(out) / chart.render_to_file(out) / open(out,'w').write(svg)
    生成 SVG には元ソース(dedent 済)を <metadata> に埋め込む(round-trip 用)。
    """
    import os
    import tempfile

    source = textwrap.dedent(source)  # 一様インデント除去(相対は保持)

    fd, out = tempfile.mkstemp(suffix=".svg")
    os.close(fd)
    ns = {"out": out}
    try:
        try:
            exec(source, ns)  # noqa: S102  (ローカル専用・信頼入力前提)
        except Exception as e:  # noqa: BLE001
            return None, _brief(e)
        if os.path.getsize(out) == 0:
            return None, (
                "出力なし（out に SVG を保存してください。"
                "例: d.save(out) / plt.savefig(out) / open(out,'w').write(svg)）"
            )
        svg = open(out, encoding="utf-8", errors="replace").read()
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass

    if "<svg" not in svg:
        return None, "SVG ではありません（out に SVG を書いてください）"

    # 元ソースを <metadata> に埋込。CDATA を壊す ]]> は無害化。
    safe = source.replace("]]>", "]]]]><![CDATA[>")
    meta = (
        '<metadata id="diagram-source" data-type="python">'
        "<![CDATA[" + safe + "]]></metadata>"
    )
    i = svg.find(">")
    if i == -1:
        return None, "SVG が不正(<svg> が見つからない)"
    return svg[: i + 1] + "\n" + meta + "\n" + svg[i + 1:], None


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: render_schemdraw.py <out.svg> < snippet\n")
        return 2
    svg, err = render(sys.stdin.read())
    if err:
        sys.stderr.write(err + "\n")
        return 4
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        f.write(svg)
    print(sys.argv[1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
