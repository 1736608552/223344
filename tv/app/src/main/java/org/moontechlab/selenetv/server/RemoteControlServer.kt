package org.moontechlab.selenetv.server

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 遥控器 Web 服务器 (原生 Java ServerSocket 实现，零第三方库依赖，超轻量，100% 杜绝 Netty 崩溃与端口拒绝)
 */
object RemoteControlServer {
    private const val TAG = "RemoteControlServer"
    private val PREFERRED_PORTS = intArrayOf(8888, 8080, 9999, 18888, 28256)
    private const val FALLBACK_START_PORT = 8889
    private const val MAX_PORT_ATTEMPTS = 50

    private var serverSocket: ServerSocket? = null
    private var currentPort: Int = PREFERRED_PORTS[0]
    private val isRunning = AtomicBoolean(false)
    private var serverThread: Thread? = null
    private var workerExecutor = Executors.newCachedThreadPool()

    private var keyEventCallback: ((Int) -> Unit)? = null
    private var textInputCallback: ((String) -> Unit)? = null

    fun getPort(): Int = currentPort

    fun setKeyEventCallback(callback: (Int) -> Unit) {
        keyEventCallback = callback
    }

    fun setTextInputCallback(callback: (String) -> Unit) {
        textInputCallback = callback
    }

    /**
     * 清空遥控回调。MainActivity 在 onDestroy（非配置变更）时调用，
     * 否则本单例会一直持有已销毁的 Activity（回调 lambda 捕获了 Activity）造成泄漏。
     */
    fun clearCallbacks() {
        keyEventCallback = null
        textInputCallback = null
    }

    /**
     * 确保服务处于监听状态，若未运行则自动拉起启动 (自愈保活)
     */
    @Synchronized
    fun ensureRunning(): Boolean {
        if (isRunning.get() && serverSocket != null && !serverSocket!!.isClosed) {
            return true
        }
        return start()
    }

    @Synchronized
    fun start(): Boolean {
        if (isRunning.get() && serverSocket != null && !serverSocket!!.isClosed) {
            Log.d(TAG, "Server already running on port $currentPort")
            return true
        }

        stop()

        // 1. 优先尝试智能电视高兼容白名单端口列表 (8888, 8080, 9999, 18888, 28256)
        val candidatePorts = mutableListOf<Int>()
        for (p in PREFERRED_PORTS) candidatePorts.add(p)
        for (i in 0 until MAX_PORT_ATTEMPTS) {
            val p = FALLBACK_START_PORT + i
            if (!candidatePorts.contains(p)) candidatePorts.add(p)
        }

        for (port in candidatePorts) {
            try {
                val ss = ServerSocket()
                ss.reuseAddress = true
                ss.bind(java.net.InetSocketAddress(port), 50)
                serverSocket = ss
                currentPort = port
                isRunning.set(true)
                if (workerExecutor.isShutdown) {
                    workerExecutor = Executors.newCachedThreadPool()
                }

                serverThread = Thread({
                    Log.i(TAG, "Remote control server listening on 0.0.0.0:$port")
                    while (isRunning.get() && !ss.isClosed) {
                        try {
                            val clientSocket = ss.accept()
                            workerExecutor.execute {
                                handleClient(clientSocket)
                            }
                        } catch (e: Exception) {
                            if (!isRunning.get() || ss.isClosed) break
                            Log.w(TAG, "Error accepting client: ${e.message}")
                        }
                    }
                }, "RemoteControlServer-Listen").apply { isDaemon = true }
                serverThread?.start()
                return true
            } catch (e: Throwable) {
                Log.d(TAG, "Port $port unavailable: ${e.message}")
            }
        }
        Log.e(TAG, "Failed to bind any port from candidates")
        return false
    }

    @Synchronized
    fun stop() {
        isRunning.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        serverSocket = null
        try {
            serverThread?.interrupt()
        } catch (_: Exception) {}
        serverThread = null
        Log.i(TAG, "Remote control server stopped")
    }

