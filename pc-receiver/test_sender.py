#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_sender.py
==============
本地测试工具：不连手机，直接给接收程序发一段正弦测试音，
用来验证"接收程序 -> 虚拟麦克风 -> 会议软件"这条电脑端链路是否通畅。

用法：
    先运行:  python phone_mic_receiver.py --device "CABLE Input"
    再运行:  python test_sender.py
然后打开 Windows 录音机或会议软件，选 "CABLE Output" 麦克风，应能听到 660Hz 提示音。
"""
import argparse
import math
import socket
import struct
import time

RATE = 48000


def main() -> None:
    ap = argparse.ArgumentParser(description='发送测试音到接收程序')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=5000)
    ap.add_argument('--duration', type=float, default=2.0, help='测试音时长（秒）')
    ap.add_argument('--freq', type=float, default=660.0, help='测试音频率（Hz）')
    ap.add_argument('--amp', type=float, default=0.2, help='音量 0~1（默认 0.2，小声）')
    args = ap.parse_args()

    n = int(RATE * args.duration)
    pcm = bytearray()
    for i in range(n):
        v = math.sin(2 * math.pi * args.freq * i / RATE) * args.amp
        pcm += struct.pack('<h', int(v * 32767))

    s = socket.create_connection((args.host, args.port), timeout=5)
    print('[+] 已连接 %s:%d，发送 %.1f 秒 %.0f Hz 测试音（音量 %.2f）…'
          % (args.host, args.port, args.duration, args.freq, args.amp))
    step = 8192
    for i in range(0, len(pcm), step):
        s.sendall(pcm[i:i + step])
        time.sleep(step / (RATE * 2))  # 按实时速率发送
    time.sleep(0.5)
    s.close()
    print('[+] 发送完成。如果虚拟麦克风正常，此时应能在录音软件里看到音量。')


if __name__ == '__main__':
    main()
