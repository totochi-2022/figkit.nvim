#!/usr/bin/env python3
"""annot server — スクショ等の画像に marker.js 3 で注釈を付ける小さなローカルサーバ。

figure studio(Streamlit) と違い依存ゼロ(stdlib のみ)。nvim の annotate.lua から
jobstart で立ち上がり、127.0.0.1 の固定ポートに居座る。

保存モデル（可逆・原本非破壊）:
    assets/<ts>.png        原本。img-clip が置いたまま。**絶対に書き換えない**
    assets/<ts>.ann.json   marker.js の AnnotationState。これが注釈の正本
    assets/<ts>.ann.png    合成結果（md が参照する・持ち出し用の生成物）

保存は「編集 → editorsave イベント → POST /save」。書き込み後、起動元 nvim の
socket へ --remote-expr で on_saved() を叩き、md のリンク差し替え＋preview 反映を
させる（studio.py と同じ手口。tmux send-keys 等は使わない）。

ルート:
    GET  /health                 "ok"
    GET  /annot?f=<abs>&sock=&buf=   エディタ本体(editor.html)。パラメータは JS 側が読む
    GET  /img?p=<abs>            画像バイト列（同一オリジン配信＝canvas が汚染されない）
    GET  /state?p=<abs>          <stem>.ann.json があれば返す。無ければ {}
    GET  /vendor/<file>          marker.js 一式
    POST /save                   {orig, state, dataUrl, sock, buf} を受けて書き出し
"""

import base64
import json
import mimetypes
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(HERE, "vendor")
DEFAULT_PORT = 31624

# 原本として受け付ける拡張子。.ann.png(合成済み)は nvim 側が原本に解決してから渡す。
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp")


def ann_paths(orig):
    """原本パス → (合成png, stateJson)。<stem>.ann.png / <stem>.ann.json"""
    stem, _ = os.path.splitext(orig)
    return stem + ".ann.png", stem + ".ann.json"


def notify_nvim(sock, payload):
    """起動元 nvim に保存を知らせる（失敗しても保存自体は成功なので握り潰す）。

    vim の文字列リテラルの入れ子を避けるため、lua チャンクは "" 側・JSON は '' 側に置く
    （JSON 内の ' は '' にエスケープ）。
    """
    if not sock or not os.path.exists(sock):
        return
    js = json.dumps(payload, ensure_ascii=False).replace("'", "''")
    expr = "luaeval(\"require('annotate').on_saved(vim.fn.json_decode(_A))\", '%s')" % js
    try:
        subprocess.run(
            ["nvim", "--server", sock, "--remote-expr", expr],
            timeout=5, capture_output=True,
        )
    except Exception as e:  # nvim が落ちている等。保存結果には影響させない
        print("notify_nvim failed: %s" % e, file=sys.stderr)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # アクセスログは出さない(nvim の jobstart 先なので邪魔)
        pass

    # --- helpers ---------------------------------------------------------
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")  # 保存のたびに作り直すので常に取り直す
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _file(self, path, ctype=None):
        if not os.path.isfile(path):
            return self._send(404, "not found")
        ctype = ctype or (mimetypes.guess_type(path)[0] or "application/octet-stream")
        with open(path, "rb") as f:
            self._send(200, f.read(), ctype)

    # --- GET -------------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        one = lambda k: (q.get(k) or [""])[0]

        if u.path == "/health":
            return self._send(200, "ok")

        if u.path in ("/", "/annot"):
            return self._file(os.path.join(HERE, "editor.html"), "text/html; charset=utf-8")

        if u.path.startswith("/vendor/"):
            name = os.path.basename(u.path)  # ディレクトリ脱出を防ぐ
            return self._file(os.path.join(VENDOR, name), "text/javascript; charset=utf-8")

        if u.path == "/img":
            p = one("p")
            if not p.lower().endswith(IMAGE_EXTS):
                return self._send(400, "not an image")
            return self._file(p)

        if u.path == "/state":
            p = one("p")
            _, state_path = ann_paths(p)
            if os.path.isfile(state_path):
                try:
                    with open(state_path, encoding="utf-8") as f:
                        return self._json(200, {"state": json.load(f)})
                except Exception as e:
                    return self._json(200, {"state": None, "error": str(e)})
            return self._json(200, {"state": None})

        return self._send(404, "not found")

    # --- POST ------------------------------------------------------------
    def do_POST(self):
        if urlparse(self.path).path != "/save":
            return self._send(404, "not found")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            return self._json(400, {"ok": False, "error": "bad request: %s" % e})

        orig = req.get("orig") or ""
        if not orig or not os.path.isfile(orig):
            return self._json(400, {"ok": False, "error": "原本が見つかりません: %s" % orig})

        ann_png, state_path = ann_paths(orig)
        try:
            # state が正本。先に書く（合成 png の書き出しに失敗しても注釈は失われない）
            with open(state_path, "w", encoding="utf-8") as f:
                json.dump(req.get("state") or {}, f, ensure_ascii=False, indent=1)

            data_url = req.get("dataUrl") or ""
            if "," in data_url:
                with open(ann_png, "wb") as f:
                    f.write(base64.b64decode(data_url.split(",", 1)[1]))
        except Exception as e:
            return self._json(500, {"ok": False, "error": str(e)})

        notify_nvim(req.get("sock"), {
            "orig": orig, "ann": ann_png, "state": state_path, "buf": req.get("buf"),
        })
        return self._json(200, {"ok": True, "ann": ann_png, "state": state_path})


def main():
    port = DEFAULT_PORT
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
