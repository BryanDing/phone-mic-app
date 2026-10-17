import { audio } from '@kit.AudioKit';
import { socket } from '@kit.NetworkKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'PhoneMic';
const PORT_DEFAULT: number = 5000;

@Entry
@Component
struct Index {
  @State serverIp: string = AppStorage.get<string>('pm_serverIp') ?? '192.168.1.100';
  @State serverPort: string = AppStorage.get<string>('pm_serverPort') ?? '5000';
  @State status: string = '未开始';
  @State streaming: boolean = false;
  @State level: number = 0;
  @State stats: string = '';

  private capturer: audio.AudioCapturer | null = null;
  private tcp: socket.TCPSocket | null = null;
  private connected: boolean = false;
  private bytesSent: number = 0;
  private startedAt: number = 0;
  private cbCount: number = 0;

  build() {
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
        .type(InputType.Number)
        .height(46)
        .onChange((v: string) => {
          this.serverPort = v;
          AppStorage.set('pm_serverPort', v);
        })

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

      Text('推流格式：48 kHz / 单声道 / 16 bit PCM（不压缩）')
        .fontSize(11)
        .fontColor('#BBBBBB')
        .width('100%')
        .margin({ top: 12 })
    }
    .padding(20)
    .width('100%')
    .height('100%')
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
      this.status = '已连接，推流中…';
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
    this.cleanupSocket();
    this.status = '已停止';
    this.stats = '';
  }

  // ---------- 采集并发送 ----------
  private async startCapture(): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    this.capturer = await audio.createAudioCapturer(options);
    this.capturer.on('readData', this.onReadData);
    await this.capturer.start();
  }

  private onReadData = (buffer: ArrayBuffer): void => {
    if (!this.connected) {
      return;
    }
    const tcp: socket.TCPSocket | null = this.tcp;
    if (tcp === null) {
      return;
    }
    try {
      tcp.send({ data: buffer }).catch((err: BusinessError) => {
        // 单帧发送失败不打断整体，等 error 事件统一处理
      });
      this.bytesSent += buffer.byteLength;
    } catch (e) {
      // 发送异常，忽略本帧
    }
    this.cbCount++;
    if (this.cbCount % 10 === 0) {
      this.level = this.calcLevel(buffer);
      this.stats = this.formatStats();
    }
  };

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
