#!/usr/bin/env python3
"""figure studio — Streamlit 製の web エディタ（左=ソース / 右=ライブSVG / 保存）。

Python を書いて `out`(SVGパス) に SVG を保存すれば何でも可（schemdraw/matplotlib/…）。

起動:  streamlit run studio.py
       ?svg=<path> を付けると、その SVG の埋込ソースを読み込み、保存先も既定でそこに。
nvim 連携: ,,e が既存 SVG を ?svg= 付きで開く / 新規は空で開く → 保存で SVG 生成。
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import streamlit as st
import streamlit.components.v1 as components
from streamlit_ace import st_ace
from render_schemdraw import render

# 末尾のコメントは「補完シード」。streamlit-ace の補完はバッファ内の既出単語を拾う
# 方式なので、系統ごとの頻出シンボルをコメントで置いておくと `elm.R`→`Resistor` の
# ように候補に出る（意味解析ではないが実用上これが一番早い）。不要なら消してよい。
DEFAULT = (
    "import schemdraw\n"
    "import schemdraw.elements as elm\n"
    "schemdraw.use('svg')\n"
    "d = schemdraw.Drawing(show=False)\n"
    "d += elm.Resistor().label('R1')\n"
    "d += elm.Capacitor().label('C1').down()\n"
    "d += elm.Ground()\n"
    "d.save(out)\n"
    "\n"
    "# --- 補完シード(schemdraw) ---\n"
    "# elm: Resistor Capacitor Inductor Diode LED Zener Photodiode Battery Cell\n"
    "#      SourceV SourceI SourceSin Source Switch SwitchSpdt Button Ground Vdd Vss\n"
    "#      Line Dot Arrow Gap Label Opamp Fuse Crystal Transformer Josephson\n"
    "#      Nmos Pmos NFet PFet Bjt BjtNpn BjtPnp\n"
    "# メソッド: .label() .up() .down() .left() .right() .at() .to() .length()\n"
    "#          .color() .fill() .reverse() .flip() .theta() .scale() .linewidth()\n"
    "# Drawing: d.push() d.pop() d.move() d.here d.add()\n"
)

# テンプレ: SVG を out に書けば何でも可（schemdraw は d に描けば out 不要）
TEMPLATES = {
    "schemdraw (回路)": DEFAULT,
    "matplotlib (グラフ)": (
        "import numpy as np\n"
        "import matplotlib.pyplot as plt\n"
        "x = np.linspace(0, 2*np.pi, 200)\n"
        "plt.figure(figsize=(6, 3))\n"
        "plt.plot(x, np.sin(x), label='sin')\n"
        "plt.legend(); plt.grid(True)\n"
        "plt.savefig(out)\n"
        "\n"
        "# --- 補完シード(matplotlib/numpy) ---\n"
        "# plt: plot scatter bar barh hist boxplot pie fill_between step stem errorbar\n"
        "#      imshow contour axhline axvline annotate text\n"
        "#      xlabel ylabel title suptitle legend grid xlim ylim xticks yticks\n"
        "#      subplot subplots figure tight_layout twinx savefig\n"
        "# np: linspace arange array sin cos tan exp log sqrt pi zeros ones\n"
        "#     random meshgrid mean std max min abs where clip concatenate\n"
    ),
    "raw SVG": (
        "open(out, 'w').write('''<svg xmlns=\"http://www.w3.org/2000/svg\" "
        "width=\"140\" height=\"60\"><rect x=\"10\" y=\"10\" width=\"120\" height=\"40\" "
        "rx=\"6\" fill=\"#5599cc\"/><text x=\"70\" y=\"36\" text-anchor=\"middle\" "
        "fill=\"white\" font-family=\"sans-serif\">hello</text></svg>''')\n"
        "\n"
        "# --- 補完シード(SVG) ---\n"
        "# 要素: rect circle ellipse line polyline polygon path text tspan g defs\n"
        "#       linearGradient radialGradient stop clipPath mask use symbol marker\n"
        "# 属性: x y width height cx cy r rx ry x1 y1 x2 y2 d points transform viewBox\n"
        "#       fill stroke stroke-width opacity font-family font-size text-anchor\n"
    ),
}


def extract_source(svg_path):
    try:
        s = open(svg_path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(
        r'<metadata id="diagram-source"[^>]*><!\[CDATA\[(.*?)\]\]></metadata>', s, re.S
    )
    if not m:
        return None
    return m.group(1).replace("]]]]><![CDATA[>", "]]>")


st.set_page_config(page_title="figure studio", layout="wide")

target = st.query_params.get("svg", "")

# 初期ソース(一度だけ): ?svg= の埋込ソース → 無ければデフォルト
if "src" not in st.session_state:
    init = extract_source(target) if target else None
    st.session_state.src = init if init is not None else DEFAULT
if "ace_key" not in st.session_state:
    st.session_state.ace_key = 0
if "save_path" not in st.session_state:
    st.session_state.save_path = target


def _insert_template():
    st.session_state.src = TEMPLATES[st.session_state.tpl_sel]
    st.session_state.ace_key += 1  # エディタを新しい value で再初期化させる


st.title("figure studio — Python → SVG")

t1, t2 = st.columns([3, 1], vertical_alignment="bottom")
with t1:
    st.selectbox("テンプレ", list(TEMPLATES), key="tpl_sel", label_visibility="collapsed")
with t2:
    st.button("テンプレ挿入", use_container_width=True, on_click=_insert_template)

left, right = st.columns(2, gap="medium")
with left:
    st.caption("source — 自己完結の Python で `out`(SVGパス) に SVG を保存（Ctrl+Enter で反映）")
    source = st_ace(
        value=st.session_state.src,
        language="python",
        theme="monokai",
        keybinding="vscode",
        font_size=14,
        tab_size=4,
        min_lines=24,
        show_gutter=True,
        auto_update=False,
        key=f"ace_{st.session_state.ace_key}",
    )
    st.session_state.src = source
with right:
    st.caption("preview")
    svg, err = render(source)
    if err:
        st.error(err)
    else:
        components.html(
            f'<div style="background:#fff;padding:8px">{svg}</div>',
            height=540,
            scrolling=True,
        )

st.divider()
c1, c2 = st.columns([4, 1], vertical_alignment="bottom")
with c1:
    save_path = st.text_input("保存先 SVG", key="save_path", placeholder="/path/to/out.svg")
with c2:
    if st.button("💾 保存(上書き)", use_container_width=True, disabled=bool(err)):
        svg2, err2 = render(source)
        if err2:
            st.error(err2)
        elif not save_path:
            st.warning("保存先を入力してください")
        else:
            os.makedirs(os.path.dirname(save_path) or ".", exist_ok=True)
            with open(save_path, "w", encoding="utf-8") as f:
                f.write(svg2)
            st.success(f"保存しました: {save_path}")

# 新規作成フロー用: ワンクリックで SVG をクリップボードへ → nvim の md で ,,p 貼付
# (localhost は secure context なので navigator.clipboard が使える。ダメなら execCommand で fallback)
if not err:
    components.html(
        """
        <button id="cp" style="font-size:14px;padding:8px 18px;border:none;border-radius:6px;
                background:#5599cc;color:#fff;cursor:pointer;font-family:sans-serif">
          📋 SVG をコピー
        </button>
        <span id="msg" style="margin-left:12px;font-family:sans-serif;color:#2a2;font-size:14px"></span>
        <script>
          const svg = __SVG__;
          const btn = document.getElementById('cp');
          const msg = document.getElementById('msg');
          btn.onclick = async () => {
            try { await navigator.clipboard.writeText(svg); }
            catch (e) {
              const ta = document.createElement('textarea');
              ta.value = svg; document.body.appendChild(ta); ta.select();
              document.execCommand('copy'); ta.remove();
            }
            msg.textContent = '✅ コピーしました → nvim で ,,p';
            setTimeout(() => { msg.textContent = ''; }, 2500);
          };
        </script>
        """.replace("__SVG__", json.dumps(svg)),
        height=52,
    )