    private fun handleClient(socket: Socket) {
        try {
            socket.soTimeout = 5000
            val input = socket.getInputStream()
            val reader = BufferedReader(InputStreamReader(input, Charsets.UTF_8))
            val output = socket.getOutputStream()

            val requestLine = reader.readLine() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return

            val method = parts[0].uppercase()
            val rawPath = parts[1]
            val path = rawPath.substringBefore("?").trim()

            var contentLength = 0
            while (true) {
                val headerLine = reader.readLine() ?: break
                if (headerLine.isEmpty()) break
                val colonIdx = headerLine.indexOf(':')
                if (colonIdx > 0) {
                    val key = headerLine.substring(0, colonIdx).trim().lowercase()
                    val value = headerLine.substring(colonIdx + 1).trim()
                    if (key == "content-length") {
                        contentLength = value.toIntOrNull() ?: 0
                    }
                }
            }

            var body = ""
            if (contentLength > 0 && contentLength < 65536) {
                val chars = CharArray(contentLength)
                var readTotal = 0
                while (readTotal < contentLength) {
                    val count = reader.read(chars, readTotal, contentLength - readTotal)
                    if (count < 0) break
                    readTotal += count
                }
                body = String(chars, 0, readTotal).trim()
            }

            when {
                method == "OPTIONS" -> {
                    sendResponse(output, "204 No Content", "text/plain", "")
                }
                method == "GET" && (path == "/" || path.isEmpty() || path == "/remote_control") -> {
                    sendResponse(output, "200 OK", "text/html; charset=utf-8", remoteControlHtml)
                }
                method == "GET" && path == "/api/ping" -> {
                    sendResponse(output, "200 OK", "application/json; charset=utf-8", """{"pong":true}""")
                }
                method == "POST" && path == "/api/key" -> {
                    val keyCode = body.toIntOrNull()
                    if (keyCode != null) {
                        Log.d(TAG, "Received key: $keyCode")
                        keyEventCallback?.invoke(keyCode)
                        sendResponse(output, "200 OK", "application/json; charset=utf-8", """{"success":true}""")
                    } else {
                        sendResponse(output, "400 Bad Request", "application/json; charset=utf-8", """{"error":"Invalid keyCode"}""")
                    }
                }
                method == "POST" && path == "/api/text" -> {
                    if (body.isNotEmpty()) {
                        Log.d(TAG, "Received text: $body")
                        textInputCallback?.invoke(body)
                        sendResponse(output, "200 OK", "application/json; charset=utf-8", """{"success":true}""")
                    } else {
                        sendResponse(output, "400 Bad Request", "application/json; charset=utf-8", """{"error":"Empty text"}""")
                    }
                }
                else -> {
                    sendResponse(output, "404 Not Found", "text/plain; charset=utf-8", "Not Found")
                }
            }
        } catch (_: Exception) {
        } finally {
            try {
                socket.close()
            } catch (_: Exception) {}
        }
    }

    private fun sendRedirect(output: OutputStream, location: String) {
        val header = "HTTP/1.1 302 Found\r\n" +
                "Location: $location\r\n" +
                "Content-Length: 0\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.US_ASCII))
        output.flush()
    }

