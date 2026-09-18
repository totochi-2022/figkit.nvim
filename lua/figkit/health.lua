-- figkit の依存チェック（`:checkhealth figkit`）。
--
-- 依存が多く、しかも**機能ごとに要るものが違う**ので、機能単位で分けて報告する。
-- 「図は描けるが Studio は上がらない」「注釈は動くが縮小が粗い」のような部分的な
-- 欠けが多いため、まとめて「NG」にすると何が使えるのか分からなくなる。
--
-- 方針:
--   error … その機能が**全く動かない**もの
--   warn  … 品質が落ちる / 一部のテンプレだけ動かない
--   info  … 環境依存で「無くて当然」のもの
--
-- 副作用は持たない（プロセスを起こさない・ファイルを書かない）。
-- 唯一 HTTP を1本だけ叩くが、それは「既に上がっているサーバ」への確認のみ。

local M = {}

local H = vim.health
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

--- 実行ファイルの有無。found なら ok、無ければ level(warn/error) で理由を出す。
local function need_exe(name, what, level, advice)
    if vim.fn.executable(name) == 1 then
        H.ok(('%s — %s'):format(name, what))
        return true
    end
    H[level](('%s が無い — %s'):format(name, what), advice)
    return false
end

--- python モジュールの有無。python3 が無いときは呼ばない。
local function py_has(mod)
    vim.fn.system({ 'python3', '-c', 'import ' .. mod })
    return vim.v.shell_error == 0
end

--- そのポートを listen しているプロセスを返す（無ければ nil）。
local function port_owner(port)
    if vim.fn.executable('ss') ~= 1 then return nil end
    local out = vim.fn.system({ 'ss', '-ltnHp', 'sport = :' .. port })
    if vim.v.shell_error ~= 0 or out == '' then return nil end
    -- users:(("python3",pid=12345,fd=3)) から名前と pid を抜く
    local name, pid = out:match('users:%(%("([^"]+)",pid=(%d+)')
    if name then return ('%s(pid %s)'):format(name, pid) end
    return '不明なプロセス'
end

