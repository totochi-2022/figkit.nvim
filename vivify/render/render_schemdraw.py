#!/usr/bin/env python3
"""Python スニペットを実行して画像化し、元ソースを埋め込む(draw.io 方式 round-trip)。

- 生成:   python3 render_schemdraw.py <out.(svg|png|jpg)> [errfile] < snippet
          出力の拡張子で形式を決定。namespace に `out`(その拡張子の一時ファイル)を渡すので、
          スニペットは自己完結(import 含む)で `out` に保存すればよい:
              d.save(out) / plt.savefig(out) / open(out,'w').write(svg) など。
          元ソースを埋め込む:  SVG=<metadata> / PNG=tEXt チャンク / JPEG=COM コメント。
- 取出し: python3 render_schemdraw.py --extract <file>   → 埋め込みソースを stdout(無ければ空)。

スニペットは exec する(=任意コード実行)ので信頼できる入力のみ(ローカル専用)。
"""
import os
import re
import shutil
import sys
import tempfile
import textwrap

_META_RE = re.compile(
    r'<metadata id="diagram-source"[^>]*><!\[CDATA\[(.*?)\]\]></metadata>', re.S
)


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


def render_file(source, target):
    """source を exec し、target(拡張子で形式決定)に画像を書く。元ソースを埋め込む。
    成功で None、失敗でエラーメッセージ1行を返す(失敗時 target は上書きしない=前の正常版を保持)。"""
    source = textwrap.dedent(source)  # 一様インデント除去(相対は保持)
    ext = os.path.splitext(target)[1].lower()

    fd, out = tempfile.mkstemp(suffix=(ext or ".svg"))
    os.close(fd)
    try:
        ns = {"out": out}
        try:
            exec(source, ns)  # noqa: S102  (ローカル専用・信頼入力前提)
        except Exception as e:  # noqa: BLE001
            return _brief(e)
        if os.path.getsize(out) == 0:
            return "出力なし（out に保存してください。例: d.save(out) / plt.savefig(out)）"

        if ext in ("", ".svg"):
            svg = open(out, encoding="utf-8", errors="replace").read()
            j = svg.find("<svg")  # 先頭 <?xml?>/<!DOCTYPE> を飛ばして <svg> 本体を探す
            if j == -1:
                return "SVG ではありません（out に SVG を書いてください）"
            i = svg.find(">", j)  # <svg …> 開始タグの閉じ '>'
            if i == -1:
                return "SVG が不正(<svg> の閉じが無い)"
            safe = source.replace("]]>", "]]]]><![CDATA[>")  # CDATA を壊す ]]> を無害化
            meta = (
                '<metadata id="diagram-source" data-type="python">'
                "<![CDATA[" + safe + "]]></metadata>"
            )
            # metadata は <svg> の中(最初の子)に入れる。外に置くと不正な SVG になる。
            with open(target, "w", encoding="utf-8") as f:
                f.write(svg[: i + 1] + "\n" + meta + "\n" + svg[i + 1:])
        elif ext == ".png":
            from PIL import Image, PngImagePlugin

            info = PngImagePlugin.PngInfo()
            info.add_text("diagram-source", source)  # tEXt チャンクに埋込
            Image.open(out).save(target, pnginfo=info)
        elif ext in (".jpg", ".jpeg"):
            from PIL import Image

            # COM コメントに埋込(EXIF UserComment は encoding で不安定なので使わない)
            Image.open(out).save(target, comment=source.encode("utf-8"))
        else:
            shutil.copyfile(out, target)  # 未知拡張子は素通し(埋込なし)
        return None
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass


def extract_source(path):
    """画像に埋め込んだ元ソースを取り出す(svg/png/jpg)。無ければ空文字。"""
    ext = os.path.splitext(path)[1].lower()
    try:
        if ext in ("", ".svg"):
            m = _META_RE.search(open(path, encoding="utf-8", errors="replace").read())
            return m.group(1).replace("]]]]><![CDATA[>", "]]>") if m else ""
        if ext == ".png":
            from PIL import Image

            return Image.open(path).text.get("diagram-source", "") or ""
        if ext in (".jpg", ".jpeg"):
            from PIL import Image

            c = Image.open(path).info.get("comment")
            return c.decode("utf-8") if isinstance(c, bytes) else (c or "")
    except Exception:  # noqa: BLE001
        return ""
    return ""


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--extract":
        if len(args) < 2:
            return 2
        sys.stdout.write(extract_source(args[1]))
        return 0
    if not args:
        sys.stderr.write("usage: render_schemdraw.py <out.(svg|png|jpg)> [errfile] < snippet\n")
        return 2
    target = args[0]
    errfile = args[1] if len(args) > 1 else None  # studio 用のエラー状態 sidecar
    err = render_file(sys.stdin.read(), target)
    if err:
        if errfile:
            try:
                with open(errfile, "w", encoding="utf-8") as f:
                    f.write(err)
            except OSError:
                pass
        sys.stderr.write(err + "\n")
        return 4
    if errfile:  # 成功: エラー状態を解除
        try:
            os.remove(errfile)
        except OSError:
            pass
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
