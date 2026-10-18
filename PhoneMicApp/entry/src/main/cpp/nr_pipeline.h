/*
 * OHAudioSuite 降噪管线封装。
 * 拓扑：输入节点(APP供数 48k/mono/S16LE) → 降噪节点(202) → 输出节点(16k/mono/S16LE)
 * 驱动：native 渲染线程循环 RenderFrame()；输入经 RequestDataCallback 从
 *       环形队列取，输出写另一个环形队列，ArkTS 侧 pull() 取走。
 * 模式：必须 EDIT_MODE（离线编辑）。官方文档明确"实时预览场景仅支持均衡器
 *       节点"，降噪节点(202)在 REALTIME_MODE 下真机实测输入回调不被调用、
 *       RenderFrame 持续返回系统错误。EDIT_MODE 的驱动方式恰是"App 循环调
 *       RenderFrame + 回调按需供数"，与本推流架构一致。
 * 关键契约：EDIT_MODE 输入节点要求每次回调填满其 1920B 内部缓存，返回短包/0
 *       会被当作输入流结束（EOS）且粘连——引擎此后不再回调、RenderFrame 永久
 *       失败。故 OnRequestData 阻塞等满一帧（天然背压，管线实时化），
 *       超时才补静音；连续断流 10s 才结束管线。
 */
#ifndef PHONEMIC_NR_PIPELINE_H
#define PHONEMIC_NR_PIPELINE_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>

#include "ring_buffer.h"
#include "ohaudiosuite/native_audio_suite_engine.h"

// init 返回码（NAPI 层会再转成 ArkTS 可见的负数错误码）
enum {
    NR_OK = 0,
    NR_ERR_ENGINE_CREATE = -1,
    NR_ERR_NODE_UNSUPPORTED = -2,
    NR_ERR_PIPELINE_CREATE = -3,
    NR_ERR_NODE_CREATE = -4,
    NR_ERR_CONNECT = -5,
    NR_ERR_START = -6,
    NR_ERR_ALREADY = -7,
    NR_ERR_THREAD = -8,
};

class NoiseReductionPipeline {
public:
    static NoiseReductionPipeline& Get();

    /** 创建引擎+管线+节点并启动。成功返回 NR_OK。 */
    int Init();

    /** 停止并销毁全部资源，可再次 Init。 */
    void Release();

    /** 送入 48kHz 单声道 S16LE PCM；返回当前输入队列积压毫秒数（>300 表示处理跟不上）。 */
    int Push(const uint8_t* data, size_t len);

    /** 拉取已降噪音频（16kHz 单声道 S16LE）；返回实际字节数。 */
    size_t Pull(uint8_t* out, size_t cap);

    /** 输入/输出队列积压毫秒（诊断）。 */
    int InputBacklogMs() const;
    int OutputBacklogMs() const;

    /** 累计被覆盖丢弃的输入字节（背压诊断）。 */
    uint64_t OverwrittenBytes() const;

    bool IsRunning() const { return running_.load(); }

private:
    NoiseReductionPipeline() = default;
    ~NoiseReductionPipeline() { Release(); }
    NoiseReductionPipeline(const NoiseReductionPipeline&) = delete;
    NoiseReductionPipeline& operator=(const NoiseReductionPipeline&) = delete;

    int32_t OnRequestData(void* audioData, int32_t audioDataSize, bool* finished);
    void RenderLoop();
    void Teardown();

    // C 回调 trampoline 需要访问私有成员
    friend int32_t RequestDataCallbackTrampoline(OH_AudioNode*, void*, void*, int32_t, bool*);

    OH_AudioSuiteEngine* engine_ = nullptr;
    OH_AudioSuitePipeline* pipeline_ = nullptr;
    OH_AudioNode* inputNode_ = nullptr;
    OH_AudioNode* nrNode_ = nullptr;
    OH_AudioNode* outputNode_ = nullptr;

    std::thread renderThread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stopping_{false};

    // RequestDataCallback 的等待：队列够一帧（引擎单次请求 1920B）才返回；
    // stopping_ 或超时（补静音）则放行。持本锁写入+通知，配对无丢唤醒。
    std::mutex cvMutex_;
    std::condition_variable dataCv_;

    // 断流保护：回调连续补静音的帧数；达到 kMaxStarveFrames 判定采集死亡，
    // 回调置 finished 结束管线。inputEnded_ 供渲染循环区分退出原因。
    std::atomic<int> starveFrames_{0};
    std::atomic<bool> inputEnded_{false};

    RingBuffer inRing_{48000 * 2};   // 48kHz mono S16LE × 1s
    RingBuffer outRing_{16000 * 2};  // 16kHz mono S16LE × 1s
};

#endif // PHONEMIC_NR_PIPELINE_H
