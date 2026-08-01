# 打包 Kokoro TTS 背景伺服器成獨立執行檔 TTS_Server.exe。
# 需要 Windows 環境（PyInstaller 產出的是原生執行檔，不能跨平台交叉編譯），
# 而且會從 PyPI 下載幾百 MB 的 wheel（onnxruntime 等），請在網路順暢時跑。
#
# 用法（在本檔所在的資料夾開 PowerShell）：
#   powershell -ExecutionPolicy Bypass -File build.ps1
#
# 只想在「有東西改過」的時候才重建，就加 -IfStale。沒改過會直接結束，不做任何事：
#   powershell -ExecutionPolicy Bypass -File build.ps1 -IfStale
#
# Python 不是全域安裝、或 "python" 指到 Microsoft Store 的殼（沒裝真正的 Python）時，
# 直接指定完整路徑：
#   powershell -ExecutionPolicy Bypass -File build.ps1 -Python "C:\Python312\python.exe"
#
# kokoro-onnx 目前只支援 Python 3.10–3.13（3.14 太新，相依套件還沒出對應 wheel）。
# 本腳本會自己去找一支版本在範圍內的 Python（py -0p 的清單、build_env\pyvenv.cfg、
# 官方安裝程式的預設落點、PATH），所以預設 python/py 是 3.14 也不必手動指定。
# 真的要指定的話：
#   powershell -ExecutionPolicy Bypass -File build.ps1 -PyVersion "-3.12"
# 想看電腦上有哪些版本可選，在 PowerShell 打 `py -0` 或 `py --list`。
#
# 完成後 TTS_Server.exe（連同相依 DLL／資料檔）會在：
#   dist\TTS_Server\TTS_Server.exe
#
# 這個資料夾要當成「一整包」看待——別只複製 .exe 出去，espeak-ng 的資料檔／DLL
# 都在同一層，缺了會啟動失敗。

