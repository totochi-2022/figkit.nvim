-- diagram.lua — 図(Python→SVG)を Streamlit「figure studio」で編集する。
--
-- studio = 前からある Streamlit の 2ペインページ。ソース部の Ace を本物の nvim に差し替えた版:
--   ・左  : ttyd(127.0.0.1:7690) → tmux で nvim を永続起動。設定そのまま=pyright 補完が効く。
--           ブラウザ/ttyd が落ちても tmux セッションに再アタッチするので編集状態は残る。
--   ・右  : studio.py が対象 SVG を白ボックスで表示。st.fragment(run_every)で右だけ 1秒ごとに
--           読み直すので、nvim の :w(BufWritePost で再生成)が反映される(左の端末は再描画しない)。
--   ・ツールバー(テンプレ/📋コピー)は Streamlit 側(studio.py)に残す。
--   ※ ページ再描画はツールバー操作時のみ。編集中(vim)は再描画されないので端末は繋ぎっぱなし。
--
-- 方式は draw.io と同思想(SVG固定・<metadata> にソース埋込・round-trip):
--   ・新規: :FigNewFromTemplate (,,m) → 現 md/typst の assets に <ts>.fig.svg を作り
--           リンク挿入、テンプレを載せて studio を開く。
--   ・編集: ![](x.svg) 上で ,,e → 埋込ソースを復元して studio を開く → :w で上書き。

local M = {}

local TTYD_PORT = 7690           -- 7681 は既存サービスが居るので避ける
local STUDIO_PORT = 8501         -- Streamlit
local TMUX_SESSION = 'figstudio'
local RENDER_PY = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py')
local STUDIO_PY = vim.fn.expand('~/.config/nvim/vivify/render/studio.py')
local CACHE = vim.fn.stdpath('cache') .. '/figstudio'

-- テンプレ(自己完結・`out` に保存すれば何でも可。out の拡張子で svg/png/jpg が決まる)。
-- 補完は pyright に任せる。schemdraw は svg 出力のときだけ svg バックエンド(png は matplotlib)。
local TEMPLATES = {
    schemdraw = table.concat({
        "import figkit  # ,,p で図と認識させる印",
        "import schemdraw",
        "import schemdraw.elements as elm",
        "if out.endswith('.svg'):",
        "    schemdraw.use('svg')",
        "d = schemdraw.Drawing(show=False)",
        "d += elm.Resistor().label('R1')",
        "d += elm.Capacitor().label('C1').down()",
        "d += elm.Ground()",
        "d.save(out)",
        "",
    }, "\n"),
    matplotlib = table.concat({
        "import figkit  # ,,p で図と認識させる印",
        "import numpy as np",
        "import matplotlib.pyplot as plt",
        "x = np.linspace(0, 2 * np.pi, 200)",
        "plt.figure(figsize=(6, 3))",
        "plt.plot(x, np.sin(x), label='sin')",
        "plt.legend()",
        "plt.grid(True)",
        "plt.savefig(out)",
        "",
    }, "\n"),
    raw = table.concat({
        "import figkit  # ,,p で図と認識させる印",
        "open(out, 'w').write('''<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"140\" height=\"60\">",
        "<rect x=\"10\" y=\"10\" width=\"120\" height=\"40\" rx=\"6\" fill=\"#5599cc\"/>",
        "<text x=\"70\" y=\"36\" text-anchor=\"middle\" fill=\"white\" font-family=\"sans-serif\">hello</text>",
        "</svg>''')",
        "",
    }, "\n"),
    rdkit = table.concat({
        "import figkit  # ,,p で図と認識させる印",
        "from rdkit import Chem",
        "from rdkit.Chem import rdDepictor",
        "from rdkit.Chem.Draw import rdMolDraw2D",
        "",
        'smiles = "CC(=O)Oc1ccccc1C(=O)O"  # アスピリン。SMILES を書き換えて構造を変える',
        "mol = Chem.MolFromSmiles(smiles)",
        "rdDepictor.Compute2DCoords(mol)",
        'svg = out.endswith(".svg")',
        "d = (rdMolDraw2D.MolDraw2DSVG if svg else rdMolDraw2D.MolDraw2DCairo)(400, 300)",
        "# d.drawOptions().useBWAtomPalette()  # コメントを外すとモノクロ(既定は O=赤 等の元素色)",
        "d.DrawMolecule(mol)",
        "d.FinishDrawing()",
        'open(out, "w" if svg else "wb").write(d.GetDrawingText())',
        "",
    }, "\n"),
}

