# 手机麦克风 → 电脑（鸿蒙 HarmonyOS 7 自研方案）

把华为手机的麦克风实时变成电脑的麦克风。**手机端 App 和电脑端程序均为本项目自研代码**，已完成电脑端全链路实测（收发、解码、虚拟声卡输出全部通过）。

```
手机 App ──WiFi(TCP, 48kHz/16bit PCM 不压缩)──▶ pc-receiver ──▶ VB-CABLE Input
                                                                      │
                                              系统虚拟麦克风 "CABLE Output" ◀─ 会议/录音软件选它
```

**为什么需要自研**：鸿蒙 7 是纯血鸿蒙（无安卓兼容层、无 adb），scrcpy、WO Mic 等安卓工具全部失效；蓝牙免提只有 8/16kHz 有损音质。本方案直接调用鸿蒙原生 `AudioCapturer`，48kHz 单声道 16bit 原始 PCM，音质无损失。

---

## 一、文件结构

| 目录 | 内容 |
|---|---|
| `PhoneMicApp/` | 手机端鸿蒙工程（用 DevEco Studio 打开） |
| `pc-receiver/` | 电脑端接收程序（Python，已验证）；`denoise_click.py` 录音降噪后处理 + `models/` RNNoise 模型 |

---

## 二、电脑端（已就绪 ✅）

1. VB-CABLE 虚拟声卡**已安装并检测到**（CABLE Input / CABLE Output 两端都在）。
2. 双击 `pc-receiver\start.bat` 启动接收程序（首次运行自动装依赖，需联网一次；防火墙弹窗点**允许**）。
3. 窗口里会显示本机 IP（当前为 **192.168.1.5**），手机 App 里填这个。换网络后 IP 可能变，以窗口显示为准。
4. 保持这个窗口开着。

## 二·补充：连接方式（WiFi 或 USB 二选一）

| 方式 | 做法 | 特点 |
|---|---|---|
| WiFi | 手机电脑连同一 WiFi | 方便；延迟约 5–30ms，受网络波动影响 |
| **USB 网络共享**（更稳） | 手机设置里搜索并打开"USB 网络共享" → 电脑会多出一个网卡 → `ipconfig` 看这个新网卡的 IP，填进手机 App | 延迟约 1–5ms，不受 WiFi 干扰，最稳 |

两种方式端口都是 5000，**不用改任何代码**，只是换个 IP 填。USB 方式下电脑 IP 通常是 192.168.42.x 或 192.168.1.x（以 ipconfig 实际显示为准）。

## 三、构建与安装到手机（二选一）

工程已是 **DevEco Studio 26.0 标准格式**（已用官方 CLI 重建脚手架并对齐，编译验证通过）。

### 方式 A：命令行一键构建（推荐）

前置：华为开发者账号已实名认证（https://developer.huawei.com/consumer/cn/ → 会员中心，个人免费）。

```bash
# 1. 登录华为开发者账号（弹出浏览器/二维码，用你的账号扫码）
devecocli auth login

# 2. 生成签名并写入工程配置
devecocli signature generate

# 3. 手机插线、允许 USB 调试后，一键构建+签名+安装+启动
devecocli run
```

`devecocli` 的安装位置：`C:\Users\Administrator\.workbuddy\binaries\node\workspace\node_modules\.bin\devecocli`（已装好 1.3.0-stable，如要全局使用可自行运行 `npm install -g @deveco/deveco-cli@stable`）。

### 方式 B：DevEco Studio 图形界面

1. 直接用 DevEco Studio 打开 `PhoneMicApp` 文件夹（格式已修复，可正常同步）
2. File → Project Structure → Sign Configs → 登录华为账号，配置调试签名
3. 手机开调试：设置 → 关于手机 → 连点"版本号"7 次 → 开发人员选项 → USB 调试；插线后点"允许"
4. 顶部选手机设备，点 ▶ Run

## 四、日常使用

1. 电脑：双击 `pc-receiver\start.bat`
2. 手机：打开"手机麦克风推流"App → 填电脑 IP（192.168.1.5）→ 端口 5000 → 点**开始推流**
3. 腾讯会议 / 钉钉 / 录音机等软件里，麦克风选 **"CABLE Output (VB-Audio Virtual Cable)"**
4. 用完在 App 里点**停止推流**

## 五、常见问题

