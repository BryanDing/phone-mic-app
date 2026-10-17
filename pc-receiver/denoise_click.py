#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
denoise_click.py — 口播录音后处理降噪（键盘声 + 环境音）
=========================================================

对 OBS / 录屏软件录制出来的音频或视频做"先录后处理"式降噪：

  1. 自动提取音轨，统一为 48kHz 单声道 PCM（与推流链路一致）
  2. 按预设叠加 ffmpeg 降噪滤镜（adeclick / afftdn / arnndn）
  3. 自动定位静音段，给出处理前后的噪声底对比（dB）
  4. 可导出"原始 vs 降噪"试听对比片段
  5. 可把干净音轨装回视频（画面不重新编码）

三种预设（对应三类噪声，理念是能少动就少动）：

  click   仅键盘/鼠标等瞬态敲击声   adeclick 定点清除，几乎无损
  light   键盘声 + 稳态环境底噪     adeclick + afftdn 轻度频谱降噪
  strong  键盘声 + 底噪 + 非稳态    adeclick + RNNoise 神经网络
                                          （模型已自带，位于 models/sh.rnnn）

原始文件永远不会被改动，任何预设效果不满意，换一档重来即可。

用法示例：
  python denoise_click.py 录音.mp4                      # 默认 click 预设
  python denoise_click.py 录音.mp4 --preset light       # 键盘声+环境底噪
  python denoise_click.py 录音.mp4 --preset strong --ab # 强力 + 试听对比
  python denoise_click.py 录音.mp4 --remux              # 干净音轨装回视频
  python denoise_click.py 录音.mp4 --af "adeclick,afftdn=nr=6"  # 自定义滤镜链
  python denoise_click.py --list-presets                # 查看所有预设

输出命名：默认 <输入名>_<预设名>.wav（如 录音_light.wav），不会互相覆盖。
自定义滤镜里若要用 arnndn，写 "arnndn" 即可（自动用自带模型）；若写
"arnndn=model=自己的路径.rnnn" 则用你自己的模型文件。

录音建议（让后处理效果最好）：
  · 开头留 2-3 秒纯环境音（不说话、不敲键盘）——脚本用它测量噪声底
  · OBS 里不要加任何音频滤镜，要原始音
  · 格式无所谓，视频文件可以直接拖进来
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SAMPLE_RATE = 48000

# RNNoise 模型文件（ffmpeg 的 arnndn 滤镜不内置模型，需外部 .rnnn）
RNNOISE_MODEL = "sh.rnnn"

PRESETS = {
    "click": "adeclick",
    "light": "adeclick,afftdn=nr=8:nf=-45:tn=1",
    "strong": "adeclick,arnndn",
}

PRESET_DESC = {
    "click": "仅键盘/鼠标等瞬态敲击声（定点清除，几乎无损）",
    "light": "键盘声 + 稳态环境底噪（adeclick + afftdn 轻度频谱降噪）",
    "strong": "键盘声 + 底噪 + 非稳态噪声（adeclick + RNNoise 神经网络）",
}


def find_rnnoise_model_dir():
    """定位自带 RNNoise 模型所在目录（脚本旁的 models/）。"""
    cand = Path(__file__).resolve().parent / "models"
    return cand if (cand / RNNOISE_MODEL).is_file() else None


def build_af(af):
    """为 arnndn 注入自带模型。

    返回 (滤镜链, ffmpeg工作目录或None)。模型用裸文件名引用——Windows 盘符
    冒号会让 ffmpeg filtergraph 解析失败（引号和转义都试过，不可靠），
    最稳的做法是让 ffmpeg 以模型所在目录为工作目录运行，输入输出走绝对路径。
    """
    if "arnndn" not in af or "model=" in af:
        return af, None
    model_dir = find_rnnoise_model_dir()
    if model_dir is None:
        raise RuntimeError(
            "未找到 RNNoise 模型 %s。请从 "
            "https://github.com/GregorR/rnnoise-models 下载 "
            "somnolent-hogwash-2018-09-01/sh.rnnn 放到 "
            "pc-receiver/models/ 目录后重试。" % RNNOISE_MODEL)
    return af.replace("arnndn", "arnndn=model=%s" % RNNOISE_MODEL, 1), model_dir


def find_exe(name):
    """在 PATH 或常见安装位置找 ffmpeg。"""
    p = shutil.which(name)
    if p:
        return p
    fallbacks = [r"C:\ProgramData\chocolatey\bin\%s.exe" % name]
    for c in fallbacks:
        if os.path.isfile(c):
            return c
    return name


def run(cmd, timeout=600, cwd=None):
    return subprocess.run(cmd, capture_output=True, text=True,
                          errors="replace", timeout=timeout, cwd=cwd)


def probe_duration(ffmpeg, path):
    r = run([ffmpeg, "-hide_banner", "-i", str(path)])
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", r.stderr or "")
    if not m:
        return None
    h, mi, s = m.groups()
    return int(h) * 3600 + int(mi) * 60 + float(s)


def has_video_stream(ffmpeg, path):
    r = run([ffmpeg, "-hide_banner", "-i", str(path)])
    return "Video:" in (r.stderr or "")