-- 画像(svg/png/jpg)に埋め込んだ元ソースを取り出す。無ければ nil(=我々の図でない)。
-- svg は metadata、png は tEXt、jpg は COM。判定/取り出しは render CLI(--extract)に一任。
local function extract_source(path)
    local src = vim.fn.system({ 'python3', RENDER_PY, '--extract', path })
    if vim.v.shell_error ~= 0 or src == '' then return nil end
    return src
end

local function resolve(path)
    if path:match('^[/~]') then return vim.fn.expand(path) end
    return vim.fn.fnamemodify(vim.fn.expand('%:p:h') .. '/' .. path, ':p')
end

-- 対象 SVG 用の temp .py パス(basename + 短ハッシュで安定&衝突回避)
local function py_for(target)
    vim.fn.mkdir(CACHE, 'p')
    local base = vim.fn.fnamemodify(target, ':t:r'):gsub('%.fig$', '')
    return CACHE .. '/' .. base .. '-' .. vim.fn.sha256(target):sub(1, 8) .. '.py'
end

-- バッファ内容から SVG を再生成。studio 内の nvim(ttyd)から :w のたびに呼ばれる。
local function regen(bufnr)
    local target = vim.b[bufnr].fig_target
    if not target or target == '' then return end
    local errfile = vim.api.nvim_buf_get_name(bufnr) .. '.err' -- studio がエラー状態を見る sidecar
    local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    local out = vim.fn.system({ 'python3', RENDER_PY, target, errfile }, src)
    if vim.v.shell_error ~= 0 then
        vim.notify('図の生成エラー: ' .. vim.trim(out), vim.log.levels.ERROR)
    else
        vim.notify('図を更新: ' .. vim.fn.fnamemodify(target, ':t'), vim.log.levels.INFO)
    end
end

-- studio 内の nvim が起動時に呼ぶ: 対象 SVG を結び付け、:w で再生成させる。
function M.attach(svg)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].fig_target = svg
    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = bufnr,
        callback = function() regen(bufnr) end,
        desc = 'figure: :w で対象 SVG を再生成',
    })
end

-- Streamlit studio が稼働中か(health を同期 curl・短タイムアウト)
local function studio_up()
    local out = vim.fn.system(
        { 'curl', '-s', '-m', '1', 'http://localhost:' .. STUDIO_PORT .. '/_stcore/health' }
    )
    return vim.trim(out) == 'ok'
end

-- 左ペイン: ttyd が tmux 経由で nvim を起動(永続セッション)。多重クォート回避に inner.sh を使う。
-- nvim は --listen <sock> で RPC を受ける(テンプレ挿入で --remote-expr により :e!|w させるため。
-- tmux send-keys は noice の cmdline ポップアップにキーを取りこぼすので使わない)。
local function start_ttyd(target, py, sock)
    local inner = CACHE .. '/inner.sh'
    vim.fn.writefile({
        '#!/bin/sh',
        'rm -f ' .. vim.fn.shellescape(sock), -- 古い socket を掃除(新規セッション時のみ実行される)
        'exec ' .. vim.fn.shellescape(vim.v.progpath)
            .. ' --listen ' .. vim.fn.shellescape(sock)
            .. " -c 'lua require(\"diagram\").attach(\"" .. target .. "\")' "
            .. vim.fn.shellescape(py),
    }, inner)
    vim.fn.setfperm(inner, 'rwxr-xr-x')
    if M._ttyd and M._ttyd > 0 then pcall(vim.fn.jobstop, M._ttyd) end
    vim.fn.system({ 'tmux', 'kill-session', '-t', TMUX_SESSION }) -- 前回分を掃除(無ければ無害)
    M._ttyd = vim.fn.jobstart({
        'ttyd', '-i', '127.0.0.1', '-p', tostring(TTYD_PORT), '-W',
        '-t', 'fontSize=15', '-t', 'disableLeaveAlert=true',
        'tmux', 'new-session', '-A', '-s', TMUX_SESSION, inner,
    }, { detach = true })
