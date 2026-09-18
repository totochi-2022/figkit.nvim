# figkit.nvim

Markdown/Typst に貼る**図と画像**の「作る / 直す」を Neovim から片付けるツール群。

- **図** … Python スニペット（schemdraw / matplotlib / RDKit …）→ SVG。**元ソースを画像に埋め込む**ので、
  貼った図はあとから何度でも直せる。
- **画像** … スクショ等に矢印 / 枠 / 文字 / モザイクを重ねる（marker.js 3）。**原本は書き換えない**。
- 出力は常に「`assets/` のファイル + md からの普通のリンク」1つだけ。md 本文に独自記法は入らないので、
  GitHub や VS Code でもそのまま見える。

> [!WARNING]
> **自分用のツールを整理して置いてあるものです。** そのまま使うことは想定していません。
> WSL2 + Windows 前提の箇所（`wslview`, `wslpath`, draw.io デスクトップ版）があり、
> 設定・キーマップも作者の環境に合わせてあります。動かない前提でコードを読んでください。

## できること

| コマンド | 既定キー | 何をするか |
|---|---|---|
| `:FigPasteAuto` | `,,p` | クリップボードを判定して貼る（Python / SVG / draw.io XML / 画像） |
| `:FigEditAuto` | `,,e` | カーソル行の対象を判定して再編集（埋込ソース / 注釈 / draw.io） |
| `:FigOpenStudio [tmpl]` | `,,s` | Studio を開く（カーソル行に図があればそれを、無ければスクラッチ） |
| `:FigNewFromTemplate [tmpl] [svg\|png]` | `,,m` | テンプレから `assets/` に作ってリンク挿入 → 分割バッファで編集 |
| `:FigStopStudio[!]` | | Studio を止める（`!` で ttyd/tmux も） |
| `:FigClipInfo` | | いま `,,p` が何をするかだけ表示（書き込まない） |
| `:FigHealth` | | 依存チェック（= `:checkhealth figkit`） |

自動判別に頼らず直接叩く用の個別コマンドもある（`:Fig<Tab>` で一覧）:
`FigRenderPython` / `FigPasteSvg` / `FigPasteDrawioXml` / `FigPasteImage` /
`FigEditSource` / `FigAnnotateImage` / `FigOpenDrawioApp`。

**判定が外れたら個別コマンドで回避できる**——これが「自動判別を薄く乗せる」構成にしている理由。

## セットアップ

```lua
{
    "totochi-2022/figkit.nvim",
    dependencies = { "HakonHarnes/img-clip.nvim" },  -- クリップボード画像の取り出しに使う
    ft = { "markdown", "typst" },
    opts = {
        -- 図/注釈を書き換えたあとに呼ばれる。プレビューを持っているならここで再読込させる。
        on_change = function(buf) require('my-preview').reload(buf) end,
        -- 注釈エディタ / Studio の URL の開き方（既定は wslview → vim.ui.open）
        open_url = function(url, title) vim.fn.jobstart({ 'wslview', url }, { detach = true }) end,
        -- draw.io デスクトップ版（WSL から Windows 側を叩く）
        drawio_exe = '/mnt/c/Program Files/draw.io/draw.io.exe',
    },
    keys = {
        { ',,p', '<cmd>FigPasteAuto<CR>',        desc = '図: 貼付(自動判別)' },
        { ',,e', '<cmd>FigEditAuto<CR>',         desc = '図: 再編集(自動判別)' },
        { ',,s', '<cmd>FigOpenStudio<CR>',       desc = '図: Studio' },
        { ',,m', '<cmd>FigNewFromTemplate<CR>',  desc = '図: テンプレから作成' },
    },
}
```

キーマップは付けない（`,,` は howm/telekasten と競合しやすいので呼び出し側で決める）。

### 依存が揃っているか確認する

```vim
:FigHealth     " = :checkhealth figkit
```

**機能ごとに分けて報告する**（依存が多く、欠け方も部分的なので）:

- **図の生成** … python3 / Pillow / schemdraw・matplotlib・rdkit（使うテンプレの分だけ）
- **画像注釈** … 同梱アセット（marker.js 一式）が読めるか。依存は stdlib のみ
- **Studio** … streamlit / ttyd / tmux / curl / pyright
- **ポート** … 31624・7690・8501・8770 を**古いプロセスが掴んでいないか**。
  注釈サーバ(31624)は `/vendor/` が 200 を返すかで新旧を判定する
  （プラグインを移動・更新したあと、起動中のサーバが消えたパスを掴んだままになる事故がある）
