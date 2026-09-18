-- wslpath.lua
-- WSL ⇄ Windows パス相互変換の共通ユーティリティ。
-- ドラッグ&ドロップ/貼り付けで来る Windows・UNC パスの取り込み（to_wsl）と、
-- explorer.exe 等に渡す Windows パスへの変換（to_win）を一箇所に集約する。
-- WSL 以外の環境（wslpath 不在）では、できる範囲で恒等変換にフォールバックする。

local M = {}

-- WSL 環境か（wslpath が使えるか）
function M.available()
  return vim.fn.executable("wslpath") == 1
end

-- 貼り付け由来のゴミを掃除: 前後の空白/改行・囲みクォート("..." '...')
local function clean(s)
  s = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  return s
end
M.clean = clean

-- Windows/UNC パス → WSL パス
--   1. クォート/空白を除去（←これが無いと空白入りパスが壊れる）
--   2. 既に Unix/WSL パス(/始まり)ならそのまま
--   3. wslpath に委譲（ドライブパスも \\wsl.localhost\ UNC も変換できる）
--   4. wslpath が扱えなかった WSL UNC のみ手動フォールバック
function M.to_wsl(path)
  local p = clean(path)
  if p == "" then
    return path
  end
  if p:sub(1, 1) == "/" then
    return p
  end
  if M.available() then
    local handle = io.popen("wslpath '" .. p:gsub("'", "'\\''") .. "' 2>/dev/null")
    if handle then
      local out = handle:read("*a"):gsub("%s+$", "")
      handle:close()
      if out ~= "" and out:sub(1, 1) == "/" then
        return out
      end
    end
  end
  -- フォールバック: \\wsl.localhost\<distro>\... / \\wsl$\<distro>\... → /...
  local rest = p:match("^\\\\wsl%.localhost\\[^\\]+\\(.*)$")
    or p:match("^\\\\wsl%$\\[^\\]+\\(.*)$")
  if rest then
    return "/" .. rest:gsub("\\", "/")
  end
  return p
end

-- WSL パス → Windows パス（explorer.exe 等に渡す用、wslpath -w）
function M.to_win(path)
  local p = clean(path)
  if p == "" then
    return path
  end
  if M.available() then
    local out = vim.fn.system({ "wslpath", "-w", p }):gsub("%s+$", "")
    if vim.v.shell_error == 0 and out ~= "" then
      return out
    end
  end
  return p
end

-- Windows/UNC パスっぽいか（C:\ , C:/ , \\server\ , \\wsl.localhost\ ...）
function M.is_windows_path(path)
  local p = clean(path)
  return p:match("^%a:[/\\]") ~= nil or p:match("^\\\\") ~= nil
end

-- ファイル/ディレクトリの実在チェック
function M.exists(path)
  return vim.loop.fs_stat(path) ~= nil
end

return M
