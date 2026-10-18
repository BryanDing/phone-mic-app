import { audio } from '@kit.AudioKit';
import { socket } from '@kit.NetworkKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
// Phase 2：OHAudioSuite 原生降噪引擎（native 模块）
import nr from 'libentry_nr.so';

const TAG: string = 'PhoneMic';
const PORT_DEFAULT: number = 5000;
const SAMPLE_RATE: number = 48000;   // 推流固定 48kHz（PC 接收端约定）
const NR_RATE: number = 16000;       // 降噪引擎输出固定 16kHz，需重采样回 48kHz

// ---------- 音源档位 ----------
// 原声 = 手机可采集的最高音质（基准）；其余档位借系统场景算法做降噪，
// 音质可能有折损（音量动态、音色、带宽），建议与原声档各录一段对比。
interface SourceMode {
  key: string;
  label: string;
  hint: string;
  source: audio.SourceType;
}

const SOURCE_MODES: SourceMode[] = [
  {
    key: 'mic', label: '原声',
    hint: '手机最高音质，无降噪处理（基准档）',
    source: audio.SourceType.SOURCE_TYPE_MIC
  },
  {
    key: 'unproc', label: '无处理',
    hint: '系统声明完全不加算法处理（比原声更“生”）',
    source: audio.SourceType.SOURCE_TYPE_UNPROCESSED
  },
  {
    key: 'vr', label: '语音识别',
    hint: '语音识别场景链路，部分机型带降噪、可能降到 16kHz',
    source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION
  },
  {
    key: 'vc', label: '系统3A',
    hint: '通话 3A：降噪+回声消除+自动增益（音量可能抽动，口播慎用）',
    source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION
  },
  {
    key: 'vm', label: '语音消息',
    hint: '微信语音消息风格（开始录制会暂停手机音乐）',
    source: audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE
  },
];

// ---------- 重采样器状态（两套：系统降采样还原、引擎降噪输出还原） ----------
interface RsState {
  queue: number[];   // 待消费的输入样本（int16）
  pos: number;       // 分数相位位置
}

/**
 * 把 buffer（inRate 单声道 S16LE）重采样回 48kHz 输出。
 * 状态在 state 中跨缓冲连续；样本不足产不出输出时返回 null。
 */
function resampleChunk(buffer: ArrayBuffer, state: RsState, inRate: number): ArrayBuffer | null {
  // 防御：native/上游传来坏对象时直接丢弃本帧，绝不让 DataView 构造炸掉
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < 2) {
    return null;
  }
  const dv: DataView = new DataView(buffer);
  const n: number = Math.floor(dv.byteLength / 2);
  for (let i = 0; i < n; i++) {
    state.queue.push(dv.getInt16(i * 2, true));
  }
  // 每个输出样本消耗的输入样本数（<1 表示上采样）
  const step: number = Math.max(0.01, inRate / SAMPLE_RATE);
  const out: number[] = [];
  while (state.pos + 1 < state.queue.length) {
    const i: number = Math.floor(state.pos);
    const frac: number = state.pos - i;
    const a: number = state.queue[i];
    const b: number = state.queue[i + 1];
    let v: number = a + (b - a) * frac;
    if (v > 32767) {
      v = 32767;
    } else if (v < -32768) {
      v = -32768;
    }
    out.push(Math.round(v));
    state.pos += step;
  }
  const drop: number = Math.floor(state.pos);
  if (drop > 0) {
    state.queue.splice(0, drop);
    state.pos -= drop;
  }
  if (out.length === 0) {
    return null;
  }
  const ab: ArrayBuffer = new ArrayBuffer(out.length * 2);
  const ov: DataView = new DataView(ab);
  for (let i = 0; i < out.length; i++) {
    ov.setInt16(i * 2, out[i], true);
  }
  return ab;
}

@Entry
@Component
struct Index {
  @State serverIp: string = AppStorage.get<string>('pm_serverIp') ?? '192.168.1.100';
  @State serverPort: string = AppStorage.get<string>('pm_serverPort') ?? '5000';
  @State sourceKey: string = AppStorage.get<string>('pm_sourceKey') ?? 'mic';
  @State nrEnabled: boolean = AppStorage.get<boolean>('pm_nrEnabled') ?? false;
  @State status: string = '未开始';
  @State streaming: boolean = false;
  @State level: number = 0;
  @State stats: string = '';
  @State dspInfo: string = '';

  private capturer: audio.AudioCapturer | null = null;
  private tcp: socket.TCPSocket | null = null;
  private connected: boolean = false;
  private bytesSent: number = 0;
  private startedAt: number = 0;
  private cbCount: number = 0;

