-- figure.lua — md に貼る図・画像の「作る / 直す」をまとめた入口。
--
-- 道具はすべて独立したコマンドとして登録し、その上に「自動判別」を薄く乗せる。
-- 判定が外れたときは個別コマンドを直接叩けば回避できる。
--
--   作る（クリップボードが入力）                直す（カーソル行が入力）
--   ---------------------------------------    ------------------------------------
--   :FigRenderPython    Python を実行→SVG      :FigEditSource     埋込ソースを編集
--   :FigPasteSvg        SVG を保存             :FigAnnotateImage  画像に注釈
--   :FigPasteDrawioXml  mxfile を保存          :FigOpenDrawioApp  draw.io.exe で開く
--   :FigPasteImage      画像を保存             :FigClipInfo       いま何が貼られるか確認
--   :FigPasteAuto  ← ,,p                       :FigEditAuto  ← ,,e
--
--   :FigOpenStudio       ← ,,s  Studio を単体で開く（作る→📋→,,p）
--   :FigNewFromTemplate  ← ,,m  テンプレから md に直接作る
--
-- なぜクリップボード経由に寄せたか:
--   以前「md のフェンスにカーソルを置いて :DiagramRender」という方式があったが、
--   バッファに「描画済み / 未描画」という中間状態ができて分からなくなり廃止された。
--   クリップボードを入力にすると中間状態が存在せず、貼った時点で常に
--   「ファイル + リンク」という1つの状態しかない。

local M = {}

local DRAWIO_EXE = '/mnt/c/Program Files/draw.io/draw.io.exe'
local RENDER_PY = vim.fn.expand('~/.config/nvim/vivify/render/render_schemdraw.py')

-- Python スニペットに要求するマーカー。誤爆防止であってセキュリティではない
-- （どうせローカルで exec するので完全な防御は無理）。他所からコピーした普通の
-- Python を間違って ,,p しても、これが無ければ実行されない。
local MARKER = 'figkit'

-- ---------------------------------------------------------------- helpers --

local function clip_text()
    local s = vim.fn.getreg('+')
    if s == nil or s == '' then s = vim.fn.getreg('*') end
    return s or ''
end

-- 保存先 assets/。名前付きバッファでないと決められないので nil を返す。
local function assets_dir()
    local base = vim.fn.expand('%:p:h')
    if base == '' or vim.bo.buftype ~= '' then
        vim.notify('保存先が不明です（名前付きで保存してから実行してください）', vim.log.levels.WARN)
        return nil
    end
    local dir = base .. '/assets'
    vim.fn.mkdir(dir, 'p')
    return dir
end

local function is_typst()
    return vim.bo.filetype == 'typst' or vim.fn.expand('%:e') == 'typ'
end

-- ファイル名 → 挿入するリンク文字列。表示できないものは通常リンクにする。
local function link_for(fname, displayable)
    if is_typst() then
        return displayable and ('#image("assets/' .. fname .. '")')
            or ('// drawio: assets/' .. fname)
    end
    return displayable and ('![](assets/' .. fname .. ')')
        or ('[drawio diagram](assets/' .. fname .. ')')
end

local function put_link(fname, displayable)
    vim.api.nvim_put({ link_for(fname, displayable) }, 'c', true, true)
end

-- 秒精度のタイムスタンプ名。同じ秒に2回貼ると衝突して**上書き**してしまうので、
-- 既にあれば -1, -2 … を足す（日記のファイル名と同じ流儀）。
local function unique_name(dir, stem, ext)
    local name = stem .. ext
    local n = 0
    while vim.fn.filereadable(dir .. '/' .. name) == 1 do
        n = n + 1
        name = stem .. '-' .. n .. ext
    end
    return name
end

local function timestamp()
    return os.date('%Y%m%d-%H%M%S')
end

-- カーソル下 / カーソル行からファイルパスを拾って絶対化する。
-- markdown `](path)` / typst `#image("path")` / コメント `drawio: path` に対応。
local function path_at_cursor()
    local cfile = vim.fn.expand('<cfile>')
    cfile = cfile:gsub('^["\']', ''):gsub('["\']$', '') -- typst のクォート除去
    if cfile == '' then
        local line = vim.api.nvim_get_current_line()
        cfile = line:match('%]%(([^)]+)%)')
            or line:match('image%(%s*"([^"]+)"')
            or line:match('drawio:%s*(%S+)')
            or ''
    end
    if cfile == '' then return nil end
    local path = cfile
    if not path:match('^[/~]') then
        path = vim.fn.expand('%:p:h') .. '/' .. cfile
    end
    return vim.fn.fnamemodify(vim.fn.expand(path), ':p')
