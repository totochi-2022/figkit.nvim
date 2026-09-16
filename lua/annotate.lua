-- annotate.lua — スクショ等の画像に marker.js 3 で注釈を付ける（`,,e` / :Annot）。
--
-- figure studio(diagram.lua)が「Python ソース → 図」なのに対し、こちらは
-- 「既にある画像 → 注釈を重ねる」担当。draw.io と同じく round-trip できる:
--
--   assets/<ts>.png       原本(img-clip が置いたもの)。**書き換えない**
--   assets/<ts>.ann.json  marker.js の AnnotationState。注釈の正本(git の差分が読める)
--   assets/<ts>.ann.png   合成結果。md はこれを参照する(持ち出し用の生成物)
--
-- 原本が残るので注釈はいつでもやり直せる。`,,e` を .ann.png に対して押すと原本 + state に
-- 解決して編集を再開する（合成済み画像へ二重に焼き込む事故が起きない）。
--
-- 保存経路: ブラウザ(editor.html) → POST /save → server.py が2ファイル書き出し →
-- nvim の socket へ --remote-expr で on_saved() → md のリンクを .ann.png に差し替え +
-- Vivify preview を reload。studio.py と同じ手口（tmux send-keys は使わない）。

local M = {}

local PORT = 31624
local SERVER_PY = vim.fn.expand('~/.config/nvim/vivify/annot/server.py')

-- 合成 .ann.png の書き出し最大幅[px]。0 で原寸。
-- 各ビューアは img に max-width:100% を掛けるので、カラム幅(Vivify 900 / GitHub 約890)より
-- 大きく出しても表示は変わらない。**表示まで小さくしたいのでカラム幅より小さく出す**。
-- md に {width=..} や <img> を書かずに全ビューアで効くのが利点(自前ツールの ](..) 前提も壊さない)。
-- 原本と state は残るので、この値を変えて焼き直せば何度でもやり直せる。
local MAX_WIDTH = 720

-- 注釈対象にする拡張子。svg は draw.io / figure studio の領分なので含めない。
local RASTER = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true }

local function is_raster(path)
    return RASTER[vim.fn.fnamemodify(path, ':e'):lower()] == true
end

local function resolve(path)
    if path:match('^[/~]') then return vim.fn.expand(path) end
    return vim.fn.fnamemodify(vim.fn.expand('%:p:h') .. '/' .. path, ':p')
end

-- 合成済み(.ann.png)なら原本に戻す。原本の拡張子は .png とは限らないので総当たりで探す。
-- 見つからなければ nil（= 原本を消した/移動した。焼き込み画像に重ね描きはさせない）。
local function to_original(path)
    local stem = path:match('^(.*)%.ann%.png$')
    if not stem then return path end
    for ext in pairs(RASTER) do
        local cand = stem .. '.' .. ext
        if vim.fn.filereadable(cand) == 1 then return cand end
    end
    return nil
end

