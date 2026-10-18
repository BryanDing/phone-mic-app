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

// ---------- 人声增强预设（OHAudioSuite 205 人声美化节点，4 预设全量） ----------
// 与引擎降噪（202 节点）互斥：两者格式契约不同（VB 输出 48k 立体声/native 已下混
// 单声道直推；NR 输出 16k 单声道需重采样回 48k），且同时开启两个引擎管线会互相
// 抢占采集数据。开关层面互斥，UI 上开启一个会自动关掉另一个。
interface VbPreset {
  type: number;   // 对应 OH_AudioSuiteEngine_SetVoiceBeautifierType 的 type
  label: string;
  hint: string;
}

const VB_TYPES: VbPreset[] = [
  { type: 1, label: '清澈', hint: 'CLEAR：突出人声清晰度，口播/网课首选' },
  { type: 2, label: '剧院', hint: 'THEATRE：增加空间感，适合有场景感的讲述' },
  { type: 3, label: 'CD', hint: 'CD：整体更均衡耐听，微暖' },
  { type: 4, label: '录音棚', hint: 'RECORDING_STUDIO：录音棚级人声厚度' },
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
  @State vbEnabled: boolean = AppStorage.get<boolean>('pm_vbEnabled') ?? false;
  @State vbType: number = AppStorage.get<number>('pm_vbType') ?? 1;
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

  // 引擎处理（Phase 2）：降噪/人声增强共用一条 native 管线，互斥使用
  private nrActive: boolean = false;   // 本次推流中 nr.init() 是否成功
  private nrMode: number = 0;          // 本次实际链路：0=引擎降噪 1=人声增强
  private nrRsState: RsState = { queue: [], pos: 0 };  // 仅降噪模式用（16k→48k）
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
            Text('系统级 AI 降噪算法，可叠加在任意音源档位上；引擎固定 16kHz 输出，APP 自动还原 48kHz 推流。与"系统3A"叠加官方不建议，仅作对比测试。与下方"人声增强"互斥。')
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

        // Phase 2：人声增强（OHAudioSuite 205 人声美化节点）
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text('人声增强（Phase 2 实验）')
              .fontSize(14)
              .fontColor('#333333')
              .width('100%')
            Text('人声美化引擎，48kHz 全带输出、不做重采样（音质优先）。与"引擎降噪"互斥：开启会自动关掉降噪。建议与原声档对比后选用。')
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
          }
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.vbEnabled })
            .id('vbToggle')
            .onChange((on: boolean) => {
              this.onVbToggle(on);
            })
        }
        .width('100%')
        .margin({ top: 10 })

        // 人声增强预设（未开启时置灰）
        Text('人声增强预设')
          .fontSize(14)
          .fontColor('#333333')
          .width('100%')
          .margin({ top: 8 })
          .opacity(this.vbEnabled ? 1 : 0.4)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(VB_TYPES, (t: VbPreset) => {
            Button(t.label)
              .fontSize(13)
              .height(34)
              .padding({ left: 12, right: 12 })
              .type(ButtonType.Capsule)
              .margin({ right: 8, bottom: 8 })
              .backgroundColor(this.vbType === t.type ? '#5B5BD6' : '#EFEFEF')
              .fontColor(this.vbType === t.type ? '#FFFFFF' : '#333333')
              .enabled(this.vbEnabled)
              .onClick(() => {
                this.onVbTypeChange(t.type);
              })
          }, (t: VbPreset) => String(t.type))
        }
        .width('100%')
        Text(this.vbHint())
          .fontSize(11)
          .fontColor('#999999')
          .width('100%')

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

  // ---------- 引擎降噪开关（Phase 2，与人声增强互斥） ----------
  private async onNrToggle(on: boolean): Promise<void> {
    this.nrEnabled = on;
    AppStorage.set('pm_nrEnabled', on);
    if (on && this.vbEnabled) {
      // 互斥：开引擎降噪则关人声增强
      this.vbEnabled = false;
      AppStorage.set('pm_vbEnabled', false);
    }
    if (!this.streaming) {
      this.status = on ? '引擎降噪已开启（下次推流生效）' : '引擎降噪已关闭（下次推流生效）';
      return;
    }
    // 推流中切换：重建 native 管线，约半秒间断
    this.status = on ? '正在启动引擎降噪…' : '正在关闭引擎降噪…';
    if (on) {
      const rc: number = await this.nrInitForStream(0, this.vbType);
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

  // ---------- 人声增强开关（Phase 2，与引擎降噪互斥） ----------
  private async onVbToggle(on: boolean): Promise<void> {
    this.vbEnabled = on;
    AppStorage.set('pm_vbEnabled', on);
    if (on && this.nrEnabled) {
      // 互斥：开人声增强则关引擎降噪
      this.nrEnabled = false;
      AppStorage.set('pm_nrEnabled', false);
    }
    if (!this.streaming) {
      this.status = on ? '人声增强已开启（下次推流生效）' : '人声增强已关闭（下次推流生效）';
      return;
    }
    this.status = on ? '正在启动人声增强…' : '正在关闭人声增强…';
    if (on) {
      const rc: number = await this.nrInitForStream(1, this.vbType);
      if (rc !== 0) {
        this.vbEnabled = false;
        AppStorage.set('pm_vbEnabled', false);
        this.status = '人声增强启动失败(' + rc + ')，已关闭';
      } else {
        this.status = '人声增强已开启（' + this.vbLabel() + '），推流中…';
      }
    } else {
      this.nrStop();
      this.status = '人声增强已关闭，推流中…';
    }
    this.refreshDspInfo();
  }

  /** 人声增强预设切换：未开启只记忆；推流中优先热改，失败回落重建管线。 */
  private async onVbTypeChange(t: number): Promise<void> {
    if (t === this.vbType) {
      return;
    }
    this.vbType = t;
    AppStorage.set('pm_vbType', t);
    if (!this.vbEnabled) {
      this.status = '已选择人声预设：' + this.vbLabel() + '（开启人声增强后生效）';
      return;
    }
    if (!this.streaming || !this.nrActive || this.nrMode !== 1) {
      this.status = '人声预设：' + this.vbLabel() + '（下次推流生效）';
      return;
    }
    // 推流中 + VB 运行中：先热改（无间断），失败回落整条重建
    const rc: number = nr.setVbType(t);
    if (rc === 0) {
      this.status = '人声预设已切换：' + this.vbLabel();
    } else {
      const rc2: number = await this.nrInitForStream(1, t);
      this.status = rc2 === 0
        ? '人声预设已切换：' + this.vbLabel() + '（热改失败已重建管线）'
        : '人声预设切换失败(' + rc + '/' + rc2 + ')';
    }
    this.refreshDspInfo();
  }

  private vbLabel(): string {
    const t: VbPreset | undefined = VB_TYPES.find((x: VbPreset) => x.type === this.vbType);
    return t ? t.label : '清澈';
  }

  private vbHint(): string {
    const t: VbPreset | undefined = VB_TYPES.find((x: VbPreset) => x.type === this.vbType);
    const hint: string = t ? t.hint : '';
    return this.vbEnabled ? hint + '（推流中点击预设即时切换）' : hint + '（开启人声增强后可切换）';
  }

  /** 初始化 native 引擎管线；成功返回 0，失败返回负错误码并保持 nrActive=false。
   *  mode: 0=引擎降噪（输出16k，需重采样回48k） 1=人声增强（输出48k 直推）。 */
  private async nrInitForStream(mode: number, vbType: number): Promise<number> {
    this.nrStop(); // 防御：清理可能残留的旧管线
    const rc: number = nr.init(mode, vbType);
    if (rc !== 0) {
      this.nrActive = false;
      return rc;
    }
    this.nrActive = true;
    this.nrMode = mode;
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

      // 5. 引擎处理（Phase 2）：引擎降噪 / 人声增强（互斥）；失败自动回退纯推流
      if (this.nrEnabled || this.vbEnabled) {
        const rc: number = await this.nrInitForStream(this.vbEnabled ? 1 : 0, this.vbType);
        if (rc !== 0) {
          if (this.vbEnabled) {
            this.vbEnabled = false;
            AppStorage.set('pm_vbEnabled', false);
            this.status = '人声增强启动失败(' + rc + ')，本次按普通推流';
          } else {
            this.nrEnabled = false;
            AppStorage.set('pm_nrEnabled', false);
            this.status = '引擎降噪启动失败(' + rc + ')，本次按普通推流';
          }
        }
      }
      this.refreshDspInfo();
      if (this.status.indexOf('启动失败') < 0) {
        this.status = '已连接，推流中…（音源：' + this.currentMode().label
          + (this.nrActive
            ? (this.nrMode === 1 ? ' ｜ 人声增强：' + this.vbLabel() : ' ｜ 引擎降噪开')
            : '') + '）';
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
    if (this.nrActive && this.nrMode === 1) {
      s += ' ｜ 人声增强：开（' + this.vbLabel() + '，48k 直推）';
    } else if (this.nrActive) {
      s += ' ｜ 引擎降噪：开（输出 16k 已还原 48k）';
    } else if (this.nrEnabled) {
      s += ' ｜ 引擎降噪：启动失败';
    } else if (this.vbEnabled) {
      s += ' ｜ 人声增强：启动失败';
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
    // 第二级：引擎处理——降噪（16k 输出需重采样）或人声增强（48k 直推）
    if (this.nrActive) {
      const backlog: number = nr.push(payload);
      if (backlog > 300 && this.cbCount % 20 === 0) {
        this.status = '引擎处理积压 ' + backlog + ' ms（实时性可能下降）';
      }
      const out: ArrayBuffer = nr.pull();
      // 三重防御：坏对象 / 空缓冲都直接丢帧——DataView 构造对未初始化句柄会 SIGSEGV
      if (!(out instanceof ArrayBuffer) || out.byteLength === 0) {
        return; // 管线预热/欠载，本帧不发送
      }
      if (this.nrMode === 1) {
        // 人声增强：native 已输出 48kHz 单声道（立体声下混），直接推流不走重采样
        this.nrOutFrames += out.byteLength;
        payload = out;
      } else {
        const up: ArrayBuffer | null = resampleChunk(out, this.nrRsState, NR_RATE);
        if (up === null) {
          return;
        }
        this.nrOutFrames += up.byteLength;
        payload = up;
      }
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
