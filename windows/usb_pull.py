"""通过 USB（usbmuxd）与 iPhone 上的 USB 传输 App 互传文件，大小不限。
命令行用法：
    python usb_pull.py list
    python usb_pull.py get 文件名 [保存目录]
    python usb_pull.py put 本地文件路径
    python usb_pull.py clean [保存目录]     # 清理未下载完成的 .part 文件
需要：Windows 已安装 iTunes 或 Apple Devices，iPhone 已解锁并点过"信任此电脑"。
"""
import glob
import json
import os
import plistlib
import shutil
import socket
import struct
import sys

MUX_ADDR = ("127.0.0.1", 27015)   # Windows 上 usbmuxd 监听的 TCP 端口
APP_PORT = 5005                   # 与 iOS 端一致
PROG = "usb-pull"
NOT_FOUND = 0xFFFFFFFFFFFFFFFF
PC_RESERVE = 200 * 1024 * 1024    # 电脑端始终保留 200MB，避免磁盘被写满
IO_TIMEOUT = 60                   # 60 秒收不到任何数据就判定中断（比如手机 App 退到后台）


def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("连接被关闭")
        buf += chunk
    return buf


def _mux_send(s, payload, tag):
    data = plistlib.dumps(payload)
    s.sendall(struct.pack("<IIII", 16 + len(data), 1, 8, tag) + data)


def _mux_recv(s):
    length, _, _, _ = struct.unpack("<IIII", _recv_exact(s, 16))
    return plistlib.loads(_recv_exact(s, length - 16))


def find_usb_device():
    """只接受 USB 连接的设备，忽略无线同步出现的 Network 设备。"""
    s = socket.create_connection(MUX_ADDR)
    _mux_send(s, {"MessageType": "ListDevices", "ClientVersionString": PROG, "ProgName": PROG}, 1)
    resp = _mux_recv(s)
    s.close()
    for d in resp.get("DeviceList", []):
        props = d["Properties"]
        if props.get("ConnectionType") == "USB":
            return props["DeviceID"]
    raise RuntimeError("没有找到 USB 连接的 iPhone：请检查数据线、解锁手机并点击“信任”")


def open_tunnel(device_id, port=APP_PORT):
    s = socket.create_connection(MUX_ADDR)
    _mux_send(s, {
        "MessageType": "Connect", "ClientVersionString": PROG, "ProgName": PROG,
        "DeviceID": device_id, "PortNumber": socket.htons(port),
    }, 2)
    if _mux_recv(s).get("Number") != 0:
        s.close()
        raise RuntimeError("连接手机端口失败：请确认手机上的 App 在前台运行")
    s.settimeout(IO_TIMEOUT)
    return s  # 握手完成后，这个 socket 就是直通手机 App 的 TCP 通道


def _read_line(s):
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    return data


def _ask(dev, line):
    s = open_tunnel(dev)
    try:
        s.sendall(line.encode("utf-8") + b"\n")
        return _read_line(s)
    finally:
        s.close()


def list_files(dev):
    return json.loads(_ask(dev, "LIST"))


def phone_info(dev):
    """返回 {'free': 手机剩余字节, 'used': App 已用字节, 'reserve': 手机保留字节}"""
    return json.loads(_ask(dev, "INFO"))


def _unique_path(folder, name):
    base, ext = os.path.splitext(name)
    path = os.path.join(folder, name)
    i = 1
    while os.path.exists(path):
        path = os.path.join(folder, f"{base} ({i}){ext}")
        i += 1
    return path


def download(dev, name, dest_dir, progress=None, delete_after=False):
    """手机 → 电脑。先写 .part，完整收完才改成正式文件名；失败会自动删除半成品。
    delete_after=True 时，下载并校验完整后通知手机删除它那份副本。"""
    os.makedirs(dest_dir, exist_ok=True)
    s = open_tunnel(dev)
    part = None
    try:
        s.sendall(f"GET {name}\n".encode("utf-8"))
        size = struct.unpack(">Q", _recv_exact(s, 8))[0]
        if size == NOT_FOUND:
            raise FileNotFoundError(name)
        free = shutil.disk_usage(dest_dir).free
        if size + PC_RESERVE > free:
            raise OSError(f"电脑磁盘空间不足：需要 {size / 1048576:,.0f} MB，"
                          f"剩余 {free / 1048576:,.0f} MB（另需保留 200 MB）")
        final = _unique_path(dest_dir, os.path.basename(name))
        part = final + ".part"
        got = 0
        with open(part, "wb") as f:
            while got < size:
                chunk = s.recv(min(1 << 20, size - got))
                if not chunk:
                    raise ConnectionError("传输中断（请保持手机 App 在前台、数据线连接稳定）")
                f.write(chunk)
                got += len(chunk)
                if progress:
                    progress(got, size)
        os.replace(part, final)
        part = None
    finally:
        s.close()
        if part and os.path.exists(part):
            os.remove(part)
    if delete_after:
        _ask(dev, f"DEL {name}")
    return final


def send_file(dev, path, progress=None):
    """电脑 → 手机。发送前先检查手机剩余空间。"""
    size = os.path.getsize(path)
    name = os.path.basename(path)
    info = phone_info(dev)
    if size + info["reserve"] > info["free"]:
        raise OSError(f"手机空间不足：{name} 需要 {size / 1048576:,.0f} MB，"
                      f"手机剩余 {info['free'] / 1048576:,.0f} MB（另需保留 {info['reserve'] // 1048576} MB）")
    s = open_tunnel(dev)
    try:
        s.sendall(f"PUT {name} {size}\n".encode("utf-8"))
        sent = 0
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                s.sendall(chunk)
                sent += len(chunk)
                if progress:
                    progress(sent, size)
        s.settimeout(600)  # 手机可能还在把大视频存进相册，多等一会儿
        ack = _read_line(s).strip()
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
        raise ConnectionError("手机中断了接收（可能空间不足，或 App 退到了后台）")
    finally:
        s.close()
    if ack != b"OK":
        raise ConnectionError("手机没有确认接收：" + (ack.decode("utf-8", "ignore") or "无响应"))


def clean_partial(folder):
    """删除保存目录里未下载完成的 .part 文件，返回 (个数, 字节数)。"""
    count = total = 0
    for p in glob.glob(os.path.join(folder, "*.part")):
        try:
            total += os.path.getsize(p)
            os.remove(p)
            count += 1
        except OSError:
            pass
    return count, total


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "get", "put", "clean"):
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]

    def show(a, b):
        print(f"\r{a / b if b else 1:6.1%}  {a:,}/{b:,}", end="", flush=True)

    if cmd == "clean":
        n, b = clean_partial(sys.argv[2] if len(sys.argv) > 2 else ".")
        print(f"已清理 {n} 个未完成文件，释放 {b / 1048576:,.1f} MB")
        sys.exit(0)
    device = find_usb_device()
    if cmd == "list":
        for item in list_files(device):
            print(f"{item['size']:>14,}  {item['name']}")
    elif cmd == "get":
        print("\n已保存：" + download(device, sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ".", show))
    else:
        send_file(device, sys.argv[2], show)
        print("\n已上传到手机")
