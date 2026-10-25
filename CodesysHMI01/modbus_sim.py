"""Tiny Modbus TCP slave that mimics the Codesys example program.

Usage:  python modbus_sim.py [port]      (default port 1502)

Map (same as vars.csv):
  COIL 0 Motor_Run, 1 Pump_Enable, 2 Alarm_Reset
  DI   0 Motor_Running, 1 Alarm_Active
  HR   0 Speed_SP INT, 1 Temp_SP INT, 2-3 Flow_SP REAL, 4-5 Batch_Target DINT
  IR   0 Speed_PV INT, 1 Temp_PV INT, 2-3 Flow_PV REAL, 4-5 Pressure_PV REAL, 6-7 Batch_Count DINT
32-bit values use Codesys word order: low word at the lower address.
"""
import math
import socketserver
import struct
import sys
import threading
import time

N = 1024
coils = [False] * N
di = [False] * N
hr = [0] * N
ir = [0] * N
lock = threading.Lock()


def put32(regs, addr, raw4):
    lo, hi = struct.unpack("<HH", raw4)
    regs[addr], regs[addr + 1] = lo, hi


def get32(regs, addr):
    return struct.pack("<HH", regs[addr], regs[addr + 1])


def simulate():
    speed = temp = flow = 0.0
    count = 0
    t0 = time.time()
    with lock:
        hr[0], hr[1] = 900, 65
        put32(hr, 2, struct.pack("<f", 18.5))
        put32(hr, 4, struct.pack("<i", 5000))
    while True:
        time.sleep(0.1)
        with lock:
            sp_speed = struct.unpack("<h", struct.pack("<H", hr[0]))[0]
            sp_temp = struct.unpack("<h", struct.pack("<H", hr[1]))[0]
            sp_flow = struct.unpack("<f", get32(hr, 2))[0]
            target = struct.unpack("<i", get32(hr, 4))[0]
            speed += ((sp_speed if coils[0] else 0) - speed) * 0.08
            temp += ((sp_temp if coils[0] else 25) - temp) * 0.02
            flow += ((sp_flow if coils[1] else 0) - flow) * 0.1
            if coils[0] and speed > 50 and count < target:
                count += 1
            pressure = 4 + 1.5 * math.sin((time.time() - t0) * 0.7) + flow * 0.05
            if coils[2]:
                di[1] = False
                coils[2] = False
            if temp > 100:
                di[1] = True
            di[0] = speed > 10
            ir[0] = int(round(speed)) & 0xFFFF
            ir[1] = int(round(temp)) & 0xFFFF
            put32(ir, 2, struct.pack("<f", flow))
            put32(ir, 4, struct.pack("<f", pressure))
            put32(ir, 6, struct.pack("<i", count))


def bits_to_bytes(bits):
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        if b:
            out[i // 8] |= 1 << (i % 8)
    return bytes(out)


def handle_pdu(pdu):
    fc = pdu[0]
    try:
        with lock:
            if fc in (1, 2):
                addr, cnt = struct.unpack(">HH", pdu[1:5])
                src = coils if fc == 1 else di
                if addr + cnt > N:
                    return bytes([fc | 0x80, 2])
                data = bits_to_bytes(src[addr:addr + cnt])
                return bytes([fc, len(data)]) + data
            if fc in (3, 4):
                addr, cnt = struct.unpack(">HH", pdu[1:5])
                src = hr if fc == 3 else ir
                if addr + cnt > N:
                    return bytes([fc | 0x80, 2])
                data = b"".join(struct.pack(">H", v) for v in src[addr:addr + cnt])
                return bytes([fc, len(data)]) + data
            if fc == 5:
                addr, val = struct.unpack(">HH", pdu[1:5])
                if addr >= N:
                    return bytes([fc | 0x80, 2])
                coils[addr] = val == 0xFF00
                return pdu[:5]
            if fc == 6:
                addr, val = struct.unpack(">HH", pdu[1:5])
                if addr >= N:
                    return bytes([fc | 0x80, 2])
                hr[addr] = val
                return pdu[:5]
            if fc == 16:
                addr, cnt, _ = struct.unpack(">HHB", pdu[1:6])
                if addr + cnt > N:
                    return bytes([fc | 0x80, 2])
                for i in range(cnt):
                    hr[addr + i] = struct.unpack(">H", pdu[6 + i * 2:8 + i * 2])[0]
                return pdu[:5]
    except struct.error:
        return bytes([fc | 0x80, 3])
    return bytes([fc | 0x80, 1])


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        print("client", self.client_address)
        sock = self.request
        while True:
            hdr = self._recv(7)
            if not hdr:
                break
            tid, pid, length, uid = struct.unpack(">HHHB", hdr)
            pdu = self._recv(length - 1)
            if not pdu:
                break
            resp = handle_pdu(pdu)
            sock.sendall(struct.pack(">HHHB", tid, 0, len(resp) + 1, uid) + resp)
        print("closed", self.client_address)

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.request.recv(n - len(buf))
            if not chunk:
                return b""
            buf += chunk
        return buf


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 1502
    threading.Thread(target=simulate, daemon=True).start()
    print(f"Modbus TCP simulator on port {port}")
    Server(("0.0.0.0", port), Handler).serve_forever()