    private fun sendResponse(output: OutputStream, status: String, contentType: String, content: String) {
        val bytes = content.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 $status\r\n" +
                "Content-Type: $contentType\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                "Access-Control-Allow-Headers: *\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.US_ASCII))
        if (bytes.isNotEmpty()) {
            output.write(bytes)
        }
        output.flush()
    }


    private val remoteControlHtml = """
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no, maximum-scale=1.0">
    <title>lunaTV Remote</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; -webkit-tap-highlight-color: transparent; user-select: none; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', sans-serif;
            background: #000;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 20px;
            color: #fff;
        }
        .remote-body {
            width: 100%;
            max-width: 240px;
            background: linear-gradient(180deg, 
                #5a5a5c 0%, 
                #4a4a4c 2%, 
                #3a3a3c 5%,
                #2c2c2e 50%,
                #252527 95%,
                #1c1c1e 100%);
            border-radius: 48px;
            padding: 30px 30px 48px;
            box-shadow: 
                0 70px 140px rgba(0,0,0,0.9),
                0 0 0 1px rgba(255,255,255,0.08),
                inset 0 1px 0 rgba(255,255,255,0.2),
                inset 0 -1px 0 rgba(0,0,0,0.3);
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 36px;
            position: relative;
        }
        .power-indicator {
            width: 10px; height: 10px;
            background: #34c759;
            border-radius: 50%;
            box-shadow: 0 0 12px rgba(52,199,89,0.8);
            position: absolute;
            top: 14px;
            left: 50%;
            transform: translateX(-50%);
        }
        .power-indicator.error { background: #ff3b30; box-shadow: 0 0 12px rgba(255,59,48,0.8); }
        .touchpad-ring {
            width: 180px; height: 180px;
            background: linear-gradient(180deg, #0a0a0a 0%, #151515 100%);
            border-radius: 50%;
            padding: 5px;
            box-shadow: 
                inset 0 4px 12px rgba(0,0,0,0.9),
                0 1px 0 rgba(255,255,255,0.1);
            margin-top: 18px;
        }
        .touchpad-inner {
            width: 100%; height: 100%;
            background: linear-gradient(180deg, #2d2d2f 0%, #1d1d1f 100%);
            border-radius: 50%;
            display: flex; align-items: center; justify-content: center;
            position: relative;
            box-shadow: inset 0 1px 0 rgba(255,255,255,0.08);
        }
        .dpad-container {
            width: 150px; height: 150px;
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            grid-template-rows: 1fr 1fr 1fr;
            position: relative;
        }
        .dpad-btn {
            background: transparent; border: none;
            display: flex; align-items: center; justify-content: center;
            cursor: pointer; transition: all 0.1s ease; border-radius: 50%;
            position: relative; z-index: 2;
        }
        .dpad-btn:active { background: rgba(255,255,255,0.1); }
        .dpad-btn svg { width: 26px; height: 26px; fill: rgba(255,255,255,0.4); transition: fill 0.1s ease; }
        .dpad-btn:active svg { fill: rgba(255,255,255,0.9); }
        .center-btn {
            grid-column: 2; grid-row: 2;
            width: 60px; height: 60px;
            background: linear-gradient(180deg, #404042 0%, #303032 100%);
            border: none; border-radius: 50%; cursor: pointer;
            box-shadow: 
                0 4px 12px rgba(0,0,0,0.5),
                inset 0 1px 0 rgba(255,255,255,0.15);
            transition: all 0.1s ease;
            justify-self: center; align-self: center;
            position: relative; z-index: 3;
        }
        .center-btn:active { 
            transform: scale(0.95); 
            background: linear-gradient(180deg, #505052 0%, #404042 100%);
        }
        .up-btn { grid-column: 2; grid-row: 1; }
        .down-btn { grid-column: 2; grid-row: 3; }
        .left-btn { grid-column: 1; grid-row: 2; }
        .right-btn { grid-column: 3; grid-row: 2; }
        .btn-row { 
            display: flex; 
            gap: 30px; 
            width: 100%;
            justify-content: center;
        }
        .action-btn {
            width: 66px; height: 66px;
            background: linear-gradient(180deg, #0c0c0c 0%, #181818 100%);
            border: none; border-radius: 50%; cursor: pointer;
            display: flex; align-items: center; justify-content: center;
            box-shadow: 
                inset 0 4px 10px rgba(0,0,0,0.7),
                0 1px 0 rgba(255,255,255,0.08);
            transition: all 0.1s ease;
        }
        .action-btn:active { 
            background: linear-gradient(180deg, #1a1a1a 0%, #252525 100%);
        }
        .action-btn svg { width: 26px; height: 26px; fill: rgba(255,255,255,0.5); transition: fill 0.1s ease; }
        .action-btn:active svg { fill: rgba(255,255,255,0.9); }
        .brand-text {
            font-size: 13px;
            font-weight: 600;
            color: rgba(255,255,255,0.2);
            letter-spacing: 4px;
            text-transform: uppercase;
            margin-top: 275px;
        }
        .modal-overlay {
            position: fixed; top: 0; left: 0; right: 0; bottom: 0;
            display: flex;
            background: rgba(0,0,0,0); 
            -webkit-backdrop-filter: blur(0px) saturate(100%);
            backdrop-filter: blur(0px) saturate(100%);
            align-items: flex-end; justify-content: center; z-index: 100;
            padding-bottom: env(safe-area-inset-bottom, 20px);
            visibility: hidden;
            pointer-events: none;
            transition: background 0.3s ease, backdrop-filter 0.3s ease, -webkit-backdrop-filter 0.3s ease, visibility 0s 0.3s;
        }
        .modal-overlay.show {
            visibility: visible;
            pointer-events: auto;
            background: rgba(0,0,0,0.6);
            -webkit-backdrop-filter: blur(40px) saturate(180%);
            backdrop-filter: blur(40px) saturate(180%);
            transition: background 0.3s ease, backdrop-filter 0.3s ease, -webkit-backdrop-filter 0.3s ease, visibility 0s 0s;
        }
        .modal {
            width: 100%; max-width: 400px;
            background: linear-gradient(180deg, rgba(58,58,60,0.98) 0%, rgba(44,44,46,0.98) 100%);
            border-radius: 14px 14px 0 0;
            overflow: hidden;
            box-shadow: 0 -10px 60px rgba(0,0,0,0.5);
            transform: translateY(100%);
            opacity: 0;
            transition: transform 0.3s cubic-bezier(0.32, 0.72, 0, 1), opacity 0.25s ease;
        }
        .modal-overlay.show .modal { transform: translateY(0); opacity: 1; }
        .modal-header {
            display: flex; align-items: center; justify-content: space-between;
            padding: 14px 16px;
            border-bottom: 1px solid rgba(255,255,255,0.08);
        }
        .modal-header-btn {
            background: none; border: none;
            font-size: 17px; font-weight: 400;
            color: #0a84ff; cursor: pointer;
            padding: 0; min-width: 60px;
        }
        .modal-header-btn:active { opacity: 0.6; }
        .modal-header-btn.send { font-weight: 600; text-align: right; }
        .modal-header-btn.cancel { text-align: left; }
        .modal-title { 
            font-size: 17px; font-weight: 600; color: #fff; 
            text-align: center; flex: 1;
        }
        .modal-body { padding: 16px; }
        .modal-input-wrapper {
            background: rgba(0,0,0,0.2);
            border-radius: 10px;
            border: 1px solid rgba(255,255,255,0.08);
            overflow: hidden;
        }
        .modal-input {
            width: 100%; height: 44px; padding: 0 14px;
            background: transparent; border: none;
            color: #fff; font-size: 17px; outline: none;
        }
        .modal-input::placeholder { color: rgba(255,255,255,0.3); }
        .modal-input:focus { background: rgba(255,255,255,0.03); }
        .modal-hint {
            font-size: 13px; color: rgba(255,255,255,0.4);
            margin-top: 10px; text-align: center;
        }
    </style>
</head>
<body>
    <div class="remote-body">
        <div class="power-indicator" id="indicator"></div>
        <div class="touchpad-ring">
            <div class="touchpad-inner">
                <div class="dpad-container">
                    <button class="dpad-btn up-btn" data-key="19"><svg viewBox="0 0 24 24"><path d="M7.41 15.41L12 10.83l4.59 4.58L18 14l-6-6-6 6z"/></svg></button>
                    <button class="dpad-btn left-btn" data-key="21"><svg viewBox="0 0 24 24"><path d="M15.41 7.41L14 6l-6 6 6 6 1.41-1.41L10.83 12z"/></svg></button>
                    <button class="center-btn" data-key="23"></button>
                    <button class="dpad-btn right-btn" data-key="22"><svg viewBox="0 0 24 24"><path d="M10 6L8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg></button>
                    <button class="dpad-btn down-btn" data-key="20"><svg viewBox="0 0 24 24"><path d="M7.41 8.59L12 13.17l4.59-4.58L18 10l-6 6-6-6z"/></svg></button>
                </div>
            </div>
        </div>
        <div class="btn-row">
            <button class="action-btn" data-key="4"><svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg></button>
            <button class="action-btn" id="keyboardBtn"><svg viewBox="0 0 24 24"><path d="M20 5H4c-1.1 0-1.99.9-1.99 2L2 17c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm-9 3h2v2h-2V8zm0 3h2v2h-2v-2zM8 8h2v2H8V8zm0 3h2v2H8v-2zm-1 2H5v-2h2v2zm0-3H5V8h2v2zm9 7H8v-2h8v2zm0-4h-2v-2h2v2zm0-3h-2V8h2v2zm3 3h-2v-2h2v2zm0-3h-2V8h2v2z"/></svg></button>
        </div>
        <div class="brand-text">lunaTV</div>
    </div>
    <div class="modal-overlay" id="modal">
        <div class="modal">
            <div class="modal-header">
                <button class="modal-header-btn cancel" id="cancelBtn">取消</button>
                <div class="modal-title">输入文本</div>
                <button class="modal-header-btn send" id="sendBtn">发送</button>
            </div>
            <div class="modal-body">
                <div class="modal-input-wrapper">
                    <input type="text" class="modal-input" id="textInput" placeholder="请输入...">
                </div>
                <div class="modal-hint">按回车键发送</div>
            </div>
        </div>
    </div>
    <script>
        const indicator = document.getElementById('indicator');
        function setStatus(ok) { indicator.className = 'power-indicator' + (ok ? '' : ' error'); }
        async function sendKey(k) {
            try {
                const r = await fetch('/api/key', { method: 'POST', body: k.toString() });
                setStatus(r.ok);
            } catch (e) { setStatus(false); }
        }
        document.querySelectorAll('[data-key]').forEach(btn => {
            const k = parseInt(btn.dataset.key);
            btn.addEventListener('touchstart', e => { e.preventDefault(); sendKey(k); if(navigator.vibrate) navigator.vibrate(10); });
            btn.addEventListener('click', e => { if(e.pointerType !== 'touch') sendKey(k); });
        });
        const modal = document.getElementById('modal');
        const textInput = document.getElementById('textInput');
        const keyboardBtn = document.getElementById('keyboardBtn');
        const cancelBtn = document.getElementById('cancelBtn');
        const sendBtn = document.getElementById('sendBtn');
        function openModal() { modal.classList.add('show'); setTimeout(() => textInput.focus(), 100); }
        function closeModal() { modal.classList.remove('show'); textInput.value = ''; }
        keyboardBtn.addEventListener('click', openModal);
        cancelBtn.addEventListener('click', closeModal);
        modal.addEventListener('click', e => { if (e.target === modal) closeModal(); });
        async function sendText() {
            const text = textInput.value.trim();
            if (!text) return;
            try {
                const r = await fetch('/api/text', { method: 'POST', body: text });
                if (r.ok) { textInput.value = ''; closeModal(); }
                setStatus(r.ok);
            } catch (e) { setStatus(false); }
        }
        sendBtn.addEventListener('click', sendText);
        textInput.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); sendText(); } });
        document.addEventListener('keydown', e => {
            if (modal.classList.contains('show')) { if (e.key === 'Escape') closeModal(); return; }
            const m = { ArrowUp: 19, ArrowDown: 20, ArrowLeft: 21, ArrowRight: 22, Enter: 23, Escape: 4, Backspace: 4 };
            if (m[e.key]) { e.preventDefault(); sendKey(m[e.key]); }
        });
        setInterval(async () => {
            try {
                const r = await fetch('/api/ping');
                setStatus(r.ok);
            } catch (e) { setStatus(false); }
        }, 2000);
    </script>
</body>
</html>
    """.trimIndent()
}
