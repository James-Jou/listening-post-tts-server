# SPDX-License-Identifier: GPL-3.0-or-later
#
# Listening Post TTS Server —— 聽哨 Listening Post 的本地語音合成伺服器。
# Copyright (C) 2026  James Jou
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# 為什麼這支程式是 GPL：見下方 docstring「GPL 隔離」一節。簡言之——它在**同一個行程內**
# 動態連結了 espeak-ng（GPL-3.0-or-later），所以它自己也必須是 GPL。呼叫它的遊戲本體
# 不必，因為那是跨行程的 HTTP 呼叫，不是連結。
"""Kokoro TTS 本地背景伺服器。

## 這支程式在做什麼
遊戲主程式（Godot / TTS_Server 的呼叫端）完全不會 import 或連結這支程式的任何一行程式碼、
也不會連結 Kokoro / espeak-ng 的任何函式庫。雙方唯一的溝通管道是本機 loopback
（127.0.0.1）上的一個 HTTP 連線——文字進、WAV 位元組出。這支伺服器會被 PyInstaller
打包成一個完全獨立的可執行檔（TTS_Server.exe），跟遊戲主程式是兩個不同的作業系統行程。

## 為什麼要這樣設計（GPL 隔離）
Kokoro 模型本身是 Apache-2.0，但目前 kokoro-onnx 這個 Python 套件預設的文字轉音素
（G2P）路徑一定會載入 espeak-ng 的共用函式庫（透過 espeakng-loader 套件，espeak-ng
本身是 GPL-3.0）。如果把這段程式碼直接編譯連結進遊戲主程式，遊戲主程式就會被視為
espeak-ng 的衍生／結合作品，必須跟著 GPL-3.0 授權——這是要避免的情況，尤其是要上
Steam 賣的商業版。

做法是把「會摸到 GPL 程式碼」的部分整個關進一個獨立的、透過作業系統行程邊界隔離的
執行檔裡：
  - 不與遊戲主程式共用記憶體位址空間，不做任何形式的靜態或動態連結
  - 溝通只透過本機 HTTP（文字/JSON 進，WAV bytes 出），這跟呼叫任何外部命令列工具
    （例如很多商業軟體背地裡呼叫 ffmpeg-gpl.exe）性質相同
  - 兩個執行檔即使被放進同一個安裝資料夾、同一份 Steam 安裝包一起發行，也只是
    GPL 第 5 條所說的「單純聚合（mere aggregation）」——各自獨立的程式被放在同一個
    散布媒介上，不會讓其中一個程式的授權條款「傳染」給另一個
  - 呼叫端只送 HTTP，沒有抄也沒有衍生 Kokoro / espeak-ng / kokoro-onnx 的任何一行
    原始碼，因此不受它們的授權條款拘束

## 但是這支程式（server.py）自己是 GPL——別搞錯這一點
分界線在「行程邊界」，不在「誰寫的」。這支程式雖然是原創，但它在**同一個行程內**
透過 phonemizer-fork / espeakng-loader 動態連結了 espeak-ng（GPL-3.0-or-later）；
打包出來的 TTS_Server.exe 是「本程式 ＋ espeak-ng」的結合作品。因此：

  - **本檔案與整個 repo 以 GPL-3.0-or-later 授權散布**（見同層 LICENSE）
  - 散布 TTS_Server.exe 時必須一併提供它對應的完整原始碼（GPLv3 §6）——
    本 repo 就是在履行這項義務；發行版另外會把同一份原始碼壓進安裝包一併附上
  - 遊戲本體不受影響：它與本程式之間只有 127.0.0.1 的 HTTP，沒有任何連結關係，
    兩者一起放進同一份 Steam 安裝包屬於 GPL 第 5 條的「單純聚合（mere aggregation）」

換句話說：GPL 被物理性地關在 TTS_Server.exe 這個行程裡（連同這支原始碼一起 GPL 化，
這是預期內的代價），不會擴散到遊戲主程式（Steam 上架的那個執行檔）。

**注意**：這不是正式法律意見。「單純聚合」是 GPL 條文與 FSF 官方 GPL FAQ 都明確允許
的做法，業界也普遍這樣處理（本機呼叫 GPL 命令列工具很常見），但實際上架 Steam 前，
建議還是花點小錢找律師看一次授權鏈，尤其確認 espeak-ng 資料檔本身的授權（部分語音
資料另有授權）沒有問題。

## 執行方式
    python server.py --model kokoro-v1.0.onnx --voices voices-v1.0.bin --port 8765

打包成 TTS_Server.exe 後：
    TTS_Server.exe --model kokoro-v1.0.onnx --voices voices-v1.0.bin --port 8765

## API
- GET  /health                → 200 "ok"（伺服器已就緒，模型已載入）
- POST /synthesize             body: {"text","voice","speed","lang"} → 200，body 為 WAV bytes
- POST /synthesize_batch       body: {"items":[{"text","voice","speed","lang"}, ...]}
                                → 200，body 為 JSON {"wavs": ["<base64 wav>", ...]}（依原順序）
- POST /shutdown                → 200，之後伺服器行程會自行結束（正常關閉用；
                                   遊戲端也可以直接用 PID 強制關閉，兩條路都支援）
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import pathlib
import sys
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

# kokoro_onnx 是唯一會去載入 espeak-ng 共用函式庫的地方（見 Tokenizer.__init__）。
# 這支伺服器整個存在的目的，就是把這個 import 隔離在自己的行程裡。
from kokoro_onnx import Kokoro

_kokoro: Kokoro | None = None
_lock = threading.Lock()  # onnxruntime InferenceSession 不保證併發安全，簡單序列化請求
_shutdown_event = threading.Event()


def _samples_to_wav_bytes(samples: np.ndarray, sample_rate: int) -> bytes:
	"""float32 [-1,1] 樣本轉成 16-bit PCM WAV bytes（不額外依賴 soundfile，PyInstaller 打包更輕）。"""
	clipped = np.clip(samples, -1.0, 1.0)
	pcm16 = (clipped * 32767.0).astype(np.int16)
	buf = io.BytesIO()
	with wave.open(buf, "wb") as wf:
		wf.setnchannels(1)
		wf.setsampwidth(2)
		wf.setframerate(sample_rate)
		wf.writeframes(pcm16.tobytes())
	return buf.getvalue()


def _synthesize_one(text: str, voice: str, speed: float, lang: str) -> bytes:
	assert _kokoro is not None
	with _lock:
		samples, sample_rate = _kokoro.create(text, voice=voice, speed=speed, lang=lang)
	return _samples_to_wav_bytes(samples, sample_rate)


class Handler(BaseHTTPRequestHandler):
	server_version = "KokoroTtsServer/1.0"

	# 只接受指向本機的 Host 標頭。伺服器綁在 127.0.0.1，這擋得住外部連線，
	# 但擋不住 DNS rebinding：惡意網頁可以把自己的網域解析到 127.0.0.1，
	# 再從瀏覽器對這個埠發請求。那種請求的 Host 是攻擊者的網域，據此就能擋掉。
	ALLOWED_HOSTS = frozenset({"127.0.0.1", "localhost", "[::1]"})

	def log_message(self, fmt: str, *args) -> None:  # 安靜一點，避免洗版 stdout
		pass

	def _host_is_local(self) -> bool:
		host = self.headers.get("Host", "")
		if not host:
			return True  # HTTP/1.0 可以不帶 Host，那不會是瀏覽器發的
		if host.startswith("["):  # IPv6 字面值，例如 [::1]:52341
			name = host.split("]", 1)[0] + "]"
		else:
			name = host.rsplit(":", 1)[0] if ":" in host else host
		return name in self.ALLOWED_HOSTS

	def _reject_remote_host(self) -> bool:
		"""不是本機的 Host 就回 403，並回報 True 讓呼叫端直接結束。"""
		if self._host_is_local():
			return False
		self._send_error_json(403, "forbidden")
		return True

	def _read_json(self) -> dict:
		length = int(self.headers.get("Content-Length", "0"))
		raw = self.rfile.read(length) if length > 0 else b"{}"
		return json.loads(raw.decode("utf-8") or "{}")

	def _send_bytes(self, status: int, content_type: str, payload: bytes) -> None:
		self.send_response(status)
		self.send_header("Content-Type", content_type)
		self.send_header("Content-Length", str(len(payload)))
		self.end_headers()
		self.wfile.write(payload)

	def _send_error_json(self, status: int, message: str) -> None:
		self._send_bytes(status, "application/json", json.dumps({"error": message}).encode("utf-8"))

	def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler 介面命名)
		if self._reject_remote_host():
			return
		if self.path == "/health":
			self._send_bytes(200, "text/plain", b"ok")
			return
		self._send_error_json(404, "not found")

	def do_POST(self) -> None:  # noqa: N802
		if self._reject_remote_host():
			return
		try:
			if self.path == "/synthesize":
				body = self._read_json()
				text = str(body.get("text", "")).strip()
				if not text:
					self._send_error_json(400, "text 不可為空")
					return
				voice = str(body.get("voice", "af_heart"))
				speed = float(body.get("speed", 1.0))
				lang = str(body.get("lang", "en-us"))
				wav_bytes = _synthesize_one(text, voice, speed, lang)
				self._send_bytes(200, "audio/wav", wav_bytes)
				return

			if self.path == "/synthesize_batch":
				body = self._read_json()
				items = body.get("items", [])
				wavs: list[str] = []
				for item in items:
					text = str(item.get("text", "")).strip()
					voice = str(item.get("voice", "af_heart"))
					speed = float(item.get("speed", 1.0))
					lang = str(item.get("lang", "en-us"))
					if not text:
						wavs.append("")
						continue
					wav_bytes = _synthesize_one(text, voice, speed, lang)
					wavs.append(base64.b64encode(wav_bytes).decode("ascii"))
				payload = json.dumps({"wavs": wavs}).encode("utf-8")
				self._send_bytes(200, "application/json", payload)
				return

			if self.path == "/shutdown":
				self._send_bytes(200, "text/plain", b"ok")
				_shutdown_event.set()
				return

			self._send_error_json(404, "not found")
		except Exception as exc:  # 讓呼叫端拿得到具體錯誤訊息，而不是連線中斷
			self._send_error_json(500, f"{type(exc).__name__}: {exc}")


def main() -> int:
	parser = argparse.ArgumentParser(description="Kokoro TTS 本地背景伺服器")
	parser.add_argument("--model", required=True, help="kokoro-v1.0.onnx 路徑")
	parser.add_argument("--voices", required=True, help="voices-v1.0.bin 路徑")
	parser.add_argument("--host", default="127.0.0.1")
	parser.add_argument(
		"--port", type=int, default=0,
		help="監聽埠。0（預設）＝交給作業系統配發一個保證空閒的埠，"
		     "配到哪一個請搭配 --port-file 讀回去。指定非零值＝釘住那個埠（手動測試用）。",
	)
	parser.add_argument(
		"--port-file", default="",
		help="綁定成功後，把實際使用的埠號寫進這個檔案（純文字，只有數字）。"
		     "呼叫端無法讀我們的 stdout 時（例如用 Godot 的 OS.create_process 拉起來），"
		     "這是唯一拿得到埠號的方法。寫入是先寫暫存檔再 rename，"
		     "所以呼叫端不會讀到寫到一半的內容。",
	)
	args = parser.parse_args()

	global _kokoro
	print(f"[kokoro_server] 載入模型：{args.model}", flush=True)
	_kokoro = Kokoro(args.model, args.voices)
	print("[kokoro_server] 模型載入完成，開始服務", flush=True)

	httpd = ThreadingHTTPServer((args.host, args.port), Handler)
	# args.port 是 0 時，實際埠號由作業系統決定，只有綁完才知道。
	# 一律以 socket 回報的為準，不要回頭用 args.port——那會在 0 的情況下印出 0。
	bound_port = httpd.server_address[1]

	# 綁定成功才寫埠號檔：這個檔案的存在本身就是「已經可以連了」的信號，
	# 呼叫端靠它從「等待啟動」轉成「開始探健康檢查」。
	# 先寫暫存檔再 rename——rename 在同一個檔案系統內是原子操作，
	# 呼叫端因此不可能讀到寫到一半的數字（讀到 "87" 而不是 "8765" 會連到別的地方去）。
	if args.port_file:
		port_path = pathlib.Path(args.port_file)
		port_path.parent.mkdir(parents=True, exist_ok=True)
		tmp_path = port_path.with_suffix(port_path.suffix + ".tmp")
		tmp_path.write_text(str(bound_port), encoding="utf-8")
		os.replace(tmp_path, port_path)
		print(f"[kokoro_server] 埠號已寫入 {port_path}", flush=True)

	def watch_shutdown() -> None:
		_shutdown_event.wait()
		httpd.shutdown()

	threading.Thread(target=watch_shutdown, daemon=True).start()
	print(f"[kokoro_server] 監聽 http://{args.host}:{bound_port}", flush=True)
	httpd.serve_forever()
	print("[kokoro_server] 已關閉", flush=True)
	return 0


if __name__ == "__main__":
	sys.exit(main())
