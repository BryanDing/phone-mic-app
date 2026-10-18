// ArkTS 侧类型声明：import nr from 'libentry_nr.so'
/** 创建并启动引擎管线。mode 0=引擎降噪(输出16k mono) 1=人声增强(输出48k mono)；
 *  vbType 1~4 仅人声增强有意义（1清澈 2剧院 3CD 4录音棚）。返回 0 成功，负数为错误码。 */
export const init: (mode?: number, vbType?: number) => number;
/** 热改人声美化预设（仅人声增强模式运行中有效）；成功返回 0。 */
export const setVbType: (vbType: number) => number;
export const release: () => void;
/** 送入 48kHz 单声道 S16LE PCM；返回输入队列积压毫秒数（负数表示未运行） */
export const push: (pcm: ArrayBuffer) => number;
/** 拉取已处理音频：降噪模式为 16kHz 单声道，人声增强模式为 48kHz 单声道；可能为空 */
export const pull: () => ArrayBuffer;
/** 诊断信息字符串 */
export const info: () => string;