end

-- ------------------------------------------------------------ 作る（貼る） --

-- クリップボードが「我々の図を作る Python スニペット」に見えるか。
-- マーカー(import figkit)と、レンダラの契約である out への書き出しの両方を要求する。
local function looks_like_figure_python(s)
    -- SVG/XML は先に弾く。**我々が作った SVG は Python ソースを <metadata> に
    -- 埋め込んでいる**ので、中身に import figkit も out も含まれてしまう。
    -- これを Python と誤認すると SVG 全体をレンダラに流して構文エラーになる。
    if s:match('<svg') or s:match('<mxfile') or s:match('<mxGraphModel') then
        return false
    end
    local has_marker = s:match('%f[%w]import%s+' .. MARKER .. '%f[%W]') ~= nil
    local writes_out = s:match('%f[%w]out%f[%W]') ~= nil
    return has_marker and writes_out
end

--- クリップボードの Python を実行して SVG を作り、リンクを挿入する。
function M.render_python()
    local src = clip_text()
    if not looks_like_figure_python(src) then
        vim.notify('図のスニペットに見えません。先頭に `import ' .. MARKER
            .. '` を入れ、`out` に保存してください', vim.log.levels.WARN)
        return
    end
    local dir = assets_dir()
    if not dir then return end

    local fname = unique_name(dir, timestamp(), '.fig.svg')
    local target = dir .. '/' .. fname
    local errfile = target .. '.err'
    local out = vim.fn.system({ 'python3', RENDER_PY, target, errfile }, src)
    if vim.v.shell_error ~= 0 then
        vim.notify('図の生成エラー: ' .. vim.trim(out), vim.log.levels.ERROR)
        return
    end
    put_link(fname, true)
    vim.notify('生成: assets/' .. fname .. '（,,e でソースを再編集）', vim.log.levels.INFO)
end

-- SVG / mxfile をそのまま assets/ に書く共通部分。
local function save_clip_as(ext, displayable, note)
    local dir = assets_dir()
    if not dir then return end
    local fname = unique_name(dir, timestamp(), ext)
    vim.fn.writefile(vim.split(clip_text(), '\n', { plain = true }), dir .. '/' .. fname)
    put_link(fname, displayable)
    vim.notify('保存: assets/' .. fname .. (note or ''), vim.log.levels.INFO)
end

--- クリップボードの SVG を保存する。
--- 出所で名前を変える: 埋込ソースあり(studio 産) → .fig.svg / それ以外(draw.io) → .drawio.svg
function M.paste_svg()
    local clip = clip_text()
    if not clip:match('<svg') then
        vim.notify('クリップボードに SVG がありません', vim.log.levels.WARN)
        return
    end
    local from_studio = clip:match('id="diagram%-source"') ~= nil
    save_clip_as(from_studio and '.fig.svg' or '.drawio.svg', true,
        from_studio and '（,,e でソースを再編集）' or '（,,e で draw.io が開く）')
end

--- クリップボードが mxfile/mxGraphModel だけのとき。再編集はできるが**表示できない**。
function M.paste_drawio_xml()
    local clip = clip_text()
    if not (clip:match('<mxfile') or clip:match('<mxGraphModel')) then
        vim.notify('クリップボードに draw.io の XML がありません', vim.log.levels.WARN)
        return
    end
    save_clip_as('.drawio', false,
        '（XMLは表示不可。draw.ioで「Copy as SVG」推奨）')
end

--- クリップボードの画像を保存する（img-clip に委譲）。
function M.paste_image()
    vim.cmd('PasteImage')
end

-- 直前に貼った内容。スクショを撮ったつもりでクリップボードが更新されておらず、
-- 前の SVG がもう一度貼られる事故が分かりにくいので、同じなら知らせる。
local last_pasted = nil