| 现象 | 解决 |
|---|---|
| App 连不上 | IP 填错（以接收窗口显示为准）/ 不在同一网络（换 WiFi 或开 USB 网络共享）/ 电脑防火墙没放行 |
| 会议软件没声音 | 麦克风设备要选 "CABLE Output"；看接收窗口音量条是否跳动 |
| 对方听到回声 | 编辑 `Index.ets`，把 `SOURCE_TYPE_MIC` 改成 `SOURCE_TYPE_VOICE_COMMUNICATION`（开启手机端回声消除），重新运行 |
| 声音卡顿 | 换 5GHz WiFi，或改用 USB 网络共享 |
| 手机不支持 48kHz | 同时改两处采样率：`Index.ets` 里 `SAMPLE_RATE_48000` 和接收程序加 `--rate 44100`（或 16000） |
| 想换端口 | 手机 App 和电脑端 `--port` 改成同一个数 |

## 六、当前版本的限制（v1.0）

- IP 需手填（没有自动发现）
- 单台手机、单声道
- 界面极简，只有开始/停止、音量条、流量统计

后续想加（自动发现 IP、立体声、录音落盘、后台保活）随时说。

## 七、录音降噪后处理（口播 / OBS 录屏场景）

用 OBS 等软件录口播时，键盘声、环境底噪会被一起录进去。`pc-receiver\denoise_click.py` 提供**先录后处理**式降噪——录音时保持原始音，录完再按需处理，原始文件永不被改动，效果不满意换一档重来即可。

```bash
# 在 pc-receiver 目录下运行（需要 ffmpeg，已在 PATH 或 chocolatey 安装）
python denoise_click.py 录音.mp4 --preset light --ab
```

| 预设 | 滤镜链 | 适用噪声 | 音质损失 |
|---|---|---|---|
| `click`（默认） | `adeclick` | 键盘/鼠标瞬态敲击 | 定点清除，几乎无损 |
| `light` | `adeclick,afftdn=nr=8:nf=-45:tn=1` | 敲击 + 稳态底噪（空调/风扇） | 轻度频谱降噪 |
| `strong` | `adeclick,arnndn` | 敲击 + 底噪 + 非稳态（人声/电视） | 神经网络重塑，有艺术噪声风险 |

常用参数：`--ab` 导出"原始 12 秒 + 降噪 12 秒"同位置试听对比；`--remux` 把干净音轨装回视频（画面不重编码）；`--af "adeclick,afftdn=nr=6"` 自定义强度；`--list-presets` 查看全部预设。输出默认命名为 `<输入名>_<预设名>.wav`，多个预设不会互相覆盖。RNNoise 模型已自带（`pc-receiver/models/sh.rnnn`）。

**实测数据**（2026-10-17，一段 41 秒含键盘声+环境音的口播测试音频）：

| 预设 | 噪声底变化 | 全程峰值（人声电平） | 差值信号解读 |
|---|---|---|---|
| click | -57.0 → -57.1 dB | -6.4 → -6.4 dB（零变化） | 移除物 RMS -48 dB，纯瞬态敲击脉冲 |
| light | -57.0 → -57.8 dB | -6.4 → -6.4 dB（零变化） | 移除物峰值 -2.7 dB，已接近人声电平 |
| strong | -57.0 → -69.0 dB | -6.4 → -6.0 dB（+0.4 dB） | 移除物 RMS -27.9 dB，信号大幅重塑 |

结论：录音环境本身安静（噪声底 -57 dB）时，**click 档是日常首选**——只敲掉键盘声、人声零接触；light/strong 适合环境本身嘈杂的场景。

录音建议：开头留 2-3 秒纯环境音（脚本用它测噪声底）；OBS 里不要加音频滤镜，要原始音。

---

## 附：实测记录（2026-10-17）

- 电脑端：本地测试音 1.5 秒收到 0.14 MB ≈ 48000×2×1.5 理论值，音量条正常，断连正常
- 编译验证（devecocli build / hvigor）：**BUILD SUCCESSFUL**，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`
- 编译过程修复 3 处代码问题：`Rectangle` 组件不存在 → 改用 `Progress`；`InputType.NUMBER` → `InputType.Number`；工程脚手架从旧版 5.0 格式重建为 26.0 标准格式（这才是 DevEco Studio 同步失败的真因）