def find_silence(ffmpeg, wav, min_dur=1.2):
    """找第一段足够长的静音（从 -35dB 逐步放宽到 -25dB）。"""
    for db in (-35.0, -30.0, -25.0):
        r = run([ffmpeg, "-hide_banner", "-i", str(wav), "-af",
                 "silencedetect=noise=%.0fdB:d=%.1f" % (db, min_dur),
                 "-f", "null", "-"])
        out = r.stderr or ""
        starts = re.findall(r"silence_start:\s*([\d.]+)", out)
        ends = re.findall(r"silence_end:\s*([\d.]+)", out)
        dur = probe_duration(ffmpeg, wav) or 0.0
        for i, s in enumerate(starts):
            s = float(s)
            e = float(ends[i]) if i < len(ends) else dur
            if e - s >= min_dur:
                return s, e
    return None


def _num(m):
    if not m:
        return None
    v = m.group(1)
    return None if v == "-inf" else float(v)


def measure_window(s, e, min_len=0.8, max_len=3.0):
    """静音段首尾通常拖着噪声衰减尾巴（实测尾巴 RMS 可高出 10dB 以上），
    取中段测量噪声底；段太短则退回整段。返回 (起点, 时长)。"""
    a, b = s + 0.5, e - 0.25
    if b - a < min_len:
        a, b = s, e
    return a, min(max_len, b - a)


def segment_stats(ffmpeg, wav, start, dur):
    """测量一段音频的 RMS（噪声底）和 Peak（人声峰值），单位 dB。"""
    r = run([ffmpeg, "-hide_banner", "-ss", "%.3f" % start, "-t", "%.3f" % dur,
             "-i", str(wav), "-af", "astats", "-f", "null", "-"])
    out = r.stderr or ""
    rms = _num(re.search(r"RMS level dB:\s*(-?[\d.]+|-inf)", out))
    peak = _num(re.search(r"Peak level dB:\s*(-?[\d.]+|-inf)", out))
    return rms, peak


def extract_audio(ffmpeg, src, dst):
    r = run([ffmpeg, "-y", "-hide_banner", "-i", str(src), "-vn",
             "-map", "0:a:0", "-ac", "1", "-ar", str(SAMPLE_RATE),
             "-c:a", "pcm_s16le", str(dst)])
    if r.returncode != 0:
        raise RuntimeError("提取音轨失败：文件可能不含音频流，或格式不受支持")


def apply_filters(ffmpeg, src, dst, af, cwd=None):
    r = run([ffmpeg, "-y", "-hide_banner", "-i", str(src), "-af", af,
             "-c:a", "pcm_s16le", str(dst)], cwd=cwd)
    if r.returncode != 0:
        raise RuntimeError("降噪处理失败：%s" % (r.stderr or "").strip()[-300:])


def export_ab(ffmpeg, orig, clean, duration):
    """导出试听对比：每个文件 = 原始 12 秒 + 0.6 秒静音 + 同位置降噪 12 秒。
    文件以降噪结果命名，多个预设不会互相覆盖。"""
    seg = min(12.0, duration / 4.0)
    if duration <= 30:
        windows = [(1.0, seg)]
    else:
        windows = [(1.0, seg),
                   (max(0.0, duration / 2 - seg / 2), seg),
                   (max(0.0, duration - seg - 1.0), seg)]
    outdir = clean.parent
    paths = []
    for i, (s, d) in enumerate(windows, 1):
        out = outdir / ("%s_试听对比_%d.wav" % (clean.stem, i))
        r = run([ffmpeg, "-y", "-hide_banner",
                 "-ss", "%.3f" % s, "-t", "%.3f" % d, "-i", str(orig),
                 "-ss", "%.3f" % s, "-t", "%.3f" % d, "-i", str(clean),
                 "-f", "lavfi", "-t", "0.6", "-i", "anullsrc=r=%d:cl=mono" % SAMPLE_RATE,
                 "-filter_complex", "[0:a][2:a][1:a]concat=n=3:v=0:a=1[a]",
                 "-map", "[a]", "-c:a", "pcm_s16le", str(out)])
        if r.returncode == 0:
            paths.append(out)
        else:
            print("[!] 第 %d 段对比导出失败" % i)
    return paths


def remux(ffmpeg, video, clean_wav, out):
    r = run([ffmpeg, "-y", "-hide_banner", "-i", str(video), "-i", str(clean_wav),
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
             "-c:a", "aac", "-b:a", "256k", "-shortest", str(out)])
    if r.returncode != 0:
        raise RuntimeError("装回视频失败：%s" % (r.stderr or "").strip()[-300:])


