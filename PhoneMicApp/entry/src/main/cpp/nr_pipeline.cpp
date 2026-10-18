#include "nr_pipeline.h"

#include <chrono>
#include <cstring>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "PhoneMicNr"

#define NR_LOGD(fmt, ...) OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define NR_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace {
constexpr int32_t kRenderRequestBytes = 2048; // 每次 RenderFrame 请求字节（16k×2B≈64ms）
constexpr int kCallbackWaitMs = 50;           // RequestDataCallback 最长等待
} // namespace

// ---------- C 回调（引擎在渲染线程里同步调用） ----------
int32_t RequestDataCallbackTrampoline(OH_AudioNode* audioNode, void* userData, void* audioData,
    int32_t audioDataSize, bool* finished)
{
    (void)audioNode;
    auto* self = static_cast<NoiseReductionPipeline*>(userData);
    if (self == nullptr) {
        *finished = true;
        return 0;
    }
    return self->OnRequestData(audioData, audioDataSize, finished);
}

NoiseReductionPipeline& NoiseReductionPipeline::Get()
{
    static NoiseReductionPipeline inst;
    return inst;
}

int NoiseReductionPipeline::Init()
{
    if (running_.load()) {
        return NR_ERR_ALREADY;
    }

    // 1. 降噪节点支持性检查（202）
    bool supported = false;
    if (OH_AudioSuiteEngine_IsNodeTypeSupported(EFFECT_NODE_TYPE_NOISE_REDUCTION, &supported)
            != AUDIOSUITE_SUCCESS
        || !supported) {
        NR_LOGE("noise reduction node not supported");
        return NR_ERR_NODE_UNSUPPORTED;
    }

    // 2. 引擎
    if (OH_AudioSuiteEngine_Create(&engine_) != AUDIOSUITE_SUCCESS || engine_ == nullptr) {
        NR_LOGE("engine create failed");
        Teardown();
        return NR_ERR_ENGINE_CREATE;
    }

    // 3. 管线（实时模式；API 23+ 支持全部效果节点）
    if (OH_AudioSuiteEngine_CreatePipeline(engine_, &pipeline_, AUDIOSUITE_PIPELINE_REALTIME_MODE)
            != AUDIOSUITE_SUCCESS
        || pipeline_ == nullptr) {
        NR_LOGE("pipeline create failed");
        Teardown();
        return NR_ERR_PIPELINE_CREATE;
    }

    OH_AudioNodeBuilder* builder = nullptr;
    if (OH_AudioSuiteNodeBuilder_Create(&builder) != AUDIOSUITE_SUCCESS || builder == nullptr) {
        NR_LOGE("builder create failed");
        Teardown();
        return NR_ERR_NODE_CREATE;
    }

    // 4. 输入节点：48kHz / 单声道 / S16LE（APP 写入格式）
    OH_AudioFormat inFmt{};
    inFmt.samplingRate = SAMPLE_RATE_48000;
    inFmt.channelLayout = CH_LAYOUT_MONO;
    inFmt.channelCount = 1;
    inFmt.encodingType = AUDIO_ENCODING_TYPE_RAW;
    inFmt.sampleFormat = AUDIO_SAMPLE_S16LE;
    if (OH_AudioSuiteNodeBuilder_SetNodeType(builder, INPUT_NODE_TYPE_DEFAULT) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteNodeBuilder_SetFormat(builder, inFmt) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteNodeBuilder_SetRequestDataCallback(builder, RequestDataCallbackTrampoline, this)
               != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &inputNode_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("input node create failed");
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        Teardown();
        return NR_ERR_NODE_CREATE;
    }

    // 5. 降噪节点（202，无参数）
    if (OH_AudioSuiteNodeBuilder_Reset(builder) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_NOISE_REDUCTION) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &nrNode_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("nr node create failed");
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        Teardown();
        return NR_ERR_NODE_CREATE;
    }

    // 6. 输出节点：16kHz / 单声道 / S16LE（降噪节点输出固定格式）
    OH_AudioFormat outFmt{};
    outFmt.samplingRate = SAMPLE_RATE_16000;
    outFmt.channelLayout = CH_LAYOUT_MONO;
    outFmt.channelCount = 1;
    outFmt.encodingType = AUDIO_ENCODING_TYPE_RAW;
    outFmt.sampleFormat = AUDIO_SAMPLE_S16LE;
    if (OH_AudioSuiteNodeBuilder_Reset(builder) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteNodeBuilder_SetNodeType(builder, OUTPUT_NODE_TYPE_DEFAULT) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteNodeBuilder_SetFormat(builder, outFmt) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &outputNode_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("output node create failed");
        OH_AudioSuiteNodeBuilder_Destroy(builder);
        Teardown();
        return NR_ERR_NODE_CREATE;
    }
    OH_AudioSuiteNodeBuilder_Destroy(builder);

    // 7. 连接：输入 → 降噪 → 输出
    if (OH_AudioSuiteEngine_ConnectNodes(inputNode_, nrNode_) != AUDIOSUITE_SUCCESS
        || OH_AudioSuiteEngine_ConnectNodes(nrNode_, outputNode_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("connect nodes failed");
        Teardown();
        return NR_ERR_CONNECT;
    }

    // 8. 启动
    if (OH_AudioSuiteEngine_StartPipeline(pipeline_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("start pipeline failed");
        Teardown();
        return NR_ERR_START;
    }

    inRing_.clear();
    outRing_.clear();
    stopping_.store(false);
    running_.store(true);
    try {
        renderThread_ = std::thread(&NoiseReductionPipeline::RenderLoop, this);
    } catch (const std::exception& e) {
        NR_LOGE("render thread create failed: %{public}s", e.what());
        running_.store(false);
        Teardown();
        return NR_ERR_THREAD;
    }
    NR_LOGD("pipeline init ok");
    return NR_OK;
}

int32_t NoiseReductionPipeline::OnRequestData(void* audioData, int32_t audioDataSize, bool* finished)
{
    // 等到有足够数据 / 停止 / 超时
    std::unique_lock<std::mutex> lk(cvMutex_);
    dataCv_.wait_for(lk, std::chrono::milliseconds(kCallbackWaitMs), [this] {
        return stopping_.load() || inRing_.available() >= static_cast<size_t>(2048);
    });
    if (stopping_.load()) {
        *finished = true;
        return 0;
    }
    lk.unlock();
    return static_cast<int32_t>(inRing_.read(static_cast<uint8_t*>(audioData),
        static_cast<size_t>(audioDataSize)));
}

void NoiseReductionPipeline::RenderLoop()
{
    std::vector<uint8_t> buf(kRenderRequestBytes);
    int idleSpins = 0;
    while (!stopping_.load()) {
        int32_t resp = 0;
        bool finished = false;
        OH_AudioSuite_Result r = OH_AudioSuiteEngine_RenderFrame(pipeline_, buf.data(),
            kRenderRequestBytes, &resp, &finished);
        if (r != AUDIOSUITE_SUCCESS) {
            NR_LOGE("RenderFrame error %{public}d", static_cast<int>(r));
            break;
        }
        if (resp > 0) {
            outRing_.write(buf.data(), static_cast<size_t>(resp));
            idleSpins = 0;
        } else {
            // 上游还没数据：让出 CPU，避免忙等
            if (++idleSpins > 4) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        if (finished) {
            break;
        }
    }
    NR_LOGD("render loop exit");
}

void NoiseReductionPipeline::Release()
{
    if (!running_.exchange(false)) {
        // 即便没在运行，也清理半初始化状态
        if (engine_ != nullptr) {
            Teardown();
        }
        return;
    }
    stopping_.store(true);
    dataCv_.notify_all();
    if (renderThread_.joinable()) {
        renderThread_.join();
    }
    Teardown();
    NR_LOGD("pipeline released");
}

void NoiseReductionPipeline::Teardown()
{
    if (pipeline_ != nullptr) {
        OH_AudioSuiteEngine_StopPipeline(pipeline_);
    }
    if (nrNode_ != nullptr) {
        OH_AudioSuiteEngine_DestroyNode(nrNode_);
        nrNode_ = nullptr;
    }
    if (outputNode_ != nullptr) {
        OH_AudioSuiteEngine_DestroyNode(outputNode_);
        outputNode_ = nullptr;
    }
    if (inputNode_ != nullptr) {
        OH_AudioSuiteEngine_DestroyNode(inputNode_);
        inputNode_ = nullptr;
    }
    if (pipeline_ != nullptr) {
        OH_AudioSuiteEngine_DestroyPipeline(pipeline_);
        pipeline_ = nullptr;
    }
    if (engine_ != nullptr) {
        OH_AudioSuiteEngine_Destroy(engine_);
        engine_ = nullptr;
    }
    stopping_.store(false);
    inRing_.clear();
    outRing_.clear();
}

int NoiseReductionPipeline::Push(const uint8_t* data, size_t len)
{
    if (!running_.load()) {
        return -1;
    }
    inRing_.write(data, len);
    dataCv_.notify_all();
    // 48kHz×2B/ms = 96 B/ms
    return static_cast<int>(inRing_.available() / 96);
}

size_t NoiseReductionPipeline::Pull(uint8_t* out, size_t cap)
{
    if (!running_.load()) {
        return 0;
    }
    return outRing_.read(out, cap);
}

int NoiseReductionPipeline::InputBacklogMs() const
{
    return static_cast<int>(inRing_.available() / 96);
}

int NoiseReductionPipeline::OutputBacklogMs() const
{
    return static_cast<int>(outRing_.available() / 32); // 16kHz×2B = 32 B/ms
}

uint64_t NoiseReductionPipeline::OverwrittenBytes() const
{
    return inRing_.overwritten();
}
