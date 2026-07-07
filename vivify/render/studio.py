#!/usr/bin/env python3
"""figure studio — Streamlit 製の web エディタ（左=vim(ttyd) / 右=ライブSVG / ツールバー）。

Ace の代わりに本物の nvim を左ペインに埋める版:
  ・左  : ttyd(?ttyd=port) の iframe = tmux 上の nvim。あなたの設定=pyright 補完が効く。
  ・右  : Vivify が ?svg= の SVG をライブ表示。nvim の :w で SVG 再生成 → 右が自動更新。
  ・ツールバー: テンプレ挿入(=?py= のソースを書き換え tmux で nvim をリロード)、📋SVGコピー。

起動: streamlit run studio.py  （通常は diagram.lua が ?svg=&py=&ttyd= 付きで開く）
ページの再描画はツールバー操作時のみ。編集中(vim)は再描画されないので端末は繋ぎっぱなし。
再描画で端末 iframe が張り直されても tmux セッションに再アタッチするので状態は残る。
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import streamlit as st
import streamlit.components.v1 as components

TMUX_SESSION = "figstudio"
VIV_PORT = 31622

# テンプレ(自己完結・`out`(SVGパス)に SVG を書けば何でも可)。補完は pyright に任せるので
# シードコメントは付けない(ソースはクリーンに保つ)。
TEMPLATES = {
    "schemdraw (回路)": (
        "import schemdraw\n"
        "import schemdraw.elements as elm\n"
        "schemdraw.use('svg')\n"
        "d = schemdraw.Drawing(show=False)\n"
        "d += elm.Resistor().label('R1')\n"
        "d += elm.Capacitor().label('C1').down()\n"
        "d += elm.Ground()\n"
        "d.save(out)\n"
    ),
    "matplotlib (グラフ)": (
        "import numpy as np\n"
        "import matplotlib.pyplot as plt\n"
        "x = np.linspace(0, 2 * np.pi, 200)\n"
        "plt.figure(figsize=(6, 3))\n"
        "plt.plot(x, np.sin(x), label='sin')\n"
        "plt.legend()\n"
        "plt.grid(True)\n"
        "plt.savefig(out)\n"
    ),
    "raw SVG": (
        'open(out, "w").write("""<svg xmlns="http://www.w3.org/2000/svg" width="140" height="60">'
        '<rect x="10" y="10" width="120" height="40" rx="6" fill="#5599cc"/>'
        '<text x="70" y="36" text-anchor="middle" fill="white" font-family="sans-serif">hello</text>'
        '</svg>""")\n'
    ),
}


def reload_vim():
    """nvim(tmux)に :e!(ディスクから再読込)→ :w(=再生成) を送る。テンプレ差し替え用。"""
    for keys in (["Escape"], [":e!", "Enter"], [":w", "Enter"]):
        subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, *keys], check=False)


st.set_page_config(page_title="figure studio", layout="wide")

target = st.query_params.get("svg", "")
pyfile = st.query_params.get("py", "")
ttyd_port = st.query_params.get("ttyd", "7690")

st.title("figure studio — nvim → SVG")

if not target or not pyfile:
    st.warning("nvim から `:Studio` / `,,e` で開いてください（?svg= と ?py= が必要）。")
    st.stop()

# ツールバー: テンプレ選択+挿入 / SVGコピー
t1, t2, t3 = st.columns([3, 1, 1], vertical_alignment="bottom")
with t1:
    st.selectbox("テンプレ", list(TEMPLATES), key="tpl_sel", label_visibility="collapsed")
with t2:
    if st.button("テンプレ挿入", use_container_width=True):
        try:
            with open(pyfile, "w", encoding="utf-8") as f:
                f.write(TEMPLATES[st.session_state.tpl_sel])
            reload_vim()  # vim に読み直させて :w → 右が更新
            st.toast("テンプレを挿入（vim をリロード）")
        except OSError as e:
            st.error(f"テンプレ挿入に失敗: {e}")
with t3:
    try:
        svg = open(target, encoding="utf-8").read()
    except OSError:
        svg = ""
    components.html(
        """
        <button id="cp" style="width:100%;font-size:14px;padding:8px 0;border:none;border-radius:6px;
                background:#5599cc;color:#fff;cursor:pointer;font-family:sans-serif">📋 SVGコピー</button>
        <span id="msg" style="margin-left:8px;font-family:sans-serif;color:#2a2;font-size:13px"></span>
        <script>
          const svg = __SVG__;
          const btn = document.getElementById('cp'), msg = document.getElementById('msg');
          btn.onclick = async () => {
            try { await navigator.clipboard.writeText(svg); }
            catch (e) {
              const ta = document.createElement('textarea');
              ta.value = svg; document.body.appendChild(ta); ta.select();
              document.execCommand('copy'); ta.remove();
            }
            msg.textContent = '✅ コピー'; setTimeout(() => { msg.textContent = ''; }, 2000);
          };
        </script>
        """.replace("__SVG__", json.dumps(svg)),
        height=46,
    )

left, right = st.columns(2, gap="small")
with left:
    st.caption("source — nvim（pyright 補完・`:w` で右に反映）")
    components.iframe(f"http://localhost:{ttyd_port}/", height=560)
with right:
    st.caption("preview — ライブSVG")
    components.iframe(f"http://localhost:{VIV_PORT}/viewer{target}", height=560)