-- URL クエリに載せるためのパーセントエンコード（パスに空白/日本語が入っても壊れないように）
local function urlenc(s)
    return (tostring(s or ''):gsub('[^%w._~-]', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

local function server_up()
    local out = vim.fn.system({ 'curl', '-s', '-m', '1', 'http://127.0.0.1:' .. PORT .. '/health' })
    return vim.trim(out) == 'ok'
end

local function ensure_server()
    if server_up() then return false end
    vim.fn.jobstart({ 'python3', SERVER_PY, '--port', tostring(PORT) }, { detach = true })
    return true -- 起動したてなので listen 待ちが要る
end

-- 保存通知を受けるための socket。web(nvim-server)でも端末でも v:servername は基本立つが、
-- 空なら自前で listen する（通知が来ないと md のリンク差し替えが手動になるため）。
local function servername()
    local s = vim.v.servername
    if s == nil or s == '' then
        local ok, res = pcall(vim.fn.serverstart)
        s = ok and res or ''
    end
    return s
end

--- 画像を注釈エディタで開く。
--- @param path string 画像パス（原本 or .ann.png。相対なら現バッファ基準）
--- @param md_buf number|nil リンク元の md バッファ（保存後にリンク差し替え＋reload する先）
function M.open(path, md_buf)
    local abs = vim.fn.fnamemodify(resolve(path), ':p')
    if vim.fn.filereadable(abs) == 0 then
        vim.notify('画像が見つかりません: ' .. abs, vim.log.levels.WARN)
        return
    end
    local orig = to_original(abs)
    if not orig then
        vim.notify('原本が見つかりません（消した/移動した？）: ' .. vim.fn.fnamemodify(abs, ':t')
            .. ' — 焼き込み済み画像への重ね描きは避けています', vim.log.levels.WARN)
        return
    end

    local started = ensure_server()
    local url = string.format('http://localhost:%d/annot?f=%s&sock=%s&buf=%d&maxw=%d',
        PORT, urlenc(orig), urlenc(servername()),
        md_buf or vim.api.nvim_get_current_buf(), MAX_WIDTH)

    local ch = vim.g.nvim_server_channel
    vim.defer_fn(function()
        if type(ch) == 'number' and ch > 0 then
            vim.rpcnotify(ch, 'web_open_url', url, 'Annot') -- web: 右プレビューペイン
        else
            vim.fn.jobstart({ 'wslview', url }, { detach = true }) -- 端末: ブラウザタブ
        end
    end, started and 1200 or 150)

    vim.notify('注釈: ' .. vim.fn.fnamemodify(orig, ':t')
        .. string.format('（保存で .ann.png を生成＋リンク差替 / 最大幅 %dpx）', MAX_WIDTH),
        vim.log.levels.INFO)
end

-- server.py から --remote-expr で呼ばれる。md のリンクを原本 → .ann.png に差し替え、
-- preview に反映する。バッファは書き換えるだけで :w はしない（`,,p` の貼り付けと同じ流儀）。
function M.on_saved(info)
    local buf = tonumber(info.buf) or 0
    local ann_base = vim.fn.fnamemodify(info.ann, ':t')
    if buf == 0 or not vim.api.nvim_buf_is_valid(buf) then
        vim.notify('注釈を保存: ' .. ann_base, vim.log.levels.INFO)
        return 0
    end

    local orig_base = vim.fn.fnamemodify(info.orig, ':t')
    local repl = ann_base:gsub('%%', '%%%%') -- gsub の置換文字列で % を literal 扱いにする
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local hit = false
    for i, line in ipairs(lines) do
        -- 既に .ann.png を指している行は原本名を含まないので素通りする
        if line:find(orig_base, 1, true) then
            lines[i] = line:gsub(vim.pesc(orig_base), repl)
            hit = true
        end
    end
    if hit then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    pcall(function() require('vivify').reload(buf) end) -- ?v= を付け直してキャッシュを外す
    vim.notify('注釈を保存: ' .. ann_base .. (hit and '（リンク差替）' or ''), vim.log.levels.INFO)
    return 0 -- --remote-expr の戻り値（数値にして余計な出力を出さない）
end

-- OpenDrawio(,,e)から: ラスタ画像なら注釈エディタで開いて true。svg 等なら false。
function M.try_edit_file(path, md_buf)
    if not path or not is_raster(path) then return false end
    M.open(path, md_buf)
    return true
end

function M.setup()
    vim.api.nvim_create_user_command('Annot', function(o)
        local md_buf = vim.api.nvim_get_current_buf()
        local target = vim.trim(o.args)
        if target == '' then
            local line = vim.api.nvim_get_current_line()
            target = line:match('%]%(([^)?#]+)') or line:match('image%(%s*"([^"]+)"') or ''
        end
        if target == '' then
            vim.notify('カーソル行に画像リンクがありません（:Annot <path> でも可）', vim.log.levels.WARN)
            return
        end
        M.open(target, md_buf)
    end, { nargs = '?', complete = 'file', desc = '画像に marker.js で注釈（保存で .ann.png 生成）' })
end

return M
