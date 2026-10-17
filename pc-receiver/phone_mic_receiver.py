#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
phone_mic_receiver.py
=====================
电脑端接收程序：接收"手机麦克风推流"App 发来的 PCM 音频
（48 kHz / 单声道 / 16 bit，不压缩），输出到虚拟麦克风。

链路：手机 App --WiFi--> 本程序 --> VB-CABLE Input --> 系统虚拟麦克风(CABLE Output)
之后在腾讯会议 / 钉钉 / 录音机等软件里把麦克风选成 "CABLE Output" 即可。

用法：
    python phone_mic_receiver.py                 # 默认端口 5000，输出到 CABLE Input
    python phone_mic_receiver.py --port 5001     # 换端口
    python phone_mic_receiver.py --list-devices  # 列出所有音频设备
    python phone_mic_receiver.py --device "扬声器"  # 临时输出到真实扬声器做测试
"""
import argparse
import math
import socket
import sys
import threading
import time
from array import array

FRAME_BYTES = 2  # int16 单声道
WRITE_CHUNK_BYTES = 4096  # 每次写入声卡的数据量（2048 帧）


def rms_level(chunk: bytes) -> float:
    """计算一段 PCM 的 RMS 音量（0~1 左右），用于界面显示。"""
    usable = len(chunk) - (len(chunk) % FRAME_BYTES)
    if usable <= 0:
        return 0.0
    a = array('h')
    a.frombytes(chunk[:usable])
    if sys.byteorder == 'big':
        a.byteswap()
    total = 0.0
    for v in a:
        f = v / 32768.0
        total += f * f
    return math.sqrt(total / len(a))


def find_output_device(substr: str):
    """按名字片段查找输出设备，返回设备索引；找不到返回 None。"""
    import sounddevice as sd
    devices = sd.query_devices()
    matches = [
        i for i, d in enumerate(devices)
        if substr.lower() in d['name'].lower() and d['max_output_channels'] >= 1
    ]
    return matches[0] if matches else None


def local_ips() -> list:
    """列出本机 IPv4 地址，供手机 App 填写。"""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ips.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        ips.append(socket.gethostbyname(socket.gethostname()))
    except Exception:
        pass
    return list(dict.fromkeys(ips))


def main() -> None:
    ap = argparse.ArgumentParser(description='手机麦克风推流接收器 -> 虚拟麦克风')
    ap.add_argument('--port', type=int, default=5000, help='监听端口（默认 5000，需和手机 App 一致）')
    ap.add_argument('--device', default='CABLE Input',
                    help='输出设备名匹配串（默认 "CABLE Input"，即 VB-CABLE 输入）')
    ap.add_argument('--rate', type=int, default=48000, help='采样率（默认 48000）')
    ap.add_argument('--channels', type=int, default=1, help='声道数（默认 1）')
    ap.add_argument('--list-devices', action='store_true', help='列出音频设备后退出')
    args = ap.parse_args()

    import sounddevice as sd

    if args.list_devices:
        print(sd.query_devices())
        return

    dev = find_output_device(args.device)
    if dev is None:
        print('[!] 找不到包含 "%s" 的输出设备，已改用默认输出设备。' % args.device)
        print('    如果没装 VB-CABLE，请先安装；或用 --list-devices 查看设备名。')
        dev = sd.default.device[1]
    dev_name = sd.query_devices(dev)['name']
    print('[+] 输出设备: %s' % dev_name)

    stream = sd.RawOutputStream(samplerate=args.rate, channels=args.channels,
                                dtype='int16', device=dev)
    stream.start()
    print('[+] 音频参数: %d Hz / %d ch / int16' % (args.rate, args.channels))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', args.port))
    srv.listen(1)
    ips = local_ips()
    ip_hint = ' 或 '.join(ips) if ips else '（未能自动获取，请用 ipconfig 查看）'
    print('[+] 等待手机连接… 手机 App 里填: %s :%d' % (ip_hint, args.port))
    print('[+] Ctrl+C 退出\n')

    state = {'total': 0, 'level': 0.0, 'lock': threading.Lock()}
    stop_flag = threading.Event()

    def meter() -> None:
        last = 0
        last_t = time.time()
        while not stop_flag.is_set():
            time.sleep(0.2)
            with state['lock']:
                cur = state['total']
                lvl = state['level']
            now = time.time()
            dt = max(0.001, now - last_t)
            kbps = (cur - last) / 1024.0 / dt
            last, last_t = cur, now
            bar = '#' * int(lvl * 30)
            sys.stdout.write('\r    音量 |%-30s| %7.1f KB/s  总计 %8.2f MB   '
                             % (bar, kbps, cur / 1048576.0))
            sys.stdout.flush()

    threading.Thread(target=meter, daemon=True).start()

    try:
        while True:
            conn, addr = srv.accept()
            sys.stdout.write('\r[+] 手机已连接: %s:%d\n' % (addr[0], addr[1]))
            sys.stdout.flush()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with state['lock']:
                state['total'] = 0
            buf = bytearray()
            try:
                while True:
                    data = conn.recv(8192)
                    if not data:
                        break
                    with state['lock']:
                        state['total'] += len(data)
                    state['level'] = rms_level(data)
                    buf += data
                    # 按固定块写入声卡，避免块大小不齐
                    while len(buf) >= WRITE_CHUNK_BYTES:
                        stream.write(bytes(buf[:WRITE_CHUNK_BYTES]))
                        del buf[:WRITE_CHUNK_BYTES]
            except OSError as e:
                sys.stdout.write('\n[!] 音频输出错误: %s\n' % e)
            finally:
                conn.close()
                sys.stdout.write('\n[-] 手机已断开，等待重新连接…\n')
    except KeyboardInterrupt:
        sys.stdout.write('\n[+] 正在退出…\n')
    finally:
        stop_flag.set()
        try:
            stream.stop()
            stream.close()
        except Exception:
            pass
        srv.close()


if __name__ == '__main__':
    main()
