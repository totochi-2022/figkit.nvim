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
import types
import tempfile
import textwrap
import unicodedata

# スニペット先頭の `import figkit` を成立させるためのダミーモジュール。
# これは ,,p(:FigPasteAuto)が「図を作るコードだ」と判別するための印で、
# 誤って普通の Python を貼って実行してしまう事故を防ぐためのもの。
# ローカルで exec する以上、完全な防御ではない(誤爆防止と割り切る)。
# 印はソースに残したまま SVG へ埋め込まれるので、studio から 📋 コピーして
# ,,p したときにも通る。
sys.modules.setdefault("figkit", types.ModuleType("figkit"))

# 図の既定フォントサイズ。schemdraw の既定 14 は CJK ラベルだと大きすぎ、端の見切れも招く
# (_pad_svg_for_cjk で救ってはいるが、そもそも小さいほうが収まりが良い)。
# exec の前に global config を張るので、既存の図も再生成すれば自動で揃う。
# ソース側で Drawing(fontsize=...) と書けば従来どおり個別に上書きできる。
DEFAULT_FONTSIZE = 10

_META_RE = re.compile(
    r'<metadata id="diagram-source"[^>]*><!\[CDATA\[(.*?)\]\]></metadata>', re.S
)


def _char_w(c):
    """1文字の概算幅(em単位)。schemdraw は半角基準で見積るため全角(CJK)で不足する。
    ここでは全角=1.0em・太い英大文字=0.92・英大文字=0.72・細い記号=0.34・他=0.6 と多めに見積る。"""
    eaw = unicodedata.east_asian_width(c)
    if eaw in ("W", "F"):
        return 1.0
    if eaw == "A":  # 全角約物(：等)は実運用で全角幅になりがち
        return 0.95
    if c in "WM@%":
        return 0.92
    if c.isupper():
        return 0.72
    if c in "il|.,':;!()[]{}　 ":
        return 0.34
    return 0.60


def _text_w(s, fs):
    return sum(_char_w(c) for c in s) * fs


def _pad_svg_for_cjk(svg):
    """<text>/<tspan> の実描画範囲(CJK考慮)を計算し、はみ出す分だけ viewBox を広げる。
    schemdraw の CJK 幅過小評価による端ラベルの見切れを防ぐ。失敗時は無変換で返す。"""
    try:
        m = re.search(r"<svg\b[^>]*>", svg)
        if not m:
            return svg
        tag = m.group(0)
        vb = re.search(r'viewBox="([-\d.eE]+)\s+([-\d.eE]+)\s+([-\d.eE]+)\s+([-\d.eE]+)"', tag)
        wpt = re.search(r'width="([\d.eE]+)pt"', tag)
        hpt = re.search(r'height="([\d.eE]+)pt"', tag)
        if not vb:
            return svg
        vx, vy, vw, vh = (float(vb.group(i)) for i in range(1, 5))
        minx, miny, maxx, maxy = vx, vy, vx + vw, vy + vh

        def _attr(pat, s, default):
            mm = re.search(pat, s)
            return mm.group(1) if mm else default

        for tm in re.finditer(r"<text\b([^>]*)>(.*?)</text>", svg, re.S):
            attrs, body = tm.group(1), tm.group(2)
            fs = float(_attr(r'font-size="([\d.eE]+)"', attrs, "12"))
            anch = _attr(r'text-anchor="(\w+)"', attrs, "start")
            ty = float(_attr(r'y="([-\d.eE]+)"', attrs, str(miny)))
            tx = float(_attr(r'x="([-\d.eE]+)"', attrs, "0"))
            yline = ty
            for sp in re.finditer(r"<tspan\b([^>]*)>([^<]*)</tspan>", body):
                spa, txt = sp.group(1), sp.group(2)
                if not txt:
                    continue
                x0 = float(_attr(r'x="([-\d.eE]+)"', spa, str(tx)))
                dym = re.search(r'dy="([-\d.eE]+)"', spa)
                yline = yline + float(dym.group(1)) if dym else yline
                w = _text_w(txt, fs)
                if anch == "middle":
                    lo, hi = x0 - w / 2, x0 + w / 2
                elif anch == "end":
                    lo, hi = x0 - w, x0
                else:
                    lo, hi = x0, x0 + w
                minx, maxx = min(minx, lo), max(maxx, hi)
                miny, maxy = min(miny, yline - fs), max(maxy, yline + 0.3 * fs)

        pad = 2.0
        minx, miny, maxx, maxy = minx - pad, miny - pad, maxx + pad, maxy + pad
        nw, nh = maxx - minx, maxy - miny
        if nw <= 0 or nh <= 0:
            return svg
        newtag = re.sub(
            r'viewBox="[^"]*"', f'viewBox="{minx:.2f} {miny:.2f} {nw:.2f} {nh:.2f}"', tag
        )
        if wpt and vw > 0:
            ppu = float(wpt.group(1)) / vw  # pt/unit を維持して拡大
            newtag = re.sub(r'width="[\d.eE]+pt"', f'width="{nw * ppu:.4f}pt"', newtag)
        if hpt and vh > 0:
            ppu = float(hpt.group(1)) / vh
            newtag = re.sub(r'height="[\d.eE]+pt"', f'height="{nh * ppu:.4f}pt"', newtag)
        return svg[: m.start()] + newtag + svg[m.end():]
    except Exception:  # noqa: BLE001  (後処理失敗で描画を壊さない)
        return svg


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
        # 既定フォントサイズを図全体に効かせる。config() は他の項目も既定値に戻すが、
        # レンダラは1図1プロセスなので誰も設定していない=実害なし。ユーザーのソースが
        # 後から schemdraw.config(...) を呼べばそちらが勝つ。
        try:
            import schemdraw
        except ImportError:
            pass  # matplotlib / rdkit 等、schemdraw を使わない図もある
        else:
            schemdraw.config(fontsize=DEFAULT_FONTSIZE)
        try:
            exec(source, ns)  # noqa: S102  (ローカル専用・信頼入力前提)
        except Exception as e:  # noqa: BLE001
            return _brief(e)
        if os.path.getsize(out) == 0:
            return "出力なし（out に保存してください。例: d.save(out) / plt.savefig(out)）"

        if ext in ("", ".svg"):
            svg = open(out, encoding="utf-8", errors="replace").read()
            svg = _pad_svg_for_cjk(svg)  # CJK 幅過小評価による端ラベル見切れを補正
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
