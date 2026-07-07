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
import base64
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import streamlit as st
import streamlit.components.v1 as components

# テンプレ(自己完結・`out`(SVGパス)に SVG を書けば何でも可)。補完は pyright に任せるので
# シードコメントは付けない(ソースはクリーンに保つ)。
TEMPLATES = {
    "schemdraw (回路)": (
        "import schemdraw\n"
        "import schemdraw.elements as elm\n"
        "if out.endswith('.svg'):\n"
        "    schemdraw.use('svg')\n"
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
    "rdkit (化学構造)": (
        "from rdkit import Chem\n"
        "from rdkit.Chem import rdDepictor\n"
        "from rdkit.Chem.Draw import rdMolDraw2D\n"
        "\n"
        'smiles = "CC(=O)Oc1ccccc1C(=O)O"  # アスピリン。SMILES を書き換えて構造を変える\n'
        "mol = Chem.MolFromSmiles(smiles)\n"
        "rdDepictor.Compute2DCoords(mol)\n"
        'svg = out.endswith(".svg")\n'
        "d = (rdMolDraw2D.MolDraw2DSVG if svg else rdMolDraw2D.MolDraw2DCairo)(400, 300)\n"
        "d.DrawMolecule(mol)\n"
        "d.FinishDrawing()\n"
        'open(out, "w" if svg else "wb").write(d.GetDrawingText())\n'
    ),
    "raw SVG": (
        'open(out, "w").write("""<svg xmlns="http://www.w3.org/2000/svg" width="140" height="60">'
        '<rect x="10" y="10" width="120" height="40" rx="6" fill="#5599cc"/>'
        '<text x="70" y="36" text-anchor="middle" fill="white" font-family="sans-serif">hello</text>'
        '</svg>""")\n'
    ),
}


def reload_vim(sock):
    """nvim(--listen sock)へ RPC で edit!(ディスク再読込)→write(=再生成) を実行させる。
    tmux send-keys は noice の cmdline ポップアップにキーを取りこぼすので RPC を使う。"""
    if not sock:
        return
    subprocess.run(
        ["nvim", "--server", sock, "--remote-expr", 'execute("edit! | write")'],
        check=False,
        capture_output=True,
    )


st.set_page_config(page_title="figure studio", layout="wide")

target = st.query_params.get("svg", "")
pyfile = st.query_params.get("py", "")
ttyd_port = st.query_params.get("ttyd", "7690")
sock = st.query_params.get("sock", "")

st.markdown(
    """
    <div style="display:flex;align-items:center;gap:13px;margin:.1rem 0 .7rem">
      <div style="width:8px;height:38px;border-radius:4px;
                  background:linear-gradient(180deg,#5aa0e0,#9b6ce0)"></div>
      <div style="line-height:1.08">
        <div style="font-size:2rem;font-weight:800;letter-spacing:-.02em;
                    background:linear-gradient(90deg,#5aa0e0 10%,#9b6ce0 90%);
                    -webkit-background-clip:text;background-clip:text;
                    -webkit-text-fill-color:transparent">figure&nbsp;studio</div>
        <div style="font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.72rem;
                    letter-spacing:.08em;color:#8b93a7;margin-top:3px">
          nvim&nbsp;<span style="color:#9b6ce0">→</span>&nbsp;SVG&nbsp;·&nbsp;PNG</div>
      </div>
    </div>
    """,
    unsafe_allow_html=True,
)

if not target or not pyfile:
    st.warning("nvim から `:Studio` / `,,e` で開いてください（?svg= と ?py= が必要）。")
    st.stop()

# 保存先 SVG を明示（左の nvim で :w すると ここに再生成/保存される）
st.caption(f"💾 保存先: `{target}` — 左の nvim で `:w` すると再生成・保存")

# ツールバー: テンプレ選択+挿入（📋コピーは右ペインの fragment 内=エラー時は出さない）
t1, t2 = st.columns([4, 1], vertical_alignment="bottom")
with t1:
    st.selectbox("テンプレ", list(TEMPLATES), key="tpl_sel", label_visibility="collapsed")
with t2:
    if st.button("テンプレ挿入", use_container_width=True):
        try:
            with open(pyfile, "w", encoding="utf-8") as f:
                f.write(TEMPLATES[st.session_state.tpl_sel])
            reload_vim(sock)  # RPC で vim に読み直させて write → 右が更新
            st.toast("テンプレを挿入（vim をリロード）")
        except OSError as e:
            st.error(f"テンプレ挿入に失敗: {e}")

COPY_BTN = """
<button id="cp" style="font-size:14px;padding:7px 16px;border:none;border-radius:6px;
        background:#5599cc;color:#fff;cursor:pointer;font-family:sans-serif">📋 SVGコピー</button>
<span id="msg" style="margin-left:10px;font-family:sans-serif;color:#2a2;font-size:13px"></span>
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
"""


def _box(inner):
    return (
        '<div style="background:#fff;padding:8px;display:flex;justify-content:center">'
        + inner + "</div>"
    )


@st.fragment(run_every="1s")
def preview(img_path, py_path):
    """右ペインだけ 1秒ごとに再実行(左の端末は再描画しない)。生成エラー時(=<py>.err がある)は
    画像もコピーも出さず、エラーだけ表示する(古い画像を残さない・壊れた出力を触らせない)。
    svg は文字列を inline(＋📋テキストコピー)、png/jpg は base64 の <img> で表示。"""
    errfile = py_path + ".err"
    if os.path.exists(errfile):
        try:
            msg = open(errfile, encoding="utf-8").read()
        except OSError:
            msg = ""
        st.error("⚠ 生成エラー（左の nvim で直して `:w`）\n\n" + msg)
        return
    ext = os.path.splitext(img_path)[1].lower()
    if ext in ("", ".svg"):
        try:
            svg_now = open(img_path, encoding="utf-8").read()
        except OSError:
            svg_now = ""
        if not svg_now:
            st.info("まだ SVG がありません（左の nvim で `:w`）")
            return
        components.html(_box(svg_now), height=510, scrolling=True)
        components.html(COPY_BTN.replace("__SVG__", json.dumps(svg_now)), height=44)
    else:
        try:
            data = open(img_path, "rb").read()
        except OSError:
            data = b""
        if not data:
            st.info("まだ画像がありません（左の nvim で `:w`）")
            return
        mime = "image/png" if ext == ".png" else "image/jpeg"
        b64 = base64.b64encode(data).decode()
        img = f'<img src="data:{mime};base64,{b64}" style="max-width:100%;height:auto">'
        components.html(_box(img), height=520, scrolling=True)
        # png/jpg は :Studio で既に md に ![] 挿入済み。テキストコピー不可なので 📋 は出さない。


left, right = st.columns(2, gap="small")
with left:
    st.caption("source — nvim（pyright 補完・`:w` で右に反映）")
    components.iframe(f"http://localhost:{ttyd_port}/", height=560)
with right:
    st.caption("preview — 図（`:w` で更新 / エラー時は非表示）")
    preview(target, pyfile)

# rdkit を使うソースのときだけ、下に SMILES 検索ツール(名前/CAS/InChI → SMILES)を出す。
# ネットへ問い合わせるのは「検索」押下時だけ(描画ループとは無関係)。
try:
    _pysrc = open(pyfile, encoding="utf-8").read()
except OSError:
    _pysrc = ""
if "rdkit" in _pysrc:
    st.divider()
    st.caption("🔎 SMILES 検索 — 名前 / CAS / InChI → SMILES")
    q1, q2, q3 = st.columns([3, 1, 1], vertical_alignment="bottom")
    with q1:
        query = st.text_input(
            "query", key="smi_q", label_visibility="collapsed",
            placeholder="例: 50-78-2（CAS）/ aspirin（名前）/ InChI=...",
        )
    with q2:
        idtype = st.selectbox(
            "種別", ["cas", "name", "inchi", "inchikey"],
            key="smi_type", label_visibility="collapsed",
        )
    with q3:
        do_search = st.button("検索", use_container_width=True)
    if do_search and query.strip():
        with st.spinner("検索中（オンライン）…"):
            try:
                from moleculeresolver import MoleculeResolver

                with MoleculeResolver() as mr:
                    mol = mr.find_single_molecule([query.strip()], [idtype])
                st.session_state.smi_result = (
                    getattr(mol, "SMILES", None) or "（見つかりませんでした）"
                )
            except Exception as e:  # noqa: BLE001
                st.session_state.smi_result = f"（検索エラー: {e}）"
    if st.session_state.get("smi_result"):
        st.code(st.session_state.smi_result, language="text")
    st.caption("名前は同義語衝突で誤ることあり。CAS / InChI が確実。")