function M.check()
    ---------------------------------------------------------------- 図の生成
    H.start('figkit: 図の生成（,,p / ,,m / ,,e→:w）')
    local py = need_exe('python3', 'Python スニペットを図にする中核', 'error',
        { 'これが無いと ,,p / ,,m / ,,e の再生成が動かない' })
    if py then
        -- Pillow: SVG だけなら不要。png/jpg 出力とソース埋込・注釈の縮小に要る
        if py_has('PIL') then
            H.ok('Pillow — png/jpg 出力とソース埋込、注釈の高品質縮小')
        else
            H.warn('Pillow が無い — SVG は作れるが png/jpg が使えない', {
                'pip install pillow',
                '注釈の縮小もブラウザ側フォールバックになる（品質が落ちる）',
            })
        end
        -- 描画ライブラリはテンプレごと。1つも無ければ図が作れないので error
        local libs = { schemdraw = '回路図', matplotlib = 'グラフ', rdkit = '化学構造式' }
        local found = 0
        for mod, what in pairs(libs) do
            if py_has(mod) then
                H.ok(('%s — %s のテンプレ'):format(mod, what))
                found = found + 1
            else
                H.warn(('%s が無い — %s のテンプレが動かない'):format(mod, what),
                    { 'pip install ' .. mod })
            end
        end
        if found == 0 then
            H.error('描画ライブラリが1つも無い — どのテンプレも動かない',
                { 'pip install schemdraw matplotlib rdkit' })
        end
    end
    -- 同梱スクリプト（パス解決が壊れていないか）
    for _, f in ipairs({ 'render/render_schemdraw.py', 'render/studio.py' }) do
        if vim.fn.filereadable(ROOT .. '/' .. f) == 1 then
            H.ok('同梱: ' .. f)
        else
            H.error('同梱スクリプトが読めない: ' .. ROOT .. '/' .. f,
                { 'プラグインの clone が壊れている可能性がある' })
        end
    end

    ---------------------------------------------------------------- 画像注釈
    H.start('figkit: 画像注釈（,,e / :FigAnnotateImage）')
    H.info('サーバは stdlib のみで動く（Streamlit 不要）')
    local assets = {
        'annot/server.py', 'annot/editor.html',
        'annot/vendor/markerjs3.umd.js', 'annot/vendor/markerjs-ui.umd.js',
    }
    local missing = {}
    for _, f in ipairs(assets) do
        if vim.fn.filereadable(ROOT .. '/' .. f) ~= 1 then table.insert(missing, f) end
    end
    if #missing == 0 then
        H.ok(('同梱アセット %d件すべて読める（marker.js 一式を含む）'):format(#assets))
    else
        H.error('同梱アセットが欠けている: ' .. table.concat(missing, ', '))
    end

    ---------------------------------------------------------------- Studio
    H.start('figkit: Studio（,,s）')
    need_exe('ttyd', '左ペインの nvim をブラウザに出す', 'warn',
        { 'sudo apt install ttyd（無いと Studio の左が空になる）' })
    need_exe('tmux', 'Studio 内 nvim の永続化（ブラウザを閉じても編集が残る）', 'warn',
        { 'sudo apt install tmux' })
    need_exe('curl', 'Streamlit の起動済み判定', 'warn', { 'sudo apt install curl' })
    if py and not py_has('streamlit') then
        H.warn('streamlit が無い — Studio が開けない（図の生成自体は動く）',
            { 'pip install streamlit' })
    elseif py then
        H.ok('streamlit — Studio のツールバーと2ペイン')
    end
    if vim.fn.executable('pyright') == 1 or vim.fn.executable('pyright-langserver') == 1 then
        H.ok('pyright — Studio 左ペインの補完')
    else
        H.info('pyright が無い — Studio でも補完が出ないだけ（Mason 経由なら別パスにある）')
    end
    need_exe('pkill', ':FigStopStudio で止める', 'warn', { 'procps が必要' })
    need_exe('ss', 'ポートの使用状況の判定', 'warn', { 'iproute2 が必要' })

    ---------------------------------------------------------------- ポート
    H.start('figkit: ポート（古いプロセスの居残り）')
    -- ファイルを動かしたあとも**プロセスは古いコードとパスを掴んだまま**なので、
    -- ここが「動くはずなのに 404 / 反映されない」の原因になりやすい。
    local ports = {
        { 31624, '注釈サーバ',     'annot' },
        { 7690,  'ttyd',           'studio' },
        { 8501,  'Streamlit',      'studio' },
        { 8770,  'Studio の /jump', 'studio' },
    }
    local any = false
    for _, p in ipairs(ports) do
        local owner = port_owner(p[1])
        if owner then
            any = true
            H.info(('%d (%s) — %s が使用中'):format(p[1], p[2], owner))
        end
    end
    if not any then
        H.ok('4ポート(31624/7690/8501/8770) すべて空 — 居残りプロセス無し')
    else
        -- 注釈サーバだけは「同梱アセットを返せるか」で新旧を判定できる
        if port_owner(31624) and vim.fn.executable('curl') == 1 then
            local code = vim.fn.system({ 'curl', '-s', '-m', '2', '-o', '/dev/null',
                '-w', '%{http_code}', 'http://127.0.0.1:31624/vendor/markerjs3.umd.js' })
            if code == '200' then
                H.ok('31624 の注釈サーバは現行パスを返せている')
            else
                H.error(('31624 の注釈サーバが古い（/vendor が HTTP %s）'):format(code), {
                    'プラグインを移動/更新する前に起動したサーバが残っている',
                    'pkill -f annot/server.py で落とす（次回 ,,e で新しいのが上がる）',
                })
            end
        end
        H.info('反映されない / 404 が出るときは :FigStopStudio（! で ttyd/tmux も）')
    end

    ---------------------------------------------------------------- 繋ぎ
    H.start('figkit: 連携と環境')
    local cfg = require('figkit').config
    -- クリップボード画像（,,p でスクショを貼る経路）
    if pcall(require, 'img-clip.clipboard') then
        H.ok('img-clip.nvim — クリップボード画像の判定と保存')
    else
        H.error('img-clip.nvim が無い — ,,p で画像を貼れない（テキストの判定は動く）',
            { 'dependencies に "HakonHarnes/img-clip.nvim" を入れる' })
    end
    -- --remote-expr のコールバック先。無いと保存しても md に反映されない
    if vim.v.servername ~= '' then
        H.ok('v:servername = ' .. vim.v.servername .. ' — 注釈/Studio の書き戻し先')
    else
        H.error('v:servername が空 — 注釈や Studio の 📄 が md に反映できない',
            { 'nvim --listen <path> で起動する（通常は自動で付く）' })
    end
    -- クリップボード provider（,,p の入力そのもの）
    if vim.fn.has('clipboard') == 1 then
        H.ok('clipboard provider あり — ,,p がシステムのクリップボードを読める')
    else
        H.warn('clipboard provider が無い — ,,p が空になる', { ':checkhealth provider を見る' })
    end
    -- URL を開く手段（既定は wslview → vim.ui.open）
    if vim.fn.executable('wslview') == 1 then
        -- wslu 3.x は binfmt を**旧名 `WSLInterop` でしか探さない**。WSL 側が
        -- 新名 `WSLInterop-late` で登録していると「WSL Interopability is disabled」
        -- になり、viv/ttyd は上がるのにタブが出ないという症状になる。
        -- ただし 3.x でも登録名が旧名ならそのまま動くので、**両方**見て判定する
        -- （バージョンだけで警告すると、動いている環境に誤報を出す）。
        local v = vim.fn.system({ 'wslview', '--version' }):match('%d+%.%d+[%.%d]*') or '?'
        local major = tonumber(v:match('^(%d+)')) or 0
        local bf = '/proc/sys/fs/binfmt_misc/'
        local old_name = vim.fn.isdirectory(bf) == 1 and vim.fn.filereadable(bf .. 'WSLInterop') == 1
        local late = vim.fn.filereadable(bf .. 'WSLInterop-late') == 1
        if major >= 4 then
            H.ok('wslu ' .. v .. ' — 注釈/Studio をブラウザで開く（binfmt の新旧どちらでも可）')
        elseif old_name then
            H.ok('wslu ' .. v .. ' — binfmt が旧名 WSLInterop で登録されているので動く')
            H.info('ただし WSL 側が WSLInterop-late に変わると開けなくなる（wslu 4.x 推奨）')
        elseif late then
            H.error('wslu ' .. v .. ' は binfmt の新名 WSLInterop-late を認識できない', {
                'viv/ttyd は上がるのにブラウザタブが出ない症状になる',
                'PPA の wslu 4.x を入れる:',
                'sudo add-apt-repository ppa:wslutilities/wslu && sudo apt install wslu',
            })
        else
            H.info('wslu ' .. v .. ' — binfmt 登録が見つからない（WSL 以外なら正常）')
        end
    elseif vim.ui and vim.ui.open then
        H.info('wslview は無いが vim.ui.open にフォールバックする（WSL 以外なら正常）')
    else
        H.warn('URL を開く手段が無い — opts.open_url を自分で指定する必要がある')
    end
    -- draw.io デスクトップ版（:FigOpenDrawioApp のみ）
    if vim.fn.executable(cfg.drawio_exe) == 1 then
        H.ok('draw.io — :FigOpenDrawioApp で .drawio.svg を開ける')
    else
        H.info('draw.io が無い（' .. cfg.drawio_exe .. '）— :FigOpenDrawioApp だけが使えない。'
            .. '場所が違うなら opts.drawio_exe で指定する')
    end
    -- preview 連携（フックが差し替えられているか）
    local hooked = cfg.on_change ~= nil
        and debug.getinfo(cfg.on_change, 'S').short_src:find('figkit') == nil
    if hooked then
        H.ok('opts.on_change が設定されている — 図を書いたあと preview が更新される')
    else
        H.info('opts.on_change 未設定 — 図は作れるが preview の自動更新はしない（既定）')
    end
end

return M