  // 实际采样率与重采样状态（系统场景档位可能把采集降到 16kHz）
  private actualRate: number = SAMPLE_RATE;
  private rsEnabled: boolean = false;
  private rsState: RsState = { queue: [], pos: 0 };

  // 引擎降噪（Phase 2）：native 管线输出 16kHz，用第二套重采样状态拉回 48kHz
  private nrActive: boolean = false;   // 本次推流中 nr.init() 是否成功
  private nrRsState: RsState = { queue: [], pos: 0 };
  private nrOutFrames: number = 0;

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('手机麦克风 → 电脑')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 16 })

        Text('手机和电脑需在同一网络：同一 WiFi，或开 USB 网络共享。先在电脑上运行接收程序，再点下面按钮。')
          .fontSize(13)
          .fontColor('#888888')
          .width('100%')

        Text('电脑 IP 地址')
          .fontSize(14)
          .fontColor('#333333')
          .width('100%')
          .margin({ top: 8 })
        TextInput({ placeholder: '例如 192.168.1.100', text: this.serverIp })
          .fontSize(17)
          .height(46)
          .onChange((v: string) => {
            this.serverIp = v;
            AppStorage.set('pm_serverIp', v);
          })

        Text('端口')
          .fontSize(14)
          .fontColor('#333333')
          .width('100%')
        TextInput({ placeholder: '默认 5000', text: this.serverPort })
          .fontSize(17)
          .height(46)
          .type(InputType.Number)
          .onChange((v: string) => {
            this.serverPort = v;
            AppStorage.set('pm_serverPort', v);
          })

        Text('音源档位（降噪开关在这里）')
          .fontSize(14)
          .fontColor('#333333')
          .width('100%')
          .margin({ top: 8 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SOURCE_MODES, (m: SourceMode) => {
            Button(m.label)
              .fontSize(13)
              .height(34)
              .padding({ left: 12, right: 12 })
              .type(ButtonType.Capsule)
              .margin({ right: 8, bottom: 8 })
              .backgroundColor(this.sourceKey === m.key ? '#1E8E3E' : '#EFEFEF')
              .fontColor(this.sourceKey === m.key ? '#FFFFFF' : '#333333')
              .onClick(() => {
                this.onSourceChange(m.key);
              })
          }, (m: SourceMode) => m.key)
        }
        .width('100%')
        Text(this.sourceHint())
          .fontSize(11)
          .fontColor('#999999')
          .width('100%')

        // Phase 2：OHAudioSuite 原生降噪引擎开关
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text('引擎降噪（Phase 2 实验）')
              .fontSize(14)
              .fontColor('#333333')
              .width('100%')
            Text('系统级 AI 降噪算法，可叠加在任意音源档位上；引擎固定 16kHz 输出，APP 自动还原 48kHz 推流。与"系统3A"叠加官方不建议，仅作对比测试。')
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
          }
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.nrEnabled })
            .id('nrToggle')
            .onChange((on: boolean) => {
              this.onNrToggle(on);
            })
        }
        .width('100%')
        .margin({ top: 10 })

        Button(this.streaming ? '停止推流' : '开始推流')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .type(ButtonType.Capsule)
          .width('100%')
          .height(48)
          .margin({ top: 10 })
          .backgroundColor(this.streaming ? '#C0392B' : '#1E8E3E')
          .onClick(() => {
            if (this.streaming) {
              this.stop();
            } else {
              this.start();
            }
          })

        Text(this.status)
          .fontSize(15)
          .fontColor('#555555')
          .width('100%')
          .margin({ top: 8 })

        // 音量指示条
        Row({ space: 8 }) {
          Text('音量')
            .fontSize(13)
            .fontColor('#666666')
          Progress({ value: Math.round(this.level * 100), total: 100, type: ProgressType.Linear })
            .layoutWeight(1)
            .height(10)
            .color('#1E8E3E')
            .backgroundColor('#E4E6E8')
        }
        .width('100%')
        .margin({ top: 4 })

        Text(this.stats)
          .fontSize(12)
          .fontColor('#999999')
          .width('100%')
          .margin({ top: 4 })

        Text(this.dspInfo)
          .fontSize(12)
          .fontColor('#B26A00')
          .width('100%')

        Text('推流格式：48 kHz / 单声道 / 16 bit PCM（不压缩）；系统若降采样会自动还原 48 kHz')
          .fontSize(11)
          .fontColor('#BBBBBB')
          .width('100%')
          .margin({ top: 12, bottom: 20 })
      }
      .padding(20)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 音源档位 ----------
  private currentMode(): SourceMode {
    const m: SourceMode | undefined = SOURCE_MODES.find((x: SourceMode) => x.key === this.sourceKey);
    return m ?? SOURCE_MODES[0];
  }

  private sourceHint(): string {
    const m: SourceMode = this.currentMode();
    if (m.key === 'mic' || m.key === 'unproc') {
      return m.label + '：' + m.hint + '。';
    }
    return m.label + '：' + m.hint + '。建议与原声档各录一段对比音质后再决定常用档。';
  }

  private async onSourceChange(key: string): Promise<void> {
    if (key === this.sourceKey) {
      return;
    }
    const wasStreaming: boolean = this.streaming;
    this.sourceKey = key;
    AppStorage.set('pm_sourceKey', key);
    if (!wasStreaming) {
      this.status = '已选择音源：' + this.currentMode().label + '（下次推流生效）';
      return;
    }
    // 推流中切换：只重建采集器，TCP 连接保持（有约半秒声音间断）
    this.status = '正在切换音源…';
    await this.stopCapturerOnly();
    try {
      await this.startCapture();
      this.status = '已连接，推流中…（音源：' + this.currentMode().label + '）';
    } catch (e) {
      this.status = '音源切换失败: ' + this.errMsg(e);
    }
  }

  // ---------- 引擎降噪开关（Phase 2） ----------
  private async onNrToggle(on: boolean): Promise<void> {
    this.nrEnabled = on;
    AppStorage.set('pm_nrEnabled', on);
    if (!this.streaming) {
      this.status = on ? '引擎降噪已开启（下次推流生效）' : '引擎降噪已关闭（下次推流生效）';
      return;
    }
    // 推流中切换：重建 native 管线，约半秒间断
    this.status = on ? '正在启动引擎降噪…' : '正在关闭引擎降噪…';
    if (on) {
      const rc: number = await this.nrInitForStream();
      if (rc !== 0) {
        this.nrEnabled = false;
        AppStorage.set('pm_nrEnabled', false);
        this.status = '引擎降噪启动失败(' + rc + ')，已关闭';
      } else {
        this.status = '引擎降噪已开启，推流中…';
      }
    } else {
      this.nrStop();
      this.status = '引擎降噪已关闭，推流中…';
    }
    this.refreshDspInfo();
  }

  /** 初始化 native 降噪管线；成功返回 0，失败返回负错误码并保持 nrActive=false。 */
  private async nrInitForStream(): Promise<number> {
    this.nrStop(); // 防御：清理可能残留的旧管线
    const rc: number = nr.init();
    if (rc !== 0) {
      this.nrActive = false;
      return rc;
    }
    this.nrActive = true;
    this.nrRsState = { queue: [], pos: 0 };
    this.nrOutFrames = 0;
    // 预热：等引擎产出第一批数据（最多 800ms），避免推流头上一小段没声音
    for (let i = 0; i < 16; i++) {
      const warm: ArrayBuffer = nr.pull();
      if (warm instanceof ArrayBuffer && warm.byteLength > 0) {
        break;
      }
      // 预热期间没有音频回调数据可推——主动喂入一小段静音帮助引擎起转
      this.nrWarmupFeed();
      await this.nrSleep(50);
    }
    return 0;
  }

  private nrSleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 预热期间没有采集回调时，喂一小段静音帮助管线起转。 */
  private nrWarmupFeed(): void {
    // 调用方保证 nrActive；喂 20ms 静音（48kHz×2B）
    const silence: ArrayBuffer = new ArrayBuffer(960);
    nr.push(silence);
  }

  private nrStop(): void {
    if (this.nrActive) {
      nr.release();
    }
    this.nrActive = false;
    this.nrRsState = { queue: [], pos: 0 };
  }

  // ---------- 开始推流 ----------
  private async start(): Promise<void> {
    // 1. 申请麦克风权限
    const ctx = getContext(this) as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const req = await atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE']);
      const granted: boolean = req.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      if (!granted) {
        this.status = '麦克风权限被拒绝，请在 设置 → 应用 里手动开启';
        return;
      }
    } catch (e) {
      this.status = '权限申请失败: ' + this.errMsg(e);
      return;
    }

    // 2. 参数检查
    const ip: string = this.serverIp.trim();
    const port: number = parseInt(this.serverPort) || PORT_DEFAULT;
    if (ip.length === 0) {
      this.status = '请先填写电脑 IP 地址';
      return;
    }

    // 3. 连接电脑
    this.status = '正在连接 ' + ip + ':' + port + ' …';
    try {
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      this.tcp = tcp;
      tcp.on('connect', () => {
        this.connected = true;
        this.status = '已连接，推流中…';
      });
      tcp.on('close', () => {
        this.connected = false;
        if (this.streaming) {
          this.streaming = false;
          this.level = 0;
          this.status = '连接已断开';
        }
      });
      tcp.on('error', (err: BusinessError) => {
        this.connected = false;
        if (this.streaming) {
          this.streaming = false;
          this.level = 0;
          this.status = '连接错误 ' + err.code + ': ' + this.errMsg(err);
        }
      });
      await tcp.connect({ address: { address: ip, port: port }, timeout: 6000 });

      // 4. 启动麦克风采集
      await this.startCapture();
      this.streaming = true;
      this.connected = true;
      this.bytesSent = 0;
      this.startedAt = Date.now();
      this.cbCount = 0;

      // 5. 引擎降噪（Phase 2）：失败则自动回退纯推流，保证功能可用
      if (this.nrEnabled) {
        const rc: number = await this.nrInitForStream();
        if (rc !== 0) {
          this.nrEnabled = false;
          AppStorage.set('pm_nrEnabled', false);
          this.status = '引擎降噪启动失败(' + rc + ')，本次按普通推流';
        }
      }
      this.refreshDspInfo();
      if (this.status.indexOf('引擎降噪启动失败') < 0) {
        this.status = '已连接，推流中…（音源：' + this.currentMode().label
          + (this.nrActive ? ' ｜ 引擎降噪开' : '') + '）';
      }
    } catch (e) {
      this.status = '连接失败: ' + this.errMsg(e) + '（检查 IP、端口和电脑防火墙）';
      this.cleanupSocket();
      this.streaming = false;
    }
  }

  // ---------- 停止推流 ----------
  private async stop(): Promise<void> {
    this.streaming = false;
    this.connected = false;
    this.level = 0;
    await this.stopCapturerOnly();
    this.nrStop();
    this.cleanupSocket();
    this.status = '已停止';
    this.stats = '';
    this.dspInfo = '';
  }

  // ---------- 采集并发送 ----------
  private async startCapture(): Promise<void> {
    const mode: SourceMode = this.currentMode();
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: mode.source,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    try {
      this.capturer = await audio.createAudioCapturer(options);
    } catch (e) {
      if (mode.key === 'mic') {
        throw new Error('创建采集器失败: ' + this.errMsg(e));
      }
      // 该场景音源不被本机支持 → 回退原声
      this.sourceKey = 'mic';
      AppStorage.set('pm_sourceKey', 'mic');
      this.capturer = await audio.createAudioCapturer({
        streamInfo: streamInfo,
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
      });
      this.status = '“' + mode.label + '”不被本机支持，已回退原声';
    }
    this.capturer.on('readData', this.onReadData);
    await this.capturer.start();
    this.detectActualRate();
    this.queryDenoiseState(mode.source);
    this.refreshDspInfo();
  }

  /** 读取系统实际给的采样率：若低于 48kHz，启用重采样把推流拉回 48kHz。 */
  private detectActualRate(): void {
    this.rsEnabled = false;
    this.rsReset();
    const cap: audio.AudioCapturer | null = this.capturer;
    if (cap === null) {
      this.actualRate = SAMPLE_RATE;
      return;
    }
    try {
      const info: audio.AudioStreamInfo = cap.getStreamInfoSync();
      const actual: number = info.samplingRate as number;
      if (actual >= 8000 && actual < SAMPLE_RATE) {
        this.actualRate = actual;
        this.rsEnabled = true;
      } else {
        this.actualRate = actual > 0 ? actual : SAMPLE_RATE;
      }
    } catch (e) {
      this.actualRate = SAMPLE_RATE;
    }
    this.refreshDspInfo();
  }

  /** 查询系统对该音源是否真的开启了智能降噪 / 支持回声消除（诊断用）。 */
  private queryDenoiseState(source: audio.SourceType): void {
    try {
      const sm: audio.AudioStreamManager = audio.getAudioManager().getStreamManager();
      const nr: boolean = sm.isIntelligentNoiseReductionEnabledForCurrentDevice(source);
      const aec: boolean = sm.isAcousticEchoCancelerSupported(source);
      this.dspInfo = '系统智能降噪：' + (nr ? '已开启' : '未开启')
        + ' ｜ 回声消除：' + (aec ? '支持' : '不支持')
        + ' ｜ 实际采集：' + this.actualRate + ' Hz'
        + (this.rsEnabled ? '（已重采样回 48000 推流）' : '');
    } catch (e) {
      this.refreshDspInfo();
    }
  }

  private refreshDspInfo(): void {
    let s: string = '实际采集：' + this.actualRate + ' Hz'
      + (this.rsEnabled ? '（已重采样回 48000 推流）' : '');
    if (this.nrActive) {
      s += ' ｜ 引擎降噪：开（输出 16k 已还原 48k）';
    } else if (this.nrEnabled) {
      s += ' ｜ 引擎降噪：启动失败';
    }
    this.dspInfo = s;
  }

  private async stopCapturerOnly(): Promise<void> {
    if (this.capturer !== null) {
      try {
        this.capturer.off('readData');
      } catch (e) {
        // 忽略
      }
      try {
        await this.capturer.stop();
      } catch (e) {
        // 忽略
      }
      try {
        this.capturer.release();
      } catch (e) {
        // 忽略
      }
      this.capturer = null;
    }
    this.rsReset();
  }

  private onReadData = (buffer: ArrayBuffer): void => {
    if (!this.connected) {
      return;
    }
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength === 0) {
      return;
    }
    const tcp: socket.TCPSocket | null = this.tcp;
    if (tcp === null) {
      return;
    }
    // 第一级：系统若把采集降到 16kHz，先重采样回 48kHz
    let payload: ArrayBuffer = buffer;
    if (this.rsEnabled) {
      const up: ArrayBuffer | null = resampleChunk(payload, this.rsState, this.actualRate);
      if (up === null) {
        return; // 排队中的样本还不够产出一个输出帧，等下一个缓冲
      }
      payload = up;
    }
    // 第二级：引擎降噪——送 native 管线，拉回 16kHz 结果再重采样回 48kHz
    if (this.nrActive) {
      const backlog: number = nr.push(payload);
      if (backlog > 300 && this.cbCount % 20 === 0) {
        this.status = '引擎降噪处理积压 ' + backlog + ' ms（实时性可能下降）';
      }
      const out: ArrayBuffer = nr.pull();
      // 三重防御：坏对象 / 空缓冲都直接丢帧——DataView 构造对未初始化句柄会 SIGSEGV
      if (!(out instanceof ArrayBuffer) || out.byteLength === 0) {
        return; // 管线预热/欠载，本帧不发送
      }
      const up: ArrayBuffer | null = resampleChunk(out, this.nrRsState, NR_RATE);
      if (up === null) {
        return;
      }
      this.nrOutFrames += up.byteLength;
      payload = up;
    }
    try {
      tcp.send({ data: payload }).catch((err: BusinessError) => {
        // 单帧发送失败不打断整体，等 error 事件统一处理
      });
      this.bytesSent += payload.byteLength;
    } catch (e) {
      // 发送异常，忽略本帧
    }
    this.cbCount++;
    if (this.cbCount % 10 === 0) {
      this.level = this.calcLevel(payload);
      this.stats = this.formatStats();
    }
  };

  // ---------- 重采样（线性插值，语音够用；把任意 inRate 拉回 48kHz） ----------
  private rsReset(): void {
    this.rsState = { queue: [], pos: 0 };
  }

  // ---------- 工具 ----------
  private calcLevel(buffer: ArrayBuffer): number {
    const dv: DataView = new DataView(buffer);
    const count: number = Math.min(dv.byteLength, 9600);
    let sum: number = 0;
    let n: number = 0;
    for (let i = 0; i + 1 < count; i += 2) {
      const s: number = dv.getInt16(i, true) / 32768;
      sum += s * s;
      n++;
    }
    if (n === 0) {
      return 0;
    }
    const rms: number = Math.sqrt(sum / n);
    return Math.min(1, rms * 5);
  }

  private formatStats(): string {
    const sec: number = Math.max(1, Math.round((Date.now() - this.startedAt) / 1000));
    const kbps: string = (this.bytesSent / 1024 / sec).toFixed(0);
    return '已发送 ' + (this.bytesSent / 1048576).toFixed(2) + ' MB / ' + sec + ' 秒 / 约 ' + kbps + ' KB/s';
  }

  private cleanupSocket(): void {
    const tcp: socket.TCPSocket | null = this.tcp;
    this.tcp = null;
    this.connected = false;
    if (tcp !== null) {
      try {
        tcp.off('connect');
        tcp.off('close');
        tcp.off('error');
        tcp.off('message');
      } catch (e) {
        // 忽略
      }
      try {
        tcp.close();
      } catch (e) {
        // 忽略
      }
    }
  }

  private errMsg(e: Object): string {
    try {
      const err: BusinessError = e as BusinessError;
      return (err.message ?? '') + ' (' + (err.code ?? '') + ')';
    } catch (_) {
      return String(e);
    }
  }
}
