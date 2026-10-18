// ArkTS 侧类型声明：import nr from 'libentry_nr.so'
export const init: () => number;
export const release: () => void;
/** 送入 48kHz 单声道 S16LE PCM；返回输入队列积压毫秒数（负数表示未运行） */
export const push: (pcm: ArrayBuffer) => number;
/** 拉取已降噪音频（16kHz 单声道 S16LE），可能为空 */
export const pull: () => ArrayBuffer;
/** 诊断信息字符串 */
export const info: () => string;
