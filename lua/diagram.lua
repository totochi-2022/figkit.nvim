-- diagram.lua — 図(Python→SVG)を「studio ページ」で編集する。
--
-- studio ページ = 1枚の web ページ(iframe 2枚, wslview で開く):
--   ・左  : ttyd(127.0.0.1:7690) → tmux で nvim を永続起動。あなたの設定がそのまま乗るので
--           pyright の本物補完(引数ヒント/文脈)が効く。ブラウザ/ttyd が落ちても tmux セッションに
--           再アタッチするので編集中の状態は生き残る(=「落ちても意味がある」)。
--   ・右  : Vivify が対象 SVG をライブ表示。:w(BufWritePost)で SVG 再生成 → Vivify が file-watch
--           でリロード → 右が自動更新。
--   ※ Streamlit の中に端末を埋めない: 自動再実行のたびに iframe がリロードして端末が再接続を
--     繰り返すため。専用の静的 HTML を挟むことで端末 iframe は繋ぎっぱなしにできる。
--
-- 方式は draw.io と同思想(SVG固定・<metadata> にソース埋込・round-trip):
--   ・新規: :Studio [schemdraw|matplotlib|svg] → 現 md/typst の assets に <ts>.fig.svg を作り
--           リンク挿入、テンプレを載せて studio ページを開く。
--   ・編集: ![](x.svg) 上で ,,e → 埋込ソースを復元して studio ページを開く → :w で上書き。

local M = {}

local TTYD_PORT = 7690           -- 7681 は既存サービスが居るので避ける
local VIV_PORT = 31622
local TMUX_SESSION = 'figstudio'
local RENDER_PY = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py')
local VIV_SERVER = vim.fn.expand('~/.local/bin/vivify-server')
local CACHE = vim.fn.stdpath('cache') .. '/figstudio'

-- テンプレ(自己完結・`out`(SVGパス)に SVG を書けば何でも可)。補完は pyright に任せるので
-- シードコメントは付けない(ソースをクリーンに保つ)。
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

-- SVG に我々の埋込ソースマーカーがあるか(先頭のみ読む)
local function has_source(svg_path)
    local f = io.open(svg_path, 'r')
    if not f then return false end
    local head = f:read(8192) or ''
    f:close()
    return head:find('id="diagram%-source"') ~= nil
end

-- SVG の <metadata id="diagram-source"> から元 Python ソースを取り出す(CDATA 無害化を戻す)
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

-- バッファ内容から SVG を再生成(render_schemdraw の CLI に stdin で渡す)。
-- studio ページ内の nvim(ttyd)から :w のたびに呼ばれる。
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

-- studio ページ内の nvim が起動時に呼ぶ: 対象 SVG を結び付け、:w で再生成させる。
function M.attach(svg)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].fig_target = svg
    vim.api.nvim_create_autocmd('BufWritePost', {
        buffer = bufnr,
        callback = function() regen(bufnr) end,
        desc = 'figure: :w で対象 SVG を再生成',
    })
end

local function ensure_vivify()
    if vim.fn.executable(VIV_SERVER) == 1 then
        vim.fn.jobstart({ VIV_SERVER }, { detach = true }) -- 起動済みなら即終了(二重起動しない)
    end
end

-- studio ページを開く: 左=ttyd(tmux+nvim) / 右=Vivify(svg)。
function M.studio(target, source)
    target = vim.fn.fnamemodify(target, ':p')
    vim.fn.mkdir(CACHE, 'p')
    local py = py_for(target)
    vim.fn.writefile(vim.split(source, '\n', { plain = true }), py)

    -- 右ペイン用に初回 SVG を生成(失敗しても :w で作り直せる)
    vim.fn.system({ 'python3', RENDER_PY, target }, source)
    ensure_vivify()

    -- 左ペイン: ttyd が tmux 経由で nvim を起動(永続セッション)。
    -- inner.sh に nvim 起動を書いて多重クォートを回避。
    local nvim = vim.v.progpath
    local inner = CACHE .. '/inner.sh'
    vim.fn.writefile({
        '#!/bin/sh',
        'exec ' .. vim.fn.shellescape(nvim)
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

    -- ラッパー HTML(左=ttyd / 右=Vivify svg)
    local right = string.format('http://localhost:%d/viewer%s', VIV_PORT, target)
    local left = string.format('http://localhost:%d/', TTYD_PORT)
    local html = CACHE .. '/studio.html'
    vim.fn.writefile({
        '<!doctype html><html><head><meta charset="utf-8"><title>figure studio</title>',
        '<style>html,body{margin:0;height:100%}',
        '.wrap{display:flex;height:100vh}',
        '.wrap>iframe{flex:1;height:100%;border:0}',
        '.wrap>iframe.right{background:#fff}</style></head>',
        '<body><div class="wrap">',
        '<iframe src="' .. left .. '"></iframe>',
        '<iframe class="right" src="' .. right .. '"></iframe>',
        '</div></body></html>',
    }, html)

    -- ttyd/vivify が listen するまで少し待ってからブラウザで開く
    vim.defer_fn(function()
        vim.fn.jobstart({ 'wslview', html }, { detach = true })
    end, 1800)
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
        desc = 'figure studio: 新規図を作成(左=nvim/右=SVG の web ページ)',
    })
end

return M
