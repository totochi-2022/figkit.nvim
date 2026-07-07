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
--   ・新規: :Studio [schemdraw|matplotlib|svg] → 現 md/typst の assets に <ts>.fig.svg を作り
--           リンク挿入、テンプレを載せて studio を開く。
--   ・編集: ![](x.svg) 上で ,,e → 埋込ソースを復元して studio を開く → :w で上書き。

local M = {}

local TTYD_PORT = 7690           -- 7681 は既存サービスが居るので避ける
local STUDIO_PORT = 8501         -- Streamlit
local TMUX_SESSION = 'figstudio'
local RENDER_PY = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py')
local STUDIO_PY = vim.fn.expand('~/.config/nvim/vivify/render/studio.py')
local CACHE = vim.fn.stdpath('cache') .. '/figstudio'

-- テンプレ(自己完結・`out`(SVGパス)に SVG を書けば何でも可)。補完は pyright に任せる。
local TEMPLATES = {
    schemdraw = table.concat({
        "import schemdraw",
        "import schemdraw.elements as elm",
        "schemdraw.use('svg')",
        "d = schemdraw.Drawing(show=False)",
        "d += elm.Resistor().label('R1')",
        "d += elm.Capacitor().label('C1').down()",
        "d += elm.Ground()",
        "d.save(out)",
        "",
    }, "\n"),
    matplotlib = table.concat({
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
    svg = table.concat({
        "open(out, 'w').write('''<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"140\" height=\"60\">",
        "<rect x=\"10\" y=\"10\" width=\"120\" height=\"40\" rx=\"6\" fill=\"#5599cc\"/>",
        "<text x=\"70\" y=\"36\" text-anchor=\"middle\" fill=\"white\" font-family=\"sans-serif\">hello</text>",
        "</svg>''')",
        "",
    }, "\n"),
}

local function has_source(svg_path)
    local f = io.open(svg_path, 'r')
    if not f then return false end
    local head = f:read(8192) or ''
    f:close()
    return head:find('id="diagram%-source"') ~= nil
end

local function extract_source(svg_path)
    local f = io.open(svg_path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    local body = s:match('<metadata id="diagram%-source"[^>]*><!%[CDATA%[(.-)%]%]></metadata>')
    if not body then return nil end
    return (body:gsub('%]%]%]%]><!%[CDATA%[>', ']]>'))
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
    local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    local out = vim.fn.system({ 'python3', RENDER_PY, target }, src)
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
function M.studio(target, source)
    target = vim.fn.fnamemodify(target, ':p')
    vim.fn.mkdir(CACHE, 'p')
    local py = py_for(target)
    local sock = (py:gsub('%.py$', '')) .. '.sock'
    vim.fn.writefile(vim.split(source, '\n', { plain = true }), py)

    vim.fn.system({ 'python3', RENDER_PY, target }, source) -- 右ペイン用に初回 SVG
    start_ttyd(target, py, sock)

    local up = studio_up()
    if not up then
        vim.fn.jobstart({
            'python3', '-m', 'streamlit', 'run', STUDIO_PY,
            '--server.headless=true', '--server.port=' .. STUDIO_PORT,
            '--browser.gatherUsageStats=false',
        }, { detach = true })
    end

    local url = string.format('http://localhost:%d/?svg=%s&py=%s&ttyd=%d&sock=%s',
        STUDIO_PORT, target, py, TTYD_PORT, sock)
    vim.defer_fn(function()
        vim.fn.jobstart({ 'wslview', url }, { detach = true })
    end, up and 400 or 4000) -- streamlit/ttyd/vivify の listen 待ち
    vim.notify('studio: ' .. vim.fn.fnamemodify(target, ':t') .. '（左=nvim/右=SVG, :w で更新）',
        vim.log.levels.INFO)
end

-- :Studio [kind] — 新規図を現 md/typst に作成して studio を開く
function M.new(kind)
    local base = vim.fn.expand('%:p:h')
    if base == '' or vim.bo.buftype ~= '' then
        vim.notify('名前付きの md/typst バッファで実行してください', vim.log.levels.WARN)
        return
    end
    local dir = base .. '/assets'
    vim.fn.mkdir(dir, 'p')
    local ts = os.date('%Y%m%d-%H%M%S')
    local fname = ts .. '.fig.svg'
    local target = dir .. '/' .. fname
    local is_typst = vim.bo.filetype == 'typst' or vim.fn.expand('%:e') == 'typ'
    local link = is_typst and ('#image("assets/' .. fname .. '")') or ('![](assets/' .. fname .. ')')
    vim.api.nvim_put({ link }, 'c', true, true)
    M.studio(target, TEMPLATES[kind] or TEMPLATES.schemdraw)
end

-- OpenDrawio(,,e)から: 埋込ソース付き SVG なら studio を開いて true。違えば false(→draw.io)。
function M.try_edit_file(path)
    if not path or not path:match('%.svg$') then return false end
    local abs = resolve(path)
    if vim.fn.filereadable(abs) == 0 then return false end
    if not has_source(abs) then return false end
    M.studio(abs, extract_source(abs) or TEMPLATES.schemdraw)
    return true
end

function M.setup()
    vim.api.nvim_create_user_command('Studio', function(o)
        M.new(o.args ~= '' and o.args or nil)
    end, {
        nargs = '?',
        complete = function() return { 'schemdraw', 'matplotlib', 'svg' } end,
        desc = 'figure studio: 新規図を作成(左=nvim/右=SVG)',
    })
end

return M