--- いま ,,p が何をするかだけ表示する（何も書き込まない）。
--- 「スクショを撮ったのに SVG が貼られる」等、クリップボードの中身が想像と違うときの確認用。
function M.clip_info()
    local clip = clip_text()
    local kind, detail
    if clip:match('<svg') then
        kind = 'SVG'
        detail = clip:match('id="diagram%-source"') and '→ .fig.svg（studio 産）'
            or '→ .drawio.svg'
    elseif clip:match('<mxfile') or clip:match('<mxGraphModel') then
        kind, detail = 'draw.io XML', '→ .drawio（表示不可）'
    elseif looks_like_figure_python(clip) then
        kind, detail = 'Python スニペット', '→ 実行して .fig.svg'
    else
        local ok, clipboard = pcall(require, 'img-clip.clipboard')
        if ok and clipboard and clipboard.content_is_image() then
            kind, detail = '画像', '→ .png'
        elseif #clip > 0 then
            kind = 'ただのテキスト(' .. #clip .. '文字)'
            detail = '→ 何もしない（Python なら `import ' .. MARKER .. '` が要る）'
        else
            kind, detail = '空', '→ 何もしない'
        end
    end
    local same = (last_pasted and clip == last_pasted) and '  ※前回貼ったものと同じ内容' or ''
    vim.notify('クリップボード: ' .. kind .. ' ' .. detail .. same, vim.log.levels.INFO)
end

--- クリップボードの中身を判定して振り分ける。
function M.paste_auto()
    local clip = clip_text()

    -- スクショを撮ったつもりでクリップボードが更新されていないと、直前の SVG が
    -- もう一度貼られる。黙って通すと気づけないので知らせる。
    if last_pasted and clip ~= '' and clip == last_pasted then
        vim.notify('前回と同じ内容を貼っています（クリップボードは更新されましたか？）',
            vim.log.levels.WARN)
    end
    if clip ~= '' then last_pasted = clip end

    -- マークアップを先に見る（上記のとおり SVG は Python を内包しうるため）
    if clip:match('<svg') then return M.paste_svg() end
    if clip:match('<mxfile') or clip:match('<mxGraphModel') then return M.paste_drawio_xml() end
    if looks_like_figure_python(clip) then return M.render_python() end

    -- 画像データ（img-clip の判定を使う。遅延ロードなのでここで require するとロードされる）
    local ok, clipboard = pcall(require, 'img-clip.clipboard')
    if ok and clipboard and clipboard.content_is_image() then
        return M.paste_image()
    end

    vim.notify('クリップボードに図・画像がありません（Python なら `import ' .. MARKER
        .. '` が要ります）', vim.log.levels.WARN)
end

-- ---------------------------------------------------------------- 直す --

--- カーソル行の図の埋込ソースを分割バッファで開く（:w で再生成）。
function M.edit_source()
    local path = path_at_cursor()
    if not path then
        vim.notify('カーソル行に図のリンクがありません', vim.log.levels.WARN)
        return
    end
    require('diagram').edit_source(path, vim.api.nvim_get_current_buf())
end

--- カーソル行の画像に注釈を付ける（marker.js）。
function M.annotate_image()
    local path = path_at_cursor()
    if not path then
        vim.notify('カーソル行に画像のリンクがありません', vim.log.levels.WARN)
        return
    end
    require('annotate').open(path, vim.api.nvim_get_current_buf())
end

--- カーソル行のファイルを draw.io.exe で開く。
function M.open_drawio_app()
    local path = path_at_cursor()
    if not path or vim.fn.filereadable(path) == 0 then
        vim.notify('カーソル行にファイルがありません', vim.log.levels.WARN)
        return
    end
    if vim.fn.executable(DRAWIO_EXE) == 0 then
        vim.notify('draw.io.exeが見つかりません: ' .. DRAWIO_EXE, vim.log.levels.ERROR)
        return
    end
    local winpath = require('wslpath').to_win(path)
    vim.fn.jobstart({ DRAWIO_EXE, winpath }, { detach = true })
    vim.notify('draw.ioで開く: ' .. vim.fn.fnamemodify(path, ':t'), vim.log.levels.INFO)
end

