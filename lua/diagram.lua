-- diagram.lua — 図は Streamlit の figure studio(Python→SVG)で作成/編集する。
--
-- 方式(draw.io と同思想・SVG固定・ソース埋込で統一):
--   ・新規: :Studio で studio を空で開く → 書く → SVG コピー → md で ,,p(SmartPaste が保存+![]挿入)
--   ・編集: ![](x.svg) 上で ,,e → x.svg に我々の <metadata id="diagram-source"> があれば studio を
--           ?svg=x.svg で開く（埋込ソース復元）→ 保存で上書き。draw.io の SVG(content=mxfile)は
--           従来どおり draw.io.exe（呼び分けは OpenDrawio 側、ここは我々のSVGだけ true を返す）。

local M = {}

local STUDIO_PORT = 8501
local STUDIO_PY = vim.fn.expand('~/.config/nvim/vivify/render/studio.py')

-- studio(streamlit)が稼働中か（health を同期 curl・短タイムアウト）
local function studio_up()
    local out = vim.fn.system(
        { 'curl', '-s', '-m', '1', 'http://localhost:' .. STUDIO_PORT .. '/_stcore/health' }
    )
    return vim.trim(out) == 'ok'
end

-- studio を起動(未起動なら)してブラウザで開く。svg 省略=新規、指定=?svg= で編集。
function M.studio(svg)
    local up = studio_up()
    if not up then
        vim.fn.jobstart({
            'python3', '-m', 'streamlit', 'run', STUDIO_PY,
            '--server.headless=true', '--server.port=' .. STUDIO_PORT,
            '--browser.gatherUsageStats=false',
        }, { detach = true })
    end
    local url = 'http://localhost:' .. STUDIO_PORT .. '/'
    if svg and svg ~= '' then url = url .. '?svg=' .. svg end
    -- 起動直後は listen まで待つ（起動済みなら即開く）
    vim.defer_fn(function()
        vim.fn.jobstart({ 'wslview', url }, { detach = true })
    end, up and 150 or 3500)
end

-- SVG に我々の埋込ソースマーカー(<metadata id="diagram-source">)があるか
local function has_source(svg_path)
    local f = io.open(svg_path, 'r')
    if not f then return false end
    local head = f:read(8192) or ''
    f:close()
    return head:find('id="diagram%-source"') ~= nil
end

local function resolve(path)
    if path:match('^[/~]') then return vim.fn.expand(path) end
    return vim.fn.fnamemodify(vim.fn.expand('%:p:h') .. '/' .. path, ':p')
end

-- OpenDrawio(,,e)から呼ばれる: 我々の埋込SVGなら studio を開いて true。
-- 違えば false（→ OpenDrawio が draw.io.exe へフォールバック）。
function M.try_edit_file(path)
    if not path or not path:match('%.svg$') then return false end
    local abs = resolve(path)
    if vim.fn.filereadable(abs) == 0 then return false end
    if not has_source(abs) then return false end
    M.studio(abs)
    vim.notify('studio で編集: ' .. vim.fn.fnamemodify(abs, ':t'))
    return true
end

function M.setup()
    vim.api.nvim_create_user_command('Studio', function()
        M.studio(nil)
    end, { desc = 'figure studio を新規で開く(Python→SVG)' })
end

return M
