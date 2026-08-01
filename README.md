# Listening Post TTS Server

A local text-to-speech server. Text in, WAV bytes out. It binds to `127.0.0.1` only and
accepts no external connections.

This is the speech component of *Listening Post*, a typing game for English learners. It
is published here to meet the source distribution requirement of the GNU General Public
License; see [Why this repository exists](#why-this-repository-exists).

**License: GPL-3.0-or-later.** See [LICENSE](LICENSE).

---

## Why this repository exists

The game itself is proprietary, but its speech pipeline has an unavoidable GPL dependency.

[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), the synthesis model, is
Apache-2.0 licensed, but it takes phonemes rather than graphemes as input. The only
English grapheme-to-phoneme frontend that is production-viable today is
[espeak-ng](https://github.com/espeak-ng/espeak-ng), which is GPL-3.0-or-later.

The approach is to keep every GPL-licensed component inside this separate executable:

```
Game binary (proprietary)  ──HTTP 127.0.0.1──▶  TTS_Server (GPL-3.0)  ──dlopen──▶  espeak-ng (GPL-3.0)
              No linkage, no shared address space; two independent OS processes.
```

This program links against espeak-ng within a single process, so it is itself licensed
under GPL-3.0-or-later, and this repository provides the corresponding source required by
GPLv3 §6.

The game binary talks to it over a local HTTP socket and nothing else. It does not import,
link against, or share an address space with any GPL-licensed code. Shipping both in one
installer is mere aggregation under GPLv3 §5.

> This section covers the engineering and licensing rationale. It is not legal advice.

## Repository contents

| File | Purpose |
|---|---|
| `server.py` | The server |
| `requirements.txt` | Python dependencies, all version-pinned |
| `TTS_Server.spec` | PyInstaller build specification |
| `build.ps1` | Windows build script |

## Requirements

Python 3.10 through 3.13. Python 3.14 is not yet supported by kokoro-onnx.

Model files are not kept in version control. Download `kokoro-v1.0.onnx` and
`voices-v1.0.bin` from the
[kokoro-onnx releases page](https://github.com/thewh1teagle/kokoro-onnx/releases).

## Building

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1

# Select a specific interpreter through the py launcher:
powershell -ExecutionPolicy Bypass -File build.ps1 -PyVersion "-3.12"

# Rebuild only when server.py, requirements.txt, or build.ps1 has changed:
powershell -ExecutionPolicy Bypass -File build.ps1 -IfStale
```

The output is `dist/TTS_Server/`. Treat that directory as a single unit: the espeak-ng
library and its data files sit alongside the executable, and copying `TTS_Server.exe` on
its own will fail at startup.

## Running

```
TTS_Server.exe --model kokoro-v1.0.onnx --voices voices-v1.0.bin --port 8765
curl http://127.0.0.1:8765/health
```

Model loading takes roughly fifteen seconds, and `/health` does not return `ok` until it
finishes. Synthesis requests are serialized through a global lock, because ONNX Runtime
sessions are not safe for concurrent use.

### Command-line options

| Option | Default | Description |
|---|---|---|
| `--model` | required | Path to `kokoro-v1.0.onnx` |
| `--voices` | required | Path to `voices-v1.0.bin` |
| `--host` | `127.0.0.1` | Bind address |
| `--port` | `0` | Listening port; `0` lets the operating system assign one |
| `--port-file` | none | File to receive the bound port number |

### Port assignment

`--port` defaults to `0`, which asks the operating system to assign a free port.

A caller cannot know which ports are already taken on an end user's machine, and a
hardcoded port that collides looks, from the caller's side, like a service that failed to
start — which is expensive to diagnose. Passing `0` moves port selection into the same
syscall as the bind, so there is no window between checking a port and claiming it.

The cost is that only this process knows which port it got. If the caller can read this
process's standard output, the port is printed there. If it cannot — for example when the
process is launched through an API such as `CreateProcess` with no pipe attached — pass
`--port-file` and the port number is written to that path once the bind succeeds:

```
TTS_Server.exe --model ... --voices ... --port 0 --port-file /tmp/tts_port.txt
```

The file is written under a temporary name and then renamed into place, so a reader never
sees a partial value.

Callers should treat the appearance of that file, containing a valid port number, as the
signal that the server is ready for connections, and should delete any existing file
before each launch so they do not read a port left over from a previous run.

## HTTP API

All endpoints are served on the bound address only.

### `GET /health`

Returns `200` with the body `ok` once the model is loaded. Any other response, including a
connection failure, means the server is not ready.

### `POST /synthesize`

```json
{ "text": "hello", "voice": "af_heart", "speed": 1.0, "lang": "en-us" }
```

Returns `200` with `Content-Type: audio/wav` and the WAV file as the body.
An empty `text` returns `400`.

### `POST /synthesize_batch`

```json
{ "items": [ { "text": "hello", "voice": "af_heart", "speed": 1.0, "lang": "en-us" } ] }
```

Returns `200` with `Content-Type: application/json`:

```json
{ "wavs": ["<base64-encoded WAV>", "..."] }
```

Results come back in request order. An item with empty `text` yields an empty string in
that position instead of an error, so one bad item does not discard the whole batch.

### `POST /shutdown`

Returns `200` and stops the server.

### Errors

Failures return a JSON body of the form `{"error": "<message>"}` with status `400`, `404`,
or `500`. Exceptions raised during synthesis are reported as `500` with the exception type
and message, rather than dropping the connection.

---

# 中文說明

《聽哨 Listening Post》使用的本地語音合成伺服器。輸入文字，輸出 WAV 位元組，
只監聽 `127.0.0.1`，不接受任何外部連線。

這個 repo 的用途是履行 GNU General Public License 的原始碼交付義務。

**授權：GPL-3.0-or-later**，全文見 [LICENSE](LICENSE)。

## 這個 repo 為什麼獨立存在

遊戲本體是專屬軟體，但它的語音管線有一項無法迴避的 GPL 相依。

合成模型 [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) 本身是 Apache-2.0 授權，
但它的輸入是音素而不是字母；目前唯一達到實用水準的英文 grapheme-to-phoneme 前端是
[espeak-ng](https://github.com/espeak-ng/espeak-ng)，那是 GPL-3.0-or-later。

作法是把所有 GPL 元件都關進這支獨立的執行檔：

```
遊戲本體（專屬）  ──HTTP 127.0.0.1──▶  TTS_Server（GPL-3.0）  ──dlopen──▶  espeak-ng（GPL-3.0）
            兩者不連結、不共用位址空間，是各自獨立的作業系統行程
```

這支程式在同一個行程內連結 espeak-ng，所以它本身也必須以 GPL-3.0-or-later 授權散布；
這個 repo 就是 GPLv3 §6 所要求的對應原始碼。

遊戲本體和它之間只有一條本機 HTTP socket，沒有任何連結關係。兩者放進同一個安裝包散布，
屬於 GPLv3 §5 所說的單純聚合（mere aggregation）。

> 這一節是工程與授權說明，不是法律意見。

## 建置需求

Python 3.10 到 3.13。kokoro-onnx 還不支援 3.14。

模型檔沒有納入版本控制，請到
[kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases)
下載 `kokoro-v1.0.onnx` 和 `voices-v1.0.bin`。

## 建置

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
powershell -ExecutionPolicy Bypass -File build.ps1 -PyVersion "-3.12"   # 指定直譯器版本
powershell -ExecutionPolicy Bypass -File build.ps1 -IfStale             # 輸入檔有改才重建
```

產物在 `dist/TTS_Server/`。這個目錄要當成一個整體看待：espeak-ng 的函式庫和資料檔
就放在執行檔同一層，只把 `TTS_Server.exe` 複製出去會啟動失敗。

## 執行

```
TTS_Server.exe --model kokoro-v1.0.onnx --voices voices-v1.0.bin --port 8765
curl http://127.0.0.1:8765/health
```

模型載入大約需要十五秒，完成之前 `/health` 不會回應 `ok`。合成請求以全域鎖序列化處理，
因為 ONNX Runtime 的 session 不支援併發存取。

### 命令列參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `--model` | 必填 | `kokoro-v1.0.onnx` 路徑 |
| `--voices` | 必填 | `voices-v1.0.bin` 路徑 |
| `--host` | `127.0.0.1` | 綁定位址 |
| `--port` | `0` | 監聽埠；`0` 表示交給作業系統配發 |
| `--port-file` | 無 | 把實際綁定的埠號寫進這個路徑 |

### 埠號配發

`--port` 預設是 `0`，也就是請作業系統配一個空閒的埠。

呼叫端無從得知使用者機器上哪些埠已經被占用，而寫死的埠一旦衝突，從呼叫端看起來就是
「服務啟動失敗」，診斷成本很高。指定 `0` 可以把埠的選擇和綁定合併在同一次系統呼叫裡，
中間沒有先檢查再綁定的競爭空隙。

代價是只有這個行程知道實際配到哪一個埠。如果呼叫端讀得到這個行程的標準輸出，埠號會
印在那裡；如果讀不到（例如經由 `CreateProcess` 一類的 API 啟動、沒有接管道），
請用 `--port-file` 指定路徑，綁定成功後埠號就會寫進那個檔案：

```
TTS_Server.exe --model ... --voices ... --port 0 --port-file /tmp/tts_port.txt
```

寫入的方式是先寫暫存檔再改名，所以讀取端不會拿到寫到一半的內容。

呼叫端應該把「這個檔案出現、而且內容是合法埠號」當成伺服器可以接受連線的信號，
並且在每次啟動前先刪掉舊檔案，避免讀到上一次執行留下的埠號。

## HTTP API

所有端點都只在綁定的位址上提供服務。

### `GET /health`

模型載入完成後回應 `200`，body 是 `ok`。其他任何回應，包括連線失敗，都表示還沒就緒。

### `POST /synthesize`

```json
{ "text": "hello", "voice": "af_heart", "speed": 1.0, "lang": "en-us" }
```

回應 `200`，`Content-Type: audio/wav`，body 是 WAV 檔內容。`text` 為空時回應 `400`。

### `POST /synthesize_batch`

```json
{ "items": [ { "text": "hello", "voice": "af_heart", "speed": 1.0, "lang": "en-us" } ] }
```

回應 `200`，`Content-Type: application/json`：

```json
{ "wavs": ["<base64 編碼的 WAV>", "..."] }
```

結果會依照請求的順序回傳。`text` 為空的項目回傳空字串而不是錯誤，
這樣單一項目出問題不會讓整批作廢。

### `POST /shutdown`

回應 `200` 並終止伺服器。

### 錯誤

失敗時回應 JSON `{"error": "<訊息>"}`，狀態碼是 `400`、`404` 或 `500`。
合成過程中拋出的例外會以 `500` 回報，內容包含例外型別和訊息，而不是直接中斷連線。
