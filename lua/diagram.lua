-- diagram.lua — フェンス(```schemdraw 等)を SVG 化し、埋込ソースで再編集する
--
-- 方式(draw.io スタイル):
--   ```schemdraw フェンス(案A: d/elm/schemdraw がスコープ済)を python で SVG 化し、
--   元ソースを <metadata data-type="schemdraw"> に埋め込んで assets/ に保存、
--   md のフェンスを ![](assets/xxx.svg) に置換する。後で埋込ソースを復元して編集でき、
--   :w で同じ SVG を再生成する（拡張子は .svg のままなのでどこでも画像表示可）。
--
-- 既存の draw.io 統合(,,p SmartPaste / ,,e OpenDrawio)から共通で呼べるよう、
-- 「やれたら true」を返す try_render / try_edit_file を提供する。

local M = {}

local RENDER = {
    schemdraw = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py'),
}
local PY = 'python3' -- mise の python(schemdraw 入り)想定

-- python レンダラを stdin=source で実行し out へ SVG を書く。ok, err を返す
local function run_render(kind, source, out)
    local script = RENDER[kind]
    if not script then return false, '未対応の図種別: ' .. tostring(kind) end
    local res = vim.system({ PY, script, out }, { stdin = source, text = true }):wait()
    if res.code ~= 0 then
        return false, (res.stderr ~= '' and res.stderr or ('exit ' .. res.code))
    end
    return true, nil
end

-- カーソルを含む ```<kind> フェンスを探す。start行/end行(1-indexed)/kind/body を返す
local function find_fence()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local sf, kind
    for i = cur, 1, -1 do
        local k = lines[i]:match('^%s*```%s*(%a[%w_-]*)%s*$')
        if k then sf, kind = i, k; break end
        if i < cur and lines[i]:match('^%s*```%s*$') then break end
    end
    if not sf then return nil end
    local ef
    for i = sf + 1, #lines do
        if lines[i]:match('^%s*```%s*$') then ef = i; break end
    end
    if not ef then return nil end
    local body = table.concat(vim.api.nvim_buf_get_lines(0, sf, ef - 1, false), '\n')
    return sf, ef, kind, body
end

-- SVG から <metadata data-type="X"><![CDATA[...]]> を取り出す。kind, src を返す
local function extract_source(svg_path)
    local f = io.open(svg_path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    local kind = s:match('<metadata id="diagram%-source" data%-type="([%w_-]+)"')
    local src = s:match('<metadata id="diagram%-source"[^>]*><!%[CDATA%[(.-)%]%]></metadata>')
    if not src then return nil end
    src = src:gsub('%]%]%]%]><!%[CDATA%[>', ']]>') -- 埋込時に無害化した ]]> を戻す
    return kind, src
end

-- コア: カーソル下の対応フェンスを SVG 化して ![] に置換。name か nil,reason を返す
local function do_render()
    local sf, ef, kind, body = find_fence()
    if not sf then return nil, 'no_fence' end
    if not RENDER[kind] then return nil, 'unsupported:' .. kind end
    local mdpath = vim.fn.expand('%:p')
    if mdpath == '' then return nil, 'unsaved' end
    local dir = vim.fn.fnamemodify(mdpath, ':h')
    vim.fn.mkdir(dir .. '/assets', 'p')
    local name = kind .. '-' .. os.date('%Y%m%d-%H%M%S') .. '.svg'
    local ok, err = run_render(kind, body, dir .. '/assets/' .. name)
    if not ok then return nil, 'render:' .. err end
    vim.api.nvim_buf_set_lines(0, sf - 1, ef, false, { '![](assets/' .. name .. ')' })
    return name
end