--- カーソル行の対象を判定して振り分ける。
function M.edit_auto()
    local path = path_at_cursor()
    if not path then
        vim.notify('カーソル下にファイルパスがありません', vim.log.levels.WARN)
        return
    end
    if vim.fn.filereadable(path) == 0 then
        vim.notify('ファイルが見つかりません: ' .. path, vim.log.levels.WARN)
        return
    end

    local md_buf = vim.api.nvim_get_current_buf()
    -- 埋込ソース付き(studio 産)なら分割バッファで編集。draw.io.exe は要らない。
    if require('diagram').try_edit_file(path) then return end
    -- 埋込ソースの無いラスタ画像（スクショ等）は注釈エディタへ。
    if require('annotate').try_edit_file(path, md_buf) then return end
    -- 残りは draw.io。
    M.open_drawio_app()
end

-- ------------------------------------------------------------ 新規作成 --

--- Studio を開く。
---   引数なし + カーソル行に既存の .fig.svg  → **その図**を開く（:w でその図を更新）
---   引数なし + それ以外                      → スクラッチ（📋 SVGコピー → ,,p で貼る）
---   引数あり（テンプレ名）                    → そのテンプレでスクラッチ
--- 化学構造式のように studio でしか出来ない操作(SMILES 検索)があるので、既存図を
--- 開き直せる入口は要る。スクラッチが欲しいときはテンプレ名を付ければよい。
function M.open_studio(kind)
    local diagram = require('diagram')
    if kind and kind ~= '' then
        return diagram.studio_scratch(kind)
    end
    local path = path_at_cursor()
    if path and path:match('%.fig%.svg$') then
        if diagram.studio_open(path) then return end
        -- 図の行に見えたのに開けなかった理由を伝える（黙ってスクラッチに落ちると
        -- 「その図で開いてくれない」としか見えない）。
        vim.notify('この図は studio で開けません（埋込ソースが無い / 読めない）: '
            .. vim.fn.fnamemodify(path, ':t') .. ' → スクラッチで開きます',
            vim.log.levels.WARN)
    end
    diagram.studio_scratch(nil)
end

--- テンプレから md に直接作る（ファイル作成＋リンク挿入＋分割バッファ）。
function M.new_from_template(kind, fmt)
    require('diagram').new(kind, fmt)
end

-- ------------------------------------------------------------ コマンド --

function M.setup()
    local cmd = vim.api.nvim_create_user_command
    local templates = { 'schemdraw', 'matplotlib', 'rdkit', 'raw' }
    local function complete_template() return templates end

    -- 作る（クリップボード）
    cmd('FigRenderPython', M.render_python,
        { desc = '図: クリップボードの Python を実行して SVG 化（import ' .. MARKER .. ' が必要）' })
    cmd('FigPasteSvg', M.paste_svg,
        { desc = '図: クリップボードの SVG を保存（出所で .fig.svg / .drawio.svg）' })
    cmd('FigPasteDrawioXml', M.paste_drawio_xml,
        { desc = '図: クリップボードの draw.io XML を保存（表示不可・リンクのみ）' })
    cmd('FigPasteImage', M.paste_image, { desc = '図: クリップボードの画像を保存' })
    cmd('FigPasteAuto', M.paste_auto, { desc = '図: クリップボードを判定して貼り付け' })
    cmd('FigClipInfo', M.clip_info,
        { desc = '図: いま ,,p が何をするかだけ表示（書き込まない）' })

    -- 直す（カーソル行）
    cmd('FigEditSource', M.edit_source, { desc = '図: 埋込ソースを編集（:w で再生成）' })
    cmd('FigAnnotateImage', M.annotate_image, { desc = '図: 画像に注釈（marker.js）' })
    cmd('FigOpenDrawioApp', M.open_drawio_app, { desc = '図: draw.io.exe で開く' })
    cmd('FigEditAuto', M.edit_auto, { desc = '図: カーソル行の対象を判定して再編集' })

    -- 新規作成
    cmd('FigOpenStudio', function(o) M.open_studio(o.fargs[1]) end,
        { nargs = '?', complete = complete_template,
          desc = '図: Studio を開く（カーソル行の図があればそれを / 無ければスクラッチ）' })
    cmd('FigNewFromTemplate', function(o)
        local kind, fmt
        for _, a in ipairs(o.fargs) do
            if a == 'svg' or a == 'png' or a == 'jpg' then fmt = a else kind = a end
        end
        M.new_from_template(kind, fmt)
    end, { nargs = '*',
           complete = function() return { 'schemdraw', 'matplotlib', 'rdkit', 'raw', 'svg', 'png' } end,
           desc = '図: テンプレから md に直接作成' })
end

return M
