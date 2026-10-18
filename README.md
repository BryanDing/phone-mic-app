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

## 八、手机端降噪档位（App 内开关）

除了录完再处理，也可以在**采集时**就借手机系统的降噪能力。App 里"音源档位"一行就是降噪开关，推流前或推流中都能切（推流中切换约半秒声音间断，TCP 不断）：

| 档位 | 原理 | 音质影响 |
|---|---|---|
| **原声**（默认） | `SOURCE_TYPE_MIC` 普通录音 | 手机最高音质，无降噪，键盘声会录进去 |
| 无处理 | `SOURCE_TYPE_UNPROCESSED` | 系统声明完全不加算法处理 |
| 语音识别 | `SOURCE_TYPE_VOICE_RECOGNITION` | ASR 场景链路，部分机型带降噪 |
| 系统3A | `SOURCE_TYPE_VOICE_COMMUNICATION` | 通话 3A（AEC+ANS+AGC）：降噪+自动增益，**音量可能抽动**，口播慎用 |
| 语音消息 | `SOURCE_TYPE_VOICE_MESSAGE` | 微信语音风格（会暂停手机音乐播放） |

两个自动保护：
1. **采样率自动还原**：系统场景档位可能把采集降到 16kHz，App 检测到后自动重采样回 48kHz 再发包（PC 端零改动），界面会显示"实际采集：16000 Hz（已重采样回 48000 推流）"
2. **不支持自动回退**：某档位不被手机支持时，自动回退原声并提示

界面还会显示"系统智能降噪：已开启/未开启"——这是查询系统对该音源的真实状态，用来判断档位是否真的生效。

**验证方法**：同一段"静音+键盘+人声"内容每个档位录一遍，电脑端用
`python phone_mic_receiver.py --save 档位.raw` 收流存文件，再用 ffmpeg 分析噪声底/人声峰值/差值（同第七节方法），最后 A/B 试听定夺。开了手机端降噪的工作流就不要再叠 PC 后处理（官方警告重复处理会失真）。

---

## 九、引擎降噪（Phase 2：OHAudioSuite 原生 AI 降噪）

档位切换借的是系统场景链路，算法不透明。Phase 2 直接调用系统音频引擎
**OHAudioSuite**（Audio Kit）的降噪节点，与档位正交、可叠加在任意档位上：

| 项目 | 说明 |
|---|---|
| 实现 | native C++ 模块（`entry/src/main/cpp/`，NAPI 导出 `libentry_nr.so`） |
| 拓扑 | 输入节点(APP 供数 48k/单声道) → 降噪节点(202) → 输出节点(**16k/单声道**) |
| 模式 | 实时渲染管线（API 23+ 支持全部效果节点，本机 API 26 满足） |
| 音质 | 引擎输出固定 16kHz——**比档位方案的 48kHz 带宽低**，这是算法决定的 |

两个自动保护（与第八节一致的理念）：
1. **16k→48k 自动还原**：App 检测到引擎输出是 16kHz，线性插值重采样回 48kHz 再走 TCP，PC 接收端零改动
2. **失败自动回退**：`nr.init()` 失败（引擎创建失败/降噪节点不支持等）自动关闭开关，按普通推流继续，功能永远可用

界面"引擎降噪"开关位于音源档位下方，可随时热切换（推流中切换约半秒间断）。
与"系统3A"档叠加官方不建议（重复处理），仅供对比测试。

**验证方法**：与第八节相同——`python phone_mic_receiver.py --save 引擎降噪.raw`，
重点对比"原声档 vs 原声+引擎降噪 vs 系统3A"三者的噪声底与音色。

**构建说明**：native 编译需要在 `entry/build-profile.json5` 配置
`buildOption.externalNativeOptions`（hvigor 才会执行 CMake 任务）；
直接调 hvigorw.js 时需在 PATH 中加入 DevEco 自带 JDK（`jbr/bin`，打包工具要 java）
并设置 `DEVECO_SDK_HOME`。

---

## 附：实测记录（2026-10-17）

- 电脑端：本地测试音 1.5 秒收到 0.14 MB ≈ 48000×2×1.5 理论值，音量条正常，断连正常
- 编译验证（devecocli build / hvigor）：**BUILD SUCCESSFUL**，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`
- 编译过程修复 3 处代码问题：`Rectangle` 组件不存在 → 改用 `Progress`；`InputType.NUMBER` → `InputType.Number`；工程脚手架从旧版 5.0 格式重建为 26.0 标准格式（这才是 DevEco Studio 同步失败的真因）