def process_one(args, ffmpeg, src):
    src = Path(src).resolve()
    if not src.exists():
        print("[!] 文件不存在: %s" % src)
        return False
    stem = src.stem
    outdir = (Path(args.outdir) if args.outdir else src.parent).resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    tag = "custom" if args.af else args.preset
    out_wav = Path(args.out).resolve() if args.out else outdir / ("%s_%s.wav" % (stem, tag))

    af = args.af if args.af else PRESETS[args.preset]
    print("[+] 输入: %s" % src)
    print("[+] 降噪链: %s" % af)

    tmp = Path(tempfile.mkdtemp(prefix="dnclk_"))
    try:
        af, model_dir = build_af(af)
        if model_dir:
            print("[+] RNNoise 模型: %s" % (model_dir / RNNOISE_MODEL))
        work = tmp / "work.wav"
        extract_audio(ffmpeg, src, work)
        duration = probe_duration(ffmpeg, work) or 0.0
        print("[+] 音轨: %.1f 秒, 48kHz 单声道 PCM" % duration)

        sil = find_silence(ffmpeg, work)
        before_rms = peak_before = None
        ms = md = None
        if sil:
            s, e = sil
            ms, md = measure_window(s, e)
            before_rms, peak_before = segment_stats(ffmpeg, work, ms, md)
            print("[+] 静音段: %.2fs - %.2fs；噪声底采样窗口 %.2fs - %.2fs"
                  % (s, e, ms, ms + md))
        else:
            print("[!] 未找到静音段（建议录音开头留 2-3 秒纯环境音），跳过噪声底测量")

        apply_filters(ffmpeg, work, out_wav, af, cwd=model_dir)
        print("[+] 已生成: %s" % out_wav)

        if sil:
            after_rms, peak_after = segment_stats(ffmpeg, out_wav, ms, md)
            if before_rms is not None and after_rms is not None:
                print("[+] 噪声底: %.1f dB -> %.1f dB（采样窗口 %.2fs-%.2fs，降低 %.1f dB）"
                      % (before_rms, after_rms, ms, ms + md,
                         before_rms - after_rms))
            if peak_before is not None and peak_after is not None \
                    and peak_before - peak_after > 3:
                print("[+] 敲击清除证据: 静音段内峰值 %.1f dB -> %.1f dB"
                      % (peak_before, peak_after))
        if duration > 0:
            full_before = segment_stats(ffmpeg, work, 0.0, duration)[1]
            full_after = segment_stats(ffmpeg, out_wav, 0.0, duration)[1]
            if full_before is not None and full_after is not None:
                print("[+] 全程峰值: %.1f dB -> %.1f dB（变化 %+.1f dB，人声电平保留情况）"
                      % (full_before, full_after, full_after - full_before))

        if args.ab and duration > 6:
            ab_paths = export_ab(ffmpeg, work, out_wav, duration)
            for p in ab_paths:
                print("[+] 试听对比: %s" % p)
            if ab_paths:
                print("    （每个文件前 12 秒是原始、后 12 秒是降噪，同一位置）")

        if args.remux:
            if has_video_stream(ffmpeg, src):
                out_video = outdir / ("%s_clean%s" % (stem, src.suffix or ".mp4"))
                remux(ffmpeg, src, out_wav, out_video)
                print("[+] 已装回视频: %s" % out_video)
            else:
                print("[!] 输入不是视频，跳过 --remux")
    except RuntimeError as e:
        print("[!] %s" % e)
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return True


def main():
    ap = argparse.ArgumentParser(
        description="口播录音后处理降噪（键盘声 + 环境音），基于 ffmpeg，原始文件不会被改动")
    ap.add_argument("inputs", nargs="+", help="音频或视频文件（可多个，支持视频直接处理）")
    ap.add_argument("--preset", default="click", choices=list(PRESETS),
                    help="降噪预设（默认 click）")
    ap.add_argument("--af", help="自定义 ffmpeg 音频滤镜链，覆盖预设，如 "
                                 "\"adeclick,afftdn=nr=6\"")
    ap.add_argument("--ab", action="store_true",
                    help="导出原始 vs 降噪试听对比片段（各约 12 秒）")
    ap.add_argument("--remux", action="store_true",
                    help="把干净音轨装回视频（画面不重新编码）")
    ap.add_argument("--out", help="输出 wav 路径（默认 <输入名>_<预设名>.wav）")
    ap.add_argument("--outdir", help="输出目录（默认与输入同目录）")
    ap.add_argument("--list-presets", action="store_true", help="查看所有预设后退出")
    args = ap.parse_args()

    if args.list_presets:
        print("可用预设：")
        for k, v in PRESETS.items():
            print("  %-7s %s" % (k, PRESET_DESC[k]))
            print("         滤镜链: %s" % v)
        print("\nstrong 预设的 RNNoise 模型已自带（models/%s）。" % RNNOISE_MODEL)
        print("录音开头留 2-3 秒纯环境音，脚本会自动用它测量噪声底。")
        return

    if args.out and len(args.inputs) > 1:
        print("[!] 多个输入时不能用 --out，请用 --outdir")
        sys.exit(1)

    ffmpeg = find_exe("ffmpeg")
    print("[+] ffmpeg: %s" % ffmpeg)

    ok = True
    for src in args.inputs:
        ok = process_one(args, ffmpeg, src) and ok
        print()

    print("提示：原始文件未改动。效果不满意就换 --preset 或用 --af 调强度重试。")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