end

-- studio を開く: 左=ttyd(tmux+nvim) / 右=Vivify(svg)。Streamlit がツールバー+レイアウトを担う。
-- URL クエリ用のパーセントエンコード（パスに空白等が入っても壊れないように）
local function urlenc(v)
    return (tostring(v or ''):gsub('[^%w._~-]', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

-- studio から「md に挿入 / md を更新」を押せるように、md 側の情報も渡す。
--   host    … md を開いている**外側の** nvim(v:servername)。studio 内の nvim とは別物
--   buf     … その md のバッファ番号
--   scratch … まだ md に入っていない図か（ボタンの文言が変わる）
local studio_ctx = { buf = 0, scratch = false }

function M.studio(target, source)
    target = vim.fn.fnamemodify(target, ':p')
    vim.fn.mkdir(CACHE, 'p')
    local py = py_for(target)
    local sock = (py:gsub('%.py$', '')) .. '.sock'
    vim.fn.writefile(vim.split(source, '\n', { plain = true }), py)

    vim.fn.system({ 'python3', RENDER_PY, target, py .. '.err' }, source) -- 右ペイン用に初回 SVG
    start_ttyd(target, py, sock)

    local up = studio_up()
    if not up then
        vim.fn.jobstart({
            'python3', '-m', 'streamlit', 'run', STUDIO_PY,
            '--server.headless=true', '--server.port=' .. STUDIO_PORT,
            '--browser.gatherUsageStats=false',
        }, { detach = true })
    end

    local url = string.format(
        'http://localhost:%d/?svg=%s&py=%s&ttyd=%d&sock=%s&host=%s&buf=%d&scratch=%s',
        STUDIO_PORT, target, py, TTYD_PORT, sock,
        urlenc(vim.v.servername), studio_ctx.buf, studio_ctx.scratch and '1' or '')
    vim.defer_fn(function()
        vim.fn.jobstart({ 'wslview', url }, { detach = true })
    end, up and 400 or 4000) -- streamlit/ttyd/vivify の listen 待ち
    vim.notify('studio: ' .. vim.fn.fnamemodify(target, ':t') .. '（左=nvim/右=SVG, :w で更新）',
        vim.log.levels.INFO)
end

-- studio を止める。用途が2つあるので強さを分ける。
--   all=false … Streamlit だけ落とす。**studio.py を書き換えたときの反映用**。
--                起動中の Streamlit は古いコードを持ったままで、M.studio は「上がっていれば
--                起動しない」ので、落とさないと変更が効かない。
--                ttyd と tmux は残すので、左の nvim の編集状態は失われない。
--   all=true  … ttyd と tmux セッションも落として完全に片付ける。
--                tmux は編集状態を保持しているので、こちらは明示的に頼まれたときだけ。
function M.studio_stop(all)
    local function port_up(port)
        local out = vim.fn.system({ 'ss', '-ltn' })
        return out:match(':' .. port .. '%s') ~= nil
    end
    local before = { streamlit = port_up(STUDIO_PORT), ttyd = port_up(TTYD_PORT) }

    -- pkill -f は ERE。Lua の %. ではなく \. で書く（ここを取り違えて効いていなかった）
    vim.fn.system({ 'pkill', '-f', 'streamlit run .*studio\\.py' })
    if all then
        if M._ttyd and M._ttyd > 0 then
            pcall(vim.fn.jobstop, M._ttyd)
            M._ttyd = nil
        end
        vim.fn.system({ 'pkill', '-f', 'ttyd .*-p ' .. TTYD_PORT })
        vim.fn.system({ 'tmux', 'kill-session', '-t', TMUX_SESSION })
    end

    vim.fn.system({ 'sleep', '0.4' })
    local msg = {}
    table.insert(msg, 'Streamlit(' .. STUDIO_PORT .. '): '
        .. (before.streamlit and (port_up(STUDIO_PORT) and '停止できず' or '停止') or '元から未起動'))
    if all then
        table.insert(msg, 'ttyd(' .. TTYD_PORT .. '): '
            .. (before.ttyd and (port_up(TTYD_PORT) and '停止できず' or '停止') or '元から未起動'))
        table.insert(msg, 'tmux ' .. TMUX_SESSION .. ': 削除')
    else
        table.insert(msg, 'ttyd/tmux は残した（編集状態を保持）')
    end
    vim.notify(table.concat(msg, ' / '), vim.log.levels.INFO)
end

-- Studio を単体で開く（対象ファイルなし）。draw.io アプリと同じ位置づけで、
-- 成果物はツールバーの「📋 SVGコピー」→ ,,p で md に入れる。
-- 描画先は cache のスクラッチなので、**assets/ には何も作られない**
-- ＝ボツにしてもゴミが残らない。
-- 既存の図(埋込ソース付き .fig.svg)を studio で開く。保存先はその図自身なので、
-- studio 側の :w がそのままファイルを更新する＝md のリンクは張り替え不要。
-- 埋込ソースが無い(draw.io 等)なら false を返して呼び出し側に委ねる。
function M.studio_open(svg)
    svg = vim.fn.fnamemodify(vim.fn.expand(svg), ':p')
    if vim.fn.filereadable(svg) == 0 then return false end
    local src = extract_source(svg)
    if not src or src == '' then return false end
    studio_ctx = { buf = vim.api.nvim_get_current_buf(), scratch = false }
    M.studio(svg, src)
    vim.notify('Studio: ' .. vim.fn.fnamemodify(svg, ':t') .. '（:w でこの図を更新）',
        vim.log.levels.INFO)
    return true
end

function M.studio_scratch(kind)
    vim.fn.mkdir(CACHE, 'p')
    studio_ctx = { buf = vim.api.nvim_get_current_buf(), scratch = true }
    local target = CACHE .. '/scratch.fig.svg'
    M.studio(target, TEMPLATES[kind] or TEMPLATES.schemdraw)
    vim.notify('Studio(スクラッチ): 仕上げたら 📋 SVGコピー → ,,p で md に貼る',
        vim.log.levels.INFO)
end

-- :FigNewFromTemplate [template] [fmt] — 新規図を現 md/typst に作成する。
-- template ∈ {schemdraw,matplotlib,raw}(既定 schemdraw) / fmt ∈ {svg,png}(既定 svg)。
function M.new(kind, fmt)
    local base = vim.fn.expand('%:p:h')
    if base == '' or vim.bo.buftype ~= '' then
        vim.notify('名前付きの md/typst バッファで実行してください', vim.log.levels.WARN)
        return
    end
    fmt = fmt or 'svg'
    local dir = base .. '/assets'
    vim.fn.mkdir(dir, 'p')
    local ts = os.date('%Y%m%d-%H%M%S')
    local fname = ts .. '.fig.' .. fmt
    local target = dir .. '/' .. fname
    local is_typst = vim.bo.filetype == 'typst' or vim.fn.expand('%:e') == 'typ'
    local link = is_typst and ('#image("assets/' .. fname .. '")') or ('![](assets/' .. fname .. ')')
    local md_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_put({ link }, 'c', true, true)

    -- studio は立てない（腰を据えたくなったら ,,s で昇格する）。
    -- テンプレを一度描画して初期 SVG を作り(ソースも埋め込まれる)、あとは ,,e と同じ
    -- 分割バッファ経路に合流させる＝ :w で再生成 + preview リロードがそのまま効く。
    local src = TEMPLATES[kind] or TEMPLATES.schemdraw
    local out = vim.fn.system({ 'python3', RENDER_PY, target, py_for(target) .. '.err' }, src)
    if vim.v.shell_error ~= 0 then
        vim.notify('図の生成エラー: ' .. vim.trim(out), vim.log.levels.ERROR)
        return
    end
    M.edit_source(target, md_buf)
end

-- figure.edit_auto(,,e)から: 埋込ソース付き画像(svg/png/jpg)なら軽量エディタ(edit_source)で開いて true。
-- 違えば false(→呼び出し側が draw.io を開く)。識別は extract_source(=<metadata id="diagram-source">)。
-- （旧: Streamlit studio を開いていたが、web ペイン内で完結する edit_source に変更）
function M.try_edit_file(path)
    if not path or not path:match('%.svg$') and not path:match('%.png$') and not path:match('%.jpe?g$') then
        return false
    end
    local abs = resolve(path)
    if vim.fn.filereadable(abs) == 0 then return false end
    if not extract_source(abs) then return false end -- 我々の図でなければ draw.io に委ねる
    M.edit_source(abs, vim.api.nvim_get_current_buf())
    return true
end

-- 埋め込みSVGの Python ソースを「編集用バッファ」で開く軽量版（Streamlit studio 不使用）。
-- svg: 対象SVGの絶対パス / md_buf: それをリンクしている md バッファ（保存後の preview reload 先）。
-- :w(BufWritePost) で SVG を再生成し、md の preview を cache-bust reload する。
-- 目的: 埋め込みSVGは人がソースを直接いじれない（描画結果しか見えない）ので、Claude を介さない
-- 手直しが今のサイクルだとできない。それを解消する。web/端末どちらでも動く（reload は localhost POST）。
function M.edit_source(svg, md_buf)
    svg = vim.fn.fnamemodify(svg, ':p')
    if vim.fn.filereadable(svg) == 0 then
        vim.notify('SVG が見つかりません: ' .. svg, vim.log.levels.WARN)
        return
    end
    local src = extract_source(svg)
    if not src then
        -- draw.io は埋め込み方式が違う(.drawio.svg / <mxfile>)。識別して ,,e に誘導する。
        local is_drawio = svg:match('%.drawio%.svg$') ~= nil
        if not is_drawio then
            local ok, head = pcall(vim.fn.readfile, svg, '', 60)
            if ok then
                for _, l in ipairs(head) do
                    if l:match('mxfile') or l:match('mxGraphModel') then is_drawio = true; break end
                end
            end
        end
        if is_drawio then
            vim.notify('draw.io 図です（埋込方式が別）。,,e で draw.io を開いてください: '
                .. vim.fn.fnamemodify(svg, ':t'), vim.log.levels.WARN)
        else
            vim.notify('埋め込みソースが無い（studio/我々の生成物ではない）: ' .. svg, vim.log.levels.WARN)
        end
        return
    end
    local py = py_for(svg)
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), py)
    vim.cmd('split ' .. vim.fn.fnameescape(py)) -- md を残して分割で開く（実ファイル=pyright 補完も効く）
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].fig_target = svg
    vim.b[bufnr].fig_md_buf = md_buf
    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = bufnr,
        callback = function()
            regen(bufnr) -- SVG + .err 再生成（エラー時は regen が notify する）
            local mb = vim.b[bufnr].fig_md_buf
            if mb and vim.api.nvim_buf_is_valid(mb) then
                pcall(function() require('vivify').reload(mb) end) -- preview に cache-bust 反映
            end
        end,
        desc = 'figure(inline): :w で SVG 再生成 + preview reload',
    })
    vim.notify('図ソース編集: ' .. vim.fn.fnamemodify(svg, ':t') .. '（:w で再生成＋preview反映）',
        vim.log.levels.INFO)
end

return M