param(
	[string]$Python = "",
	[string]$PyVersion = "",   # 例如 "-3.12"，透過 py launcher 指定版本；跟 -Python 二選一
	[switch]$IfStale           # 只有在輸入檔改過時才重建，沒改就直接結束
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$venv = Join-Path $root "build_env"

# ── 過期判斷 ────────────────────────────────────────────────────────────────
# 建完會把三個輸入檔的 SHA-256 記在 dist\TTS_Server.build-stamp。下次帶 -IfStale 跑，
# 內容一樣就跳過整個建置。
#
# 為什麼要這個：改了 server.py 卻忘記重建，症狀是舊 exe 不認得新參數，
# 而它多半會表現成「啟動起來了，但功能靜默失效」，比直接爆掉難查得多。
# 讓打包流程自動判斷，就不必靠人記得。
#
# 三個輸入檔的選法：server.py 是程式本體；requirements.txt 決定裝哪些套件；
# build.ps1 自己也算，因為 PyInstaller 的參數（--collect-all 那些）寫在這裡面，
# 改了會影響產物內容。TTS_Server.spec 不算，PyInstaller 走 CLI 參數時會覆寫它。
$StampFile = Join-Path $root "dist\TTS_Server.build-stamp"
$ExeFile = Join-Path $root "dist\TTS_Server\TTS_Server.exe"

function Get-InputStamp {
	$parts = @()
	foreach ($f in @("server.py", "requirements.txt", "build.ps1")) {
		$path = Join-Path $root $f
		if (-not (Test-Path $path)) { return $null }
		$parts += "{0}  {1}" -f (Get-FileHash $path -Algorithm SHA256).Hash, $f
	}
	return ($parts -join "`n")
}

$CurrentStamp = Get-InputStamp

if ($IfStale) {
	if (-not (Test-Path $ExeFile)) {
		Write-Host "還沒建過 TTS_Server.exe，開始建置。" -ForegroundColor Yellow
	}
	elseif ($null -eq $CurrentStamp) {
		Write-Host "算不出輸入檔的雜湊（有檔案不見了？），保險起見重建。" -ForegroundColor Yellow
	}
	elseif ((Test-Path $StampFile) -and ((Get-Content $StampFile -Raw).Trim() -eq $CurrentStamp.Trim())) {
		Write-Host "TTS_Server.exe 是最新的（server.py／requirements.txt／build.ps1 都沒動過），跳過建置。" -ForegroundColor Green
		exit 0
	}
	else {
		Write-Host "輸入檔改過了，重新建置 TTS_Server.exe。" -ForegroundColor Yellow
	}
}

function Assert-LastExitOk {
	param([string]$Step)
	if ($LASTEXITCODE -ne 0) {
		throw "$Step 失敗（exit code $LASTEXITCODE），往上看訊息找原因。"
	}
}

# 找 Python：用 Get-Command 解析路徑，不直接執行 python --version 來判斷有沒有裝（Windows 內建的 'python' 常常是 Microsoft Store 的殼，執行會跳出 Store 頁面而不是
# 真的跑 Python，靠「有沒有輸出版本號」來判斷並不可靠）。
#
# 重點是「找到一支版本在範圍內的 Python」，不是「找到一支 Python」。
# py launcher 沒指定版本時給的是**最新**那支——機器上裝了 3.14 之後，「py 找得到」
# 就不等於「這支能用」，2026-08-02 打包就是卡在這裡（pip 找不到 kokoro-onnx 的 wheel）。
# 找的順序：
#   1. -Python / -PyVersion 明講的最優先，講錯就當場失敗（不默默換一支）
#   2. build_env\pyvenv.cfg 記著上次建環境用的那支（沿用＝不會無聲換掉工具鏈）
#   3. py -0p 列出所有註冊過的版本，挑範圍內最新的
#   4. 官方安裝程式的預設落點 %LOCALAPPDATA%\Programs\Python\Python3XX 等
#   5. PATH 上的 python / python3（最後才試，最容易撞到 Store 殼）
$MinMinor = 10
$MaxMinor = 13

function Get-PyText {
	param([string]$Exe, [string[]]$Prefix = @())
	if ($Exe -eq "") { return "" }
	try { return ((& $Exe @Prefix --version 2>&1 | Out-String).Trim()) } catch { return "" }
}

function Get-PyMinor {
	# 回傳次版號（3.12 → 12）；不是 Python 3.x 或問不出來就回 -1
	param([string]$Exe, [string[]]$Prefix = @())
	$m = [regex]::Match((Get-PyText $Exe $Prefix), '(\d+)\.(\d+)')
	if (-not $m.Success) { return -1 }
	if ([int]$m.Groups[1].Value -ne 3) { return -1 }
	return [int]$m.Groups[2].Value
}

function Get-PyLauncherList {
	# py -0p 的輸出格式跨 launcher 版本不同，兩種都吃：
	#   -V:3.12 *        C:\...\python.exe     （3.11 之後）
	#   -3.12-64         C:\...\python.exe     （較舊）
	# 有些舊版不印路徑，那就留空，改用 `py -3.12` 這種版本旗標去呼叫。
	if ($null -eq (Get-Command "py" -ErrorAction SilentlyContinue)) { return @() }
	$lines = @()
	try { $lines = & py -0p 2>&1 } catch { return @() }
	$found = @()
	foreach ($line in $lines) {
		$m = [regex]::Match([string]$line, '^\s*-(?:V:)?(\d+)\.(\d+)(?:-(?:32|64|arm64))?\s*\*?\s*(.*)$')
		if (-not $m.Success) { continue }
		if ([int]$m.Groups[1].Value -ne 3) { continue }
		$found += [pscustomobject]@{
			Minor = [int]$m.Groups[2].Value
			Path  = $m.Groups[3].Value.Trim().Trim('"')
		}
	}
	return $found
}

Write-Host "== 0/5 尋找 Python ==" -ForegroundColor Cyan
$PyExe = ""
$PyPrefix = @()   # 有些呼叫需要在 -m 前面多塞版本旗標（py -3.12 -m venv ...），其餘指令都用這個前綴
$PySpecified = $false

if ($PyVersion -ne "") {
	$cmd = Get-Command "py" -ErrorAction SilentlyContinue
	if ($null -eq $cmd) {
		Write-Host "指定了 -PyVersion 但找不到 py launcher（py.exe）。" -ForegroundColor Red
		exit 1
	}
	$PyExe = $cmd.Source
	$PyPrefix = @($PyVersion)
	$PySpecified = $true
}
elseif ($Python -ne "") {
	if (-not (Test-Path $Python)) {
		Write-Host "指定的 Python 不存在：$Python" -ForegroundColor Red
		exit 1
	}
	$PyExe = $Python
	$PySpecified = $true
}
else {
	# 2. 上次建 build_env 用的那支。排在最前面是刻意的：它是這個專案實際建置過的版本，
	# requirements.txt 的相依解析也是對著它跑的。沿用它就不會因為裝了新的 Python
	# 而無聲換掉整套工具鏈（要換版本就把 build_env 整個刪掉，下一次自然會重挑）。
	$cfg = Join-Path $venv "pyvenv.cfg"
	if (Test-Path $cfg) {
		$homeLine = (Get-Content $cfg | Where-Object { $_ -match "^home\s*=" } | Select-Object -First 1)
		if ($null -ne $homeLine) {
			$cand = (($homeLine -split "=", 2)[1].Trim()) + "\python.exe"
			if (Test-Path $cand) {
				$minor = Get-PyMinor $cand
				if ($minor -ge $MinMinor -and $minor -le $MaxMinor) { $PyExe = $cand }
			}
		}
	}
	# 3. py launcher 註冊過的版本，挑範圍內最新的
	if ($PyExe -eq "") {
		foreach ($c in (Get-PyLauncherList | Where-Object { $_.Minor -ge $MinMinor -and $_.Minor -le $MaxMinor } | Sort-Object Minor -Descending)) {
			if ($c.Path -ne "" -and (Test-Path $c.Path)) { $PyExe = $c.Path; break }
			$pyCmd = Get-Command "py" -ErrorAction SilentlyContinue
			if ($null -ne $pyCmd) { $PyExe = $pyCmd.Source; $PyPrefix = @("-3.$($c.Minor)"); break }
		}
	}
	# 4. 官方安裝程式的預設落點
	if ($PyExe -eq "") {
		foreach ($minor in ($MaxMinor..$MinMinor)) {
			foreach ($base in @("$env:LOCALAPPDATA\Programs\Python\Python3$minor",
			                    "$env:ProgramFiles\Python3$minor",
			                    "C:\Python3$minor")) {
				$cand = "$base\python.exe"   # 不用 Join-Path：它會驗 PSDrive，探路階段不需要
				if (Test-Path $cand) { $PyExe = $cand; break }
			}
			if ($PyExe -ne "") { break }
		}
	}
	# 5. PATH 上的 python / python3
	if ($PyExe -eq "") {
		foreach ($cand in @("python", "python3")) {
			$cmd = Get-Command $cand -ErrorAction SilentlyContinue
			if ($null -ne $cmd) {
				$minor = Get-PyMinor $cmd.Source
				if ($minor -ge $MinMinor -and $minor -le $MaxMinor) { $PyExe = $cmd.Source; break }
			}
		}
	}
}

if ($PyExe -eq "") {
	Write-Host "找不到版本在 3.10–3.13 的 Python（kokoro-onnx 只支援這個範圍）。" -ForegroundColor Red
	Write-Host "py launcher 目前註冊的版本：" -ForegroundColor Yellow
	$listed = @(Get-PyLauncherList)
	if ($listed.Count -gt 0) {
		foreach ($c in $listed) { Write-Host ("  3.{0}  {1}" -f $c.Minor, $c.Path) -ForegroundColor Yellow }
	}
	else {
		Write-Host "  （問不到，可能沒裝 py launcher）" -ForegroundColor Yellow
	}
	Write-Host "去 https://www.python.org/downloads/ 裝一份 3.12 或 3.13（安裝時勾選 'py launcher'，" -ForegroundColor Yellow
	Write-Host "不用設成系統預設，也不會影響你原本的 3.14）。裝好之後重跑本檔就會自動找到。" -ForegroundColor Yellow
	Write-Host "已經有一支但沒被找到的話，直接指定完整路徑：" -ForegroundColor Yellow
	Write-Host "  powershell -ExecutionPolicy Bypass -File build.ps1 -Python `"C:\完整路徑\python.exe`"" -ForegroundColor Yellow
	exit 1
}

$PyVersionText = Get-PyText $PyExe $PyPrefix
if ($PyPrefix.Count -gt 0) { Write-Host "  使用 $PyExe $PyPrefix（$PyVersionText）" }
else { Write-Host "  使用 $PyExe（$PyVersionText）" }

# 最後再驗一次版本。自動挑出來的一定在範圍內，所以這裡實際上是在擋
# -Python／-PyVersion 指錯的情況——指定了就照做、照做之前先講清楚不能用。
$PyVersionMatch = [regex]::Match($PyVersionText, '(\d+)\.(\d+)')
if ($PyVersionMatch.Success) {
	$verMajor = [int]$PyVersionMatch.Groups[1].Value
	$verMinor = [int]$PyVersionMatch.Groups[2].Value
	if (-not ($verMajor -eq 3 -and $verMinor -ge $MinMinor -and $verMinor -le $MaxMinor)) {
		Write-Host "這個 Python（$PyVersionText）版本不在 kokoro-onnx 支援範圍（3.10–3.13）內。" -ForegroundColor Red
		if ($PySpecified) {
			Write-Host "這支是你用 -Python／-PyVersion 指定的。把那個參數拿掉，本腳本會自己去找" -ForegroundColor Yellow
			Write-Host "一支範圍內的版本（build_env／py -0p 清單／官方安裝路徑／PATH）。" -ForegroundColor Yellow
		}
		Write-Host "看看電腦上還有哪些版本可用：" -ForegroundColor Yellow
		Write-Host "  py -0p" -ForegroundColor Yellow
		Write-Host "如果都沒有 3.10–3.13，去 https://www.python.org/downloads/ 裝一份 3.12 或 3.13" -ForegroundColor Yellow
		Write-Host "（安裝時勾選 'py launcher'，不用設成系統預設，也不會影響你原本的 3.14）。" -ForegroundColor Yellow
		exit 1
	}
}

Write-Host "== 1/5 建立專用虛擬環境 $venv ==" -ForegroundColor Cyan
$venvPython = Join-Path $venv "Scripts\python.exe"
$needFreshVenv = $true
if (Test-Path $venvPython) {
	$existingVer = Get-PyText $venvPython
	if ($existingVer -eq $PyVersionText) {
		Write-Host "  已存在且版本相符（$existingVer），沿用 $venvPython"
		$needFreshVenv = $false
	}
	else {
		Write-Host "  已存在但版本不符（現有 $existingVer，這次要 $PyVersionText），重建虛擬環境" -ForegroundColor Yellow
		Remove-Item -Recurse -Force $venv
	}
}
if ($needFreshVenv) {
	& $PyExe @PyPrefix -m venv $venv
	if (-not (Test-Path $venvPython)) {
		Write-Host "虛擬環境沒有建成功，找不到：$venvPython" -ForegroundColor Red
		Write-Host "可以手動測試 `"$PyExe`" $PyPrefix -m venv 是否正常執行，看看有沒有錯誤訊息被吃掉。" -ForegroundColor Yellow
		exit 1
	}
}

