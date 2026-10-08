#!/usr/bin/env python3
"""開発サーバー（docker compose の relay コンテナ）の GET /health と GET /ws を、実際に確かめる（issue #21）。

使い方: python3 -I dev_server_check.py [--port 3002] [--skip-slow]
  --port       relay を公開しているポート（既定は環境変数 RELAY_PORT、無ければ 3002）
  --skip-slow  接続通知（hello）の期限 10 秒を待つ確認を省く

標準ライブラリだけで、RFC 6455 の最小のクライアントを実装する（ブラウザは使わない）。実際の YouTube・アプリケーションには
接続しない（無効なチケットを送って、中継が致命通知で切ることを確かめるだけ）。

確かめること:
  1. GET /health が 200 と {"status":"ok"}
  2. WebSocket ではない GET /ws は 400。POST /ws は 404（GET だけを割り当てている）
  3. 他のオリジン（Origin: http://evil.example）からの WebSocket の接続を受ける（Cookie を使わず、チケットで認可するため）
  4. 形式の不正なチケット（空白を含む）の hello -> 致命通知 invalid_ticket -> 通常の切断（Close コード 1000）
  5. 形式は正しいが、存在しないチケットの hello -> 致命通知 invalid_ticket（アプリケーションが照合できる場合）、または
     internal_error（アプリケーションの内部通信の口が、まだ無い場合）-> 通常の切断
  6. テキストのメッセージ -> 致命通知 protocol_violation -> 通常の切断
  7. 接続から 10 秒 hello が無い -> 致命通知 hello_timeout -> 通常の切断（実時間で 10 秒待つ）
  8. 2 MiB を 1 バイト超えるメッセージ -> 致命通知 message_too_large が先に届き、そのあと Close コード 1009
  9. 壊れたフレーム（識別子が違う）は、破棄されて接続が続く（続けて hello を送ると、照合へ進む）
 10. 要求ヘッダが大きすぎる要求（64 KiB）は 431。通常の大きさ（2 KiB）は受け付ける（HTTP サーバーの上限は 16 KiB）

削除系の語は、このファイルに書かない。
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HOST = "127.0.0.1"
MAGIC = b"BL"
HEADER_BYTES = 17
MAX_MESSAGE_BYTES = 2_097_152
TYPE_HELLO = 0x01
TYPE_PROBE = 0x02
TYPE_FATAL = 0x87
TYPE_ACCEPTED = 0x81
OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x1, 0x2, 0x8, 0x9, 0xA
IO_TIMEOUT = 15


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def http_request(port, method, path, headers=None):
    request = urllib.request.Request(f"http://{HOST}:{port}{path}", method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=IO_TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise Failure(f"接続が途中で閉じられました（{len(data)}/{count} バイト）")
        data += chunk
    return data


class Ws:
    """最小の WebSocket クライアント（RFC 6455。クライアントのフレームはマスクする）。"""

    def __init__(self, port, origin=None):
        self.sock = socket.create_connection((HOST, port), timeout=IO_TIMEOUT)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET /ws HTTP/1.1", f"Host: {HOST}:{port}", "Upgrade: websocket", "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13",
        ]
        if origin:
            lines.append(f"Origin: {origin}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Failure("切り替えの応答が届く前に、接続が閉じられました")
            response += chunk
        head, _, rest = response.partition(b"\r\n\r\n")
        self.buffer = rest
        status_line = head.split(b"\r\n")[0].decode()
        check(" 101 " in status_line, f"WebSocket への切り替えが 101 ではありません: {status_line}")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        check(accept.lower() in head.decode().lower(), "Sec-WebSocket-Accept が一致しません")

    def _take(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Failure("接続が途中で閉じられました")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send(self, opcode, payload):
        mask = os.urandom(4)
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)) if length < 4096 else _mask_large(payload, mask)
        self.sock.sendall(header + mask + masked)

    def receive(self):
        """次のデータフレームまたは Close フレームを (opcode, payload) で返す。ping には pong で答える。"""
        while True:
            first, second = self._take(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._take(8))[0]
            payload = self._take(length)
            if opcode == OP_PING:
                self.send(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue
            return opcode, payload

    def hello(self, ticket):
        self.send(OP_BINARY, frame(TYPE_HELLO, ticket))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def _mask_large(payload, mask):
    # 大きなペイロードは、マスクの 4 バイトを繰り返した列との XOR（整数演算で速くする）
    repeated = (mask * (len(payload) // 4 + 1))[: len(payload)]
    value = int.from_bytes(payload, "big") ^ int.from_bytes(repeated, "big")
    return value.to_bytes(len(payload), "big")


def frame(frame_type, body=b"", timestamp_us=0):
    return MAGIC + bytes([1, frame_type, 0]) + struct.pack(">Q", timestamp_us) + struct.pack(">I", len(body)) + body


def parse_frame(data):
    check(len(data) >= HEADER_BYTES, f"フレームがヘッダより短い: {len(data)} バイト")
    check(data[:2] == MAGIC, "フレームの識別子が違う")
    declared = struct.unpack(">I", data[13:17])[0]
    check(declared == len(data) - HEADER_BYTES, "フレームの本文長が合わない")
    return data[3], data[HEADER_BYTES:]


def expect_fatal_then_close(ws, want_codes, want_close):
    """致命通知（want_codes のどれか）が先に届き、そのあと、Close コード want_close で閉じられること。"""
    opcode, payload = ws.receive()
    check(opcode == OP_BINARY, f"最初のメッセージがバイナリではありません（opcode {opcode}）")
    frame_type, body = parse_frame(payload)
    check(frame_type == TYPE_FATAL, f"最初のメッセージが致命通知ではありません（種別 {frame_type:#x}）")
    code = json.loads(body)["code"]
    check(code in want_codes, f"致命通知の符号が {code} です（期待: {sorted(want_codes)}）")
    opcode, payload = ws.receive()
    check(opcode == OP_CLOSE, f"致命通知のあとが Close フレームではありません（opcode {opcode}）")
    close_code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
    check(close_code == want_close, f"Close コードが {close_code} です（期待: {want_close}）")
    return code


def run_checks(port, skip_slow):
    results = []

    def step(name, function):
        started = time.time()
        try:
            detail = function()
            results.append((name, True, detail or "", time.time() - started))
        except (Failure, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            results.append((name, False, f"{type(error).__name__}: {error}", time.time() - started))

    def health():
        status, body = http_request(port, "GET", "/health")
        check(status == 200, f"GET /health が {status}")
        check(json.loads(body) == {"status": "ok"}, f"本文が違う: {body!r}")

    def plain_requests():
        status, _ = http_request(port, "GET", "/ws")
        check(status == 400, f"WebSocket ではない GET /ws が {status}（期待 400）")
        status, _ = http_request(port, "POST", "/ws")
        check(status == 404, f"POST /ws が {status}（期待 404）")

    def header_limit():
        status, _ = http_request(port, "GET", "/health", headers={"X-Padding": "a" * 2048})
        check(status == 200, f"2 KiB のヘッダの GET /health が {status}（期待 200）")
        status, _ = http_request(port, "GET", "/health", headers={"X-Padding": "a" * 65536})
        check(status == 431, f"64 KiB のヘッダの GET /health が {status}（期待 431）")

    def foreign_origin():
        ws = Ws(port, origin="http://evil.example")
        ws.close()
        return "Origin: http://evil.example で 101"

    def malformed_ticket():
        ws = Ws(port)
        try:
            ws.hello(b"dummy ticket with spaces")
            return "致命通知 " + expect_fatal_then_close(ws, {"invalid_ticket"}, 1000)
        finally:
            ws.close()

    def unknown_ticket():
        ws = Ws(port)
        try:
            ws.hello(b"dummy-unknown-ticket-0123456789abcdefghijklmnopqrstuvwxyz")
            return "致命通知 " + expect_fatal_then_close(ws, {"invalid_ticket", "internal_error"}, 1000)
        finally:
            ws.close()

    def text_message():
        ws = Ws(port)
        try:
            ws.send(OP_TEXT, b"hello")
            return "致命通知 " + expect_fatal_then_close(ws, {"protocol_violation"}, 1000)
        finally:
            ws.close()

    def hello_timeout():
        ws = Ws(port)
        try:
            return "致命通知 " + expect_fatal_then_close(ws, {"hello_timeout"}, 1000)
        finally:
            ws.close()

    def oversize():
        ws = Ws(port)
        try:
            ws.send(OP_BINARY, b"\x00" * (MAX_MESSAGE_BYTES + 1))
            return "致命通知 " + expect_fatal_then_close(ws, {"message_too_large"}, 1009)
        finally:
            ws.close()

    def broken_frame_is_discarded():
        ws = Ws(port)
        try:
            ws.send(OP_BINARY, b"XX" + bytes(15))  # 識別子が違う。破棄されて、接続は続く
            ws.send(OP_BINARY, frame(TYPE_PROBE, b"\x00" * 100))  # 照合の前の計測データも、破棄される
            ws.hello(b"has a space")
            return "壊れたフレームのあとも接続が続き、" + expect_fatal_then_close(ws, {"invalid_ticket"}, 1000)
        finally:
            ws.close()

    step("GET /health が 200 と status ok", health)
    step("WebSocket ではない GET /ws は 400、POST /ws は 404", plain_requests)
    step("要求ヘッダが大きすぎる要求は 431（上限 16 KiB）", header_limit)
    step("他のオリジンからの WebSocket の接続を受ける", foreign_origin)
    step("形式の不正なチケット -> invalid_ticket -> 切断", malformed_ticket)
    step("存在しないチケット -> 致命通知 -> 切断", unknown_ticket)
    step("テキストのメッセージ -> protocol_violation -> 切断", text_message)
    step("2 MiB + 1 バイト -> message_too_large -> Close 1009", oversize)
    step("壊れたフレームは破棄され、接続は続く", broken_frame_is_discarded)
    if not skip_slow:
        step("hello が 10 秒無い -> hello_timeout -> 切断（実時間で待つ）", hello_timeout)
    return results


def main(argv):
    port = int(os.environ.get("RELAY_PORT", "3002"))
    skip_slow = False
    index = 1
    while index < len(argv):
        if argv[index] == "--port" and index + 1 < len(argv):
            port = int(argv[index + 1])
            index += 2
        elif argv[index] == "--skip-slow":
            skip_slow = True
            index += 1
        else:
            print(f"使い方: dev_server_check.py [--port N] [--skip-slow]（不明な引数: {argv[index]}）")
            return 2
    print(f"開発サーバー {HOST}:{port} を確かめます")
    results = run_checks(port, skip_slow)
    failed = 0
    for name, ok, detail, seconds in results:
        mark = "成功" if ok else "失敗"
        print(f"  {mark}  {name}  ({seconds:.1f} 秒) {detail}")
        if not ok:
            failed += 1
    print(f"確認 {len(results)} 件、失敗 {failed} 件")
    if failed:
        return 1
    print("問題ありません")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