-- スクラッチで埋込ソースを開き、:w で同じ SVG へ再生成する
local function open_editor(svg, kind, src)
    vim.cmd('vsplit')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(src, '\n'))
    vim.bo[buf].buftype = 'acwrite' -- :w を BufWriteCmd で受ける
    vim.bo[buf].filetype = 'python' -- schemdraw スニペットは python 風
    vim.api.nvim_buf_set_name(buf, 'diagram://' .. vim.fn.fnamemodify(svg, ':t'))
    vim.b[buf].diagram_svg = svg
    vim.b[buf].diagram_kind = kind
    vim.bo[buf].modified = false
    vim.api.nvim_create_autocmd('BufWriteCmd', {
        buffer = buf,
        callback = function()
            local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
            local ok, err = run_render(vim.b[buf].diagram_kind, body, vim.b[buf].diagram_svg)
            if not ok then
                vim.notify('再生成失敗:\n' .. err, vim.log.levels.ERROR)
                return
            end
            vim.bo[buf].modified = false
            vim.notify('再生成: ' .. vim.fn.fnamemodify(vim.b[buf].diagram_svg, ':t'))
        end,
    })
    vim.notify('編集: ' .. kind .. '（:w で SVG 再生成）')
end

-- 相対/絶対パスを編集中ファイル基準で絶対化
local function resolve(path)
    if path:match('^[/~]') then return vim.fn.expand(path) end
    return vim.fn.fnamemodify(vim.fn.expand('%:p:h') .. '/' .. path, ':p')
end

-- === 共通呼び出し用(bool を返す・通知控えめ) =============================

-- カーソルが対応フェンス内なら描画して true。違えば false。
function M.try_render()
    local name, reason = do_render()
    if name then
        vim.notify('生成: assets/' .. name)
        return true
    end
    if reason and reason:match('^render:') then
        vim.notify('描画失敗:\n' .. reason:sub(8), vim.log.levels.ERROR)
        return true -- フェンスではあった(=貼付にフォールバックしない)
    end
    if reason == 'unsaved' then
        vim.notify('ファイルが保存されていません', vim.log.levels.WARN)
        return true
    end
    return false -- no_fence / unsupported → 呼び元の従来処理へ
end

-- path が埋込ソース付き SVG(我々の生成物)なら nvim エディタで開いて true。違えば false。
function M.try_edit_file(path)
    if not path or path == '' or not path:match('%.svg$') then return false end
    local abs = resolve(path)
    if vim.fn.filereadable(abs) == 0 then return false end
    local kind, src = extract_source(abs)
    if not src or not RENDER[kind] then return false end
    open_editor(abs, kind, src)
    return true
end

-- === 明示コマンド ========================================================

function M.render() -- :DiagramRender
    local name, reason = do_render()
    if name then
        vim.notify('生成: assets/' .. name)
    elseif reason == 'no_fence' then
        vim.notify('カーソルが ```<kind> フェンス内にありません', vim.log.levels.WARN)
    elseif reason and reason:match('^unsupported:') then
        vim.notify('DiagramRender 未対応: ' .. reason:sub(13) .. '（対応: schemdraw）', vim.log.levels.WARN)
    elseif reason == 'unsaved' then
        vim.notify('ファイルが保存されていません', vim.log.levels.WARN)
    else
        vim.notify('描画失敗:\n' .. (reason or ''):gsub('^render:', ''), vim.log.levels.ERROR)
    end
end

function M.edit() -- :DiagramEdit
    local line = vim.api.nvim_get_current_line()
    local rel = line:match('!%[[^%]]*%]%(([^)]-%.svg)%)') or line:match('([%w%._/%-]+%.svg)')
    if not rel then
        vim.notify('カーソル行に .svg の参照がありません', vim.log.levels.WARN)
        return
    end
    if not M.try_edit_file(rel) then
        vim.notify('この SVG に編集ソースが無い/未対応（我々の生成物ではない）', vim.log.levels.WARN)
    end
end

function M.setup()
    vim.api.nvim_create_user_command('DiagramRender', M.render,
        { desc = 'カーソル下の ```schemdraw フェンスを SVG 化して ![] に置換' })
    vim.api.nvim_create_user_command('DiagramEdit', M.edit,
        { desc = '![](x.svg) の埋込ソースを編集（:w で再生成）' })
end

return M