- **連携と環境** … img-clip / `v:servername` / クリップボード provider /
  wslu のバージョンと binfmt 登録名 / draw.io / `on_change` が注入されているか

`:checkhealth figkit` も同じものだが、**遅延ロード中は nvim が health モジュールを
見つけられない**（rtp に載っていないため）。`:FigHealth` なら `cmd` トリガで
プラグインが読み込まれてから走るので、どの状態でも打てる。

### 必要なもの

| 用途 | 必要なもの |
|---|---|
| 図の生成 | `python3` + `schemdraw` / `matplotlib` / `rdkit`（使うものだけ）、`Pillow`（png/jpg 出力とソース埋込） |
| Studio | `streamlit`, `ttyd`, `tmux`, `pyright`（左ペインの補完） |
| 画像注釈 | **なし**（`server.py` は stdlib のみ。`Pillow` があれば縮小品質が上がる） |
| クリップボード画像 | [img-clip.nvim](https://github.com/HakonHarnes/img-clip.nvim) |
| WSL | `wslview`（**wslu 4.x**。3.x は `WSLInterop-late` を知らずブラウザを開けない） |

## 保存モデル

### 図（Python → SVG）
```
assets/<ts>.fig.svg      生成物。元ソースを <metadata id="diagram-source"> に埋め込む
assets/<ts>.fig.svg.err  生成エラー（在るときは画像を出さない＝古い絵を残さない）
```
png/jpg も選べる（ソースは PNG tEXt / JPEG COM に埋め込む。draw.io と同じ round-trip の考え方）。
`,,e` はこの埋込ソースを取り出して分割バッファに出し、**`:w` で再生成**する。

### 画像（注釈）
```
assets/<ts>.png        原本。**書き換えない**
assets/<ts>.ann.json   marker.js の AnnotationState。注釈の正本（git で差分が読める）
assets/<ts>.ann.png    合成結果。md はこれを参照する（生成物・持ち出し用）
```
`.ann.png` に `,,e` すると**原本 + state に解決して再開**する。原本が消えているときは
「焼き込み済み画像への重ね描き」を避けて中断する。

## 設計メモ

**クリップボードを入力にした理由**: 以前「md のフェンスにカーソルを置いて描画」方式があったが、
バッファに「描画済み / 未描画」の中間状態ができて分からなくなった。クリップボード入力なら
中間状態が存在せず、貼った時点で常に「ファイル + リンク」の1状態しかない。

**注釈は作業サイズ = 出力サイズ**。編集画面の大きさがそのまま保存される（右下のつまみでドラッグ変更可）。
当初は原寸に描いて書き出し時に縮めていたが、注釈まで縮む → state で補正 → 画面と出力が食い違う、と
問題が連鎖した。出力と同じ大きさで描くのが結局いちばん単純で、補正コードが全部要らなくなった。
縮小は毎回**原本から** Pillow(LANCZOS) で作るので往復しても劣化しない（Pillow が無ければブラウザ側にフォールバック）。

**モザイクは自作マーカー**（marker.js の18種にぼかしが無い）。作業サイズ全体を一度モザイク化した
画像を各マーカーが**同じ座標のまま**矩形でクリップして見せる。動かしてもリサイズしても常に真下が出る。
書き出しは自前の `Renderer` で行う——marker.js UI 内蔵のラスタライズは自作マーカー型を知らず、
**画面では潰れているのに保存 PNG は素通し**になる（静かに漏れる事故）。

**md に大きさを書かない**。`{width=..}` は markdown-it-attrs 依存で GitHub/VS Code では本文にゴミが出るし、
`<img>` はプレビューのキャッシュバスター・`,,e` のパス抽出・リンク差し替えが全て `](..)` 前提なので壊れる。
大きさは**画像自体**を縮めて決める。

## セキュリティ

**`,,p`（`:FigRenderPython`）はクリップボードの Python をローカルで実行します。**
先頭に `import figkit` を要求しているが、これは**他所からコピーした普通の Python を
うっかり `,,p` したときの誤爆防止**であって、サンドボックスではない。
信用できない出所のコードを貼らないこと。

## ライセンス

自作部分のライセンスは未定（決まったら `LICENSE` を置く）。同梱物:

- **marker.js 3**（`annot/vendor/markerjs3.umd.js`）… **linkware**。商用含め無料だが
  **編集中のロゴ表示を残す条件**。ロゴを消す改変はしないこと（`annot/vendor/LICENSE.markerjs3.txt`）。
- **marker.js UI**（`annot/vendor/markerjs-ui.umd.js`）… MIT。

読み込み順は固定（UI が `markerjs3` のグローバルを参照する）。
