-- diagram.lua — 図(Python→SVG)を nvim で編集する。
--
-- 方式(draw.io と同思想・SVG固定・ソース埋込で統一):
--   ・新規: :Studio [schemdraw|matplotlib|svg] → 現 md/typst の assets に <ts>.fig.svg を作り
--           リンクを挿入、temp .py を nvim で開く（pyright 補完）→ :w で SVG 再生成。
--   ・編集: ![](x.svg) 上で ,,e → x.svg に <metadata id="diagram-source"> があれば埋込ソースを
--           temp .py に復元して nvim で開く → :w で x.svg を上書き。
--   ・レイアウト(web版 nvim): py を新規タブで開くので左=py編集エリア / 右=Vivify ペイン(画像)。
--   ・プレビュー: 編集中は Vivify が対象 SVG を監視し、:w の再生成でリロード＝ライブ更新。
--
-- なぜ nvim 編集か: import に応じた本物の補完(pyright/jedi)が欲しいため。ブラウザの Ace は
-- 既出単語ベースで semantic 補完ができなかった。編集を nvim に寄せて LSP をそのまま使う。
-- 前提: python LSP(pyright) が studio と同じ env(schemdraw/matplotlib 入り)を解決できること。

local M = {}

local RENDER_PY = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py')

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
    local dir = vim.fn.stdpath('cache') .. '/figstudio'
    vim.fn.mkdir(dir, 'p')
    local base = vim.fn.fnamemodify(target, ':t:r'):gsub('%.fig$', '')
    return dir .. '/' .. base .. '-' .. vim.fn.sha256(target):sub(1, 8) .. '.py'
end

-- バッファ内容から SVG を再生成(render_schemdraw の CLI に stdin で渡す)
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

-- target(SVG) を source で編集する: temp .py を開き、:w で再生成、Vivify でライブプレビュー。
function M.edit(target, source)
    target = vim.fn.fnamemodify(target, ':p')
    local py = py_for(target)

    -- 新規タブで py を開く（左=編集エリアが丸ごと py になり、web版では右の Vivify ペインが
    -- 画像になる＝「左vim編集 / 右画像」の2ペイン）。:q/:tabclose で元のタブ(md)に戻る。
    -- 既に同じ temp を編集中なら、上書きせずそのバッファをタブで開く(未保存編集の保護)。
    local existing = vim.fn.bufnr(py)
    local bufnr
    if existing ~= -1 and vim.fn.bufloaded(existing) == 1 then
        vim.cmd('tab sbuffer ' .. existing)
        bufnr = existing
    else
        vim.fn.writefile(vim.split(source, '\n', { plain = true }), py)
        vim.cmd('tabedit ' .. vim.fn.fnameescape(py))
        bufnr = vim.api.nvim_get_current_buf()
        vim.bo[bufnr].filetype = 'python' -- 念のため(拡張子で自動判定されるはず)
        vim.b[bufnr].fig_target = target
        vim.api.nvim_create_autocmd('BufWritePost', {
            buffer = bufnr,
            callback = function() regen(bufnr) end,
            desc = 'figure: :w で対象 SVG を再生成',
        })
    end

    -- 初回生成(svg 未作成なら作る)してから Vivify でプレビュー
    regen(bufnr)
    require('vivify').open_path(target)
    vim.notify(
        '編集: ' .. vim.fn.fnamemodify(py, ':t') .. ' → :w で ' ..
        vim.fn.fnamemodify(target, ':t') .. ' 更新（補完は pyright）',
        vim.log.levels.INFO
    )
end

-- :Studio [kind] — 新規図を現 md/typst に作成して編集開始
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
    M.edit(target, TEMPLATES[kind] or TEMPLATES.schemdraw)
end

-- OpenDrawio(,,e)から: 埋込ソース付き SVG なら nvim で編集して true。違えば false(→draw.io)。
function M.try_edit_file(path)
    if not path or not path:match('%.svg$') then return false end
    local abs = resolve(path)
    if vim.fn.filereadable(abs) == 0 then return false end
    if not has_source(abs) then return false end
    M.edit(abs, extract_source(abs) or TEMPLATES.schemdraw)
    return true
end

function M.setup()
    vim.api.nvim_create_user_command('Studio', function(o)
        M.new(o.args ~= '' and o.args or nil)
    end, {
        nargs = '?',
        complete = function() return { 'schemdraw', 'matplotlib', 'svg' } end,
        desc = 'figure: 新規図を作成し nvim で編集(Python→SVG)',
    })
end

return M