Write-Host "== 2/5 安裝相依套件（含 PyInstaller） ==" -ForegroundColor Cyan
& $venvPython -m pip install --upgrade pip
Assert-LastExitOk "pip install --upgrade pip"
& $venvPython -m pip install -r (Join-Path $root "requirements.txt")
Assert-LastExitOk "pip install -r requirements.txt"

Write-Host "== 3/5 定位 espeakng-loader 的資料／函式庫路徑（打包必須一起收） ==" -ForegroundColor Cyan
$espeakDataPath = & $venvPython -c "import espeakng_loader; print(espeakng_loader.get_data_path())"
$espeakLibPath  = & $venvPython -c "import espeakng_loader; print(espeakng_loader.get_library_path())"
Write-Host "  data path : $espeakDataPath"
Write-Host "  lib  path : $espeakLibPath"

# 排除項目有兩類，理由不同。
#
# ssl / _ssl / _hashlib：CPython 3.10 的 Windows 建置帶的是 OpenSSL 1.1.1，
# 而 1.1.1 用的是 OpenSSL License 加 SSLeay License 的雙授權，其中含一條廣告條款，
# 與 GPL 不相容。這支伺服器是 GPL-3.0（因為連結了 espeak-ng），兩者放在一起會出問題，
# 而我們沒有立場替 espeak-ng 與 phonemizer-fork 加 OpenSSL 例外條款。
# 這支伺服器只在 127.0.0.1 上跑明文 HTTP，本來就不需要 TLS；拿掉 _hashlib 之後
# hashlib 會退回 CPython 內建的實作，功能不受影響。順帶也甩掉一個 2023-09-11
# 就結束支援的加密函式庫。相依套件裡沒有 requests／urllib3／certifi，沒有東西會用到 TLS。
#
# setuptools / pkg_resources：建置期相依，執行期用不到，收進去只是讓包變大，
# 而且 65.5.0 有 CVE-2022-40897。
# 重建後如果 TTS_Server 啟動失敗，先把這兩行拿掉再試（有些套件仍靠 pkg_resources
# 註冊 entry point）；ssl 那三行不要動。
#
# --noupx：UPX 壓縮是防毒誤判的頭號觸發條件，出貨用的執行檔不要壓。
Write-Host "== 4/5 執行 PyInstaller（--onedir，含 collect-all 確保 espeak-ng／phonemizer 相依資料檔進包） ==" -ForegroundColor Cyan
Push-Location $root
& $venvPython -m PyInstaller `
	--name TTS_Server `
	--onedir `
	--noconfirm `
	--clean `
	--collect-all espeakng_loader `
	--collect-all phonemizer_fork `
	--collect-all language_tags `
	--collect-all segments `
	--collect-all csvw `
	--collect-data kokoro_onnx `
	--exclude-module ssl `
	--exclude-module _ssl `
	--exclude-module _hashlib `
	--exclude-module setuptools `
	--exclude-module pkg_resources `
	--noupx `
	server.py
Assert-LastExitOk "PyInstaller"
Pop-Location

# 記下這次用的輸入，下次 -IfStale 才知道有沒有改過。
# 一定要放在 PyInstaller 成功之後，失敗的建置不該留下「已是最新」的假象。
if ($null -ne $CurrentStamp) {
	Set-Content -Path $StampFile -Value $CurrentStamp -Encoding UTF8
}

Write-Host "== 5/5 完成 ==" -ForegroundColor Green
Write-Host "輸出位置：$root\dist\TTS_Server\TTS_Server.exe"
Write-Host ""
Write-Host "接下來："
Write-Host "  1) 到 https://github.com/thewh1teagle/kokoro-onnx/releases 下載"
Write-Host "     kokoro-v1.0.onnx 與 voices-v1.0.bin（放哪都行，下一步用得到路徑）"
Write-Host "  2) 手動測試： dist\TTS_Server\TTS_Server.exe --model <路徑>\kokoro-v1.0.onnx --voices <路徑>\voices-v1.0.bin --port 8765"
Write-Host "  3) 另開一個終端機： curl http://127.0.0.1:8765/health  應該回 ok"
