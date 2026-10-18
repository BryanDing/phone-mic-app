#include "nr_pipeline.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "PhoneMicNr"

#define NR_LOGD(fmt, ...) OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define NR_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define NR_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace {
constexpr int32_t kRenderRequestBytes = 2048; // 每次 RenderFrame 请求字节（16k×2B≈64ms）
// 输入节点单次请求 1920B（48k×2B×20ms，见引擎日志 InitCacheBuffer
// cachedBufferSize:1920, singleRequestSize_:1920）；不足一帧不调 RenderFrame，
// 否则引擎走欠载错误路径（AUDIOSUITE_ERROR_SYSTEM）
constexpr size_t kMinInputBytes = 1920;
// 启动前预灌静音毫秒数：覆盖渲染线程首帧到采集回调落地的窗口
constexpr size_t kPrefillMs = 100;
// 连续 RenderFrame 错误上限（每次间隔 2ms，200 次≈0.4s 才退出）
constexpr int kMaxConsecutiveErrors = 200;
// 输入回调单次等待上限：等不满一帧就补静音顶住（采集断流时保命）
constexpr int kRequestWaitMs = 500;
// 连续断流帧数上限（20×500ms≈10s）：采集彻底死亡才结束管线，
// 避免对着死采集无限输出静音；中途恢复则计数清零
constexpr int kMaxStarveFrames = 20;
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

int NoiseReductionPipeline::Init(int mode, int vbType)
{
    if (running_.load()) {
        return NR_ERR_ALREADY;
    }
    // 模式参数归一化（非法值回落默认，绝不因此失败）
    mode_ = (mode == NR_MODE_VOICE_BEAUTIFIER) ? NR_MODE_VOICE_BEAUTIFIER : NR_MODE_NOISE_REDUCTION;
    vbType_ = (vbType >= 1 && vbType <= 4) ? vbType : 1;
    inputChannels_ = (mode_ == NR_MODE_VOICE_BEAUTIFIER) ? 2 : 1;
    outRate_ = (mode_ == NR_MODE_VOICE_BEAUTIFIER) ? 48000 : 16000;
    NR_LOGD("init begin: mode=%{public}d vbType=%{public}d inCh=%{public}d outRate=%{public}d",
        mode_, vbType_, inputChannels_, outRate_);

    // 1. 效果节点支持性检查（按模式：降噪 202 / 人声美化 205）
    const OH_AudioNode_Type wantNode = (mode_ == NR_MODE_VOICE_BEAUTIFIER)
        ? EFFECT_NODE_TYPE_VOICE_BEAUTIFIER : EFFECT_NODE_TYPE_NOISE_REDUCTION;
    bool supported = false;
    if (OH_AudioSuiteEngine_IsNodeTypeSupported(wantNode, &supported) != AUDIOSUITE_SUCCESS
            || !supported) {
        NR_LOGE("node type %{public}d not supported", wantNode);
        return NR_ERR_NODE_UNSUPPORTED;
    }
    NR_LOGD("step1: node type %{public}d supported", wantNode);

    // 1.5 （原 VB→NR / NR→VB 直连串联探测已移除）
    // 2026-10-18 真机实证：VB(205) 直连 NR(202) 时引擎内部
    // VoiceMorphing algo apply 失败(-94) → SuitePipeline 线程 SIGSEGV(11)，
    // 整个进程被杀（用户日志：AudioSuiteVoiceMorphingAlgoInte Apply failed
    // → AudioSuitePorcessNode SignalProcess Apply failed → DFX signo 11）。
    // 结论：叠加不可行——与格式契约分析一致（VB 出 48k 立体声 /
    // NR 期望 48k 单声道，ConnectNodes 无格式协商承诺）。产品层面
    // 两效果互斥；若未来要做叠加，需经 native_audio_converter.h
    // (API 26) 做声道/采样率中转，且必须先在小流量实验包验证。

    // 2. 引擎
    if (OH_AudioSuiteEngine_Create(&engine_) != AUDIOSUITE_SUCCESS || engine_ == nullptr) {
        NR_LOGE("engine create failed");
        Teardown();
        return NR_ERR_ENGINE_CREATE;
    }
    NR_LOGD("step2: engine created");

    // 3. 管线。必须用 EDIT_MODE（离线编辑模式）：
    // 官方设备开发文档明确"实时预览场景仅支持均衡器节点"，降噪节点(202)
    // 在 REALTIME_MODE 下实测输入回调不被调用、RenderFrame 持续报系统错误
    // （真机日志：GeneratePushBuffer cachedBuffer not data → ret=-62980096）。
    // EDIT_MODE 的驱动方式恰是"App 循环调 RenderFrame + 回调按需供数"，
    // 与我们的推流架构一致，也是官方文档中唯一支持降噪节点的模式。
    if (OH_AudioSuiteEngine_CreatePipeline(engine_, &pipeline_, AUDIOSUITE_PIPELINE_EDIT_MODE)
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

    // 4. 输入节点。
    // NR 模式：48k 单声道（降噪节点内部重采样到 16k）。
    // VB 模式：48k 立体声——人声美化节点原生格式即 48k 立体声，
    // 采集单声道在 OnRequestData 里复制成立体声喂入，不依赖引擎的格式自适应。
    OH_AudioFormat inFmt{};
    inFmt.samplingRate = SAMPLE_RATE_48000;
    inFmt.channelLayout = (inputChannels_ == 2) ? CH_LAYOUT_STEREO : CH_LAYOUT_MONO;
    inFmt.channelCount = inputChannels_;
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
    NR_LOGD("step4: input node created (%{public}d ch)", inputChannels_);

    if (mode_ == NR_MODE_VOICE_BEAUTIFIER) {
        // 5. 人声美化节点（205，无格式参数；建后设预设）
        if (OH_AudioSuiteNodeBuilder_Reset(builder) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_VOICE_BEAUTIFIER) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &vbNode_) != AUDIOSUITE_SUCCESS) {
            NR_LOGE("vb node create failed");
            OH_AudioSuiteNodeBuilder_Destroy(builder);
            Teardown();
            return NR_ERR_NODE_CREATE;
        }
        if (OH_AudioSuiteEngine_SetVoiceBeautifierType(vbNode_,
                static_cast<OH_VoiceBeautifierType>(vbType_)) != AUDIOSUITE_SUCCESS) {
            NR_LOGE("set voice beautifier type %{public}d failed", vbType_);
            OH_AudioSuiteNodeBuilder_Destroy(builder);
            Teardown();
            return NR_ERR_NODE_CREATE;
        }
        NR_LOGD("step5: vb node created, type=%{public}d", vbType_);

        // 6. 输出节点：48kHz / 立体声 / S16LE（人声美化输出原生格式，
        // RenderLoop 里再下混单声道写入输出环）
        OH_AudioFormat outFmt{};
        outFmt.samplingRate = SAMPLE_RATE_48000;
        outFmt.channelLayout = CH_LAYOUT_STEREO;
        outFmt.channelCount = 2;
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
        NR_LOGD("step6: output node created (48k stereo)");

        // 7. 连接：输入 → 人声美化 → 输出
        if (OH_AudioSuiteEngine_ConnectNodes(inputNode_, vbNode_) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteEngine_ConnectNodes(vbNode_, outputNode_) != AUDIOSUITE_SUCCESS) {
            NR_LOGE("connect nodes failed");
            Teardown();
            return NR_ERR_CONNECT;
        }
    } else {
        // 5. 降噪节点（202，无参数）
        if (OH_AudioSuiteNodeBuilder_Reset(builder) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteNodeBuilder_SetNodeType(builder, EFFECT_NODE_TYPE_NOISE_REDUCTION) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteEngine_CreateNode(pipeline_, builder, &nrNode_) != AUDIOSUITE_SUCCESS) {
            NR_LOGE("nr node create failed");
            OH_AudioSuiteNodeBuilder_Destroy(builder);
            Teardown();
            return NR_ERR_NODE_CREATE;
        }

        NR_LOGD("step5: nr node created");

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
        NR_LOGD("step6: output node created");

        // 7. 连接：输入 → 降噪 → 输出
        if (OH_AudioSuiteEngine_ConnectNodes(inputNode_, nrNode_) != AUDIOSUITE_SUCCESS
            || OH_AudioSuiteEngine_ConnectNodes(nrNode_, outputNode_) != AUDIOSUITE_SUCCESS) {
            NR_LOGE("connect nodes failed");
            Teardown();
            return NR_ERR_CONNECT;
        }
    }
    NR_LOGD("step7: nodes connected");

    // 清理上一次运行的残留（必须在预灌之前）
    inRing_.clear();
    outRing_.clear();

    // 7.5 预热：先往输入环灌一段静音再启动管线。
    // 引擎在输入无数据时会让 RenderFrame 返回 AUDIOSUITE_ERROR_SYSTEM，
    // 裸启动时渲染线程第一帧必然欠载（采集数据还没推过来），直接走错误路径。
    {
        const size_t prefillBytes = 48000 * 2 * kPrefillMs / 1000;
        std::vector<uint8_t> silence(prefillBytes, 0);
        inRing_.write(silence.data(), silence.size());
        NR_LOGD("step7.5: input ring prefilled %{public}u bytes",
            static_cast<unsigned>(prefillBytes));
    }

    // 8. 启动
    if (OH_AudioSuiteEngine_StartPipeline(pipeline_) != AUDIOSUITE_SUCCESS) {
        NR_LOGE("start pipeline failed");
        Teardown();
        return NR_ERR_START;
    }
    NR_LOGD("step8: pipeline started");

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
    static std::atomic<uint64_t> s_cbCount{0};
    uint64_t n = ++s_cbCount;

    if (stopping_.load()) {
        *finished = true;
        return 0;
    }
    const size_t need = static_cast<size_t>(audioDataSize);
    if (audioData == nullptr || need == 0) {
        // 引擎不会这么调（singleRequestSize_=1920），纯防御
        return 0;
    }
    // 环形队列里始终是单声道（采集侧约定）；VB 模式输入节点是立体声，
    // 引擎要的字节数除以声道数才是需要等待的单声道字节数。
    const size_t needMono = need / static_cast<size_t>(inputChannels_);
    if (needMono == 0) {
        return 0;
    }

    // 【核心契约】EDIT_MODE 输入节点要求每次回调填满其内部缓存。
    // 返回不足一帧（短包或 0）会被引擎当作输入流结束（EOS）且粘连：
    // 真机日志实证——短包后 GeneratePushBuffer cachedBuffer not data0 →
    // RenderFrame ret=-62980096（错误 3），且引擎此后再不调用本回调，
    // 即使环形队列里明明有数据。因此这里必须阻塞等到凑满一帧：
    // 阻塞点是天然背压，把管线节流到实时速度（采集 96B/ms vs
    // 引擎不设限消耗 1920B/2ms≈13 倍实时）。无死锁风险：采集侧
    // （AudioCapturer 线程 → push → notify）与引擎线程完全独立。
    std::unique_lock<std::mutex> lk(cvMutex_);
    dataCv_.wait_for(lk, std::chrono::milliseconds(kRequestWaitMs), [&] {
        return stopping_.load() || inRing_.available() >= needMono;
    });
    if (stopping_.load()) {
        *finished = true;
        return 0;
    }

    size_t got = 0; // 实际填入 audioData 的字节数（含声道扩展）
    size_t avail = inRing_.available();
    if (avail >= needMono) {
        got = FillFrame(audioData, need, needMono, /*allowPartial=*/false);
        starveFrames_.store(0);
    } else {
        // 超时仍凑不满：采集侧断流（权限被收回/音频焦点被抢/退后台）。
        // 不能返回短包（=EOS），补静音顶住管线活命，累计断流到上限才结束。
        int starve = starveFrames_.fetch_add(1) + 1;
        if (starve >= kMaxStarveFrames) {
            NR_LOGE("input starved %{public}d frames, mark input finished",
                kMaxStarveFrames);
            inputEnded_.store(true);
            *finished = true;
            return 0;
        }
        got = FillFrame(audioData, need, needMono, /*allowPartial=*/true);
        if (n <= 100 || n % 500 == 0) {
            NR_LOGW("OnRequestData #%{public}llu: starved, filled %{public}u bytes silence (starve=%{public}d)",
                static_cast<unsigned long long>(n), static_cast<unsigned>(got), starve);
        }
    }
    // 埋点：前 20 次 + 每 200 次打一条，确认回调真的被引擎调用（排查管线不动的关键证据）
    if (n <= 20 || n % 200 == 0) {
        NR_LOGD("OnRequestData #%{public}llu: req=%{public}d avail=%{public}u ret=%{public}d",
            static_cast<unsigned long long>(n), audioDataSize,
            static_cast<unsigned>(avail), static_cast<int>(got));
    }
    return static_cast<int32_t>(got);
}

size_t NoiseReductionPipeline::FillFrame(void* audioData, size_t need, size_t needMono, bool allowPartial)
{
    // 把单声道数据填成引擎要的满帧：单声道模式直接读；立体声模式读入
    // 暂存区后按 L=R 复制。allowPartial=false 时调用方已保证 avail>=needMono；
    // allowPartial=true 时吃下现有全部，剩余补零（断流保命路径）。
    if (inputChannels_ <= 1) {
        size_t gotMono = inRing_.read(static_cast<uint8_t*>(audioData),
            allowPartial ? inRing_.available() : needMono);
        if (allowPartial && gotMono < need) {
            std::memset(static_cast<uint8_t*>(audioData) + gotMono, 0, need - gotMono);
        }
        return allowPartial ? need : gotMono;
    }
    // 立体声：先读单声道（最多 needMono），再交错复制
    const size_t wantMono = allowPartial ? inRing_.available() : needMono;
    if (wantMono > 0) {
        if (monoScratch_.size() < wantMono) {
            monoScratch_.resize(wantMono);
        }
    }
    size_t gotMono = (wantMono > 0) ? inRing_.read(monoScratch_.data(), wantMono) : 0;
    const int16_t* src = reinterpret_cast<const int16_t*>(monoScratch_.data());
    int16_t* dst = static_cast<int16_t*>(audioData);
    const size_t frames = need / (2 * sizeof(int16_t)); // 立体声 S16 帧数
    const size_t gotFrames = gotMono / sizeof(int16_t);
    for (size_t i = 0; i < frames; i++) {
        const int16_t v = (i < gotFrames) ? src[i] : 0;
        dst[2 * i] = v;
        dst[2 * i + 1] = v;
    }
    return need;
}

void NoiseReductionPipeline::RenderLoop()
{
    std::vector<uint8_t> buf(kRenderRequestBytes);
    std::vector<int16_t> monoBuf; // VB 模式立体声下混暂存
    int consecutiveErrors = 0;
    uint64_t iter = 0;
    while (!stopping_.load()) {
        // 数据门禁：输入环不足一帧（20ms 单声道）时等待，绝不带着空环调 RenderFrame。
        // 引擎欠载时会返回系统错误而非空响应，预热/卡顿期都可能触发。
        if (inRing_.available() < kMinInputBytes) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }
        int32_t resp = 0;
        bool finished = false;
        OH_AudioSuite_Result r = OH_AudioSuiteEngine_RenderFrame(pipeline_, buf.data(),
            kRenderRequestBytes, &resp, &finished);
        if (++iter <= 10) {
            NR_LOGD("RenderFrame #%{public}llu: r=%{public}d resp=%{public}d",
                static_cast<unsigned long long>(iter), static_cast<int>(r), resp);
        }
        if (r != AUDIOSUITE_SUCCESS) {
            // 偶发错误等数据补给后重试；只有持续失败才认为管线已坏
            if (++consecutiveErrors >= kMaxConsecutiveErrors) {
                NR_LOGE("RenderFrame keeps failing %{public}d, exit render loop",
                    static_cast<int>(r));
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            continue;
        }
        consecutiveErrors = 0;
        if (resp > 0) {
            if (mode_ == NR_MODE_VOICE_BEAUTIFIER) {
                // VB 输出 48k 立体声 S16LE → (L+R)/2 下混单声道写入输出环，
                // ArkTS 侧直接按 48k 推流（无需重采样，全带音质）
                const size_t frames = static_cast<size_t>(resp) / (2 * sizeof(int16_t));
                if (frames > 0) {
                    if (monoBuf.size() < frames) {
                        monoBuf.resize(frames);
                    }
                    const int16_t* s = reinterpret_cast<const int16_t*>(buf.data());
                    for (size_t i = 0; i < frames; i++) {
                        const int32_t l = s[2 * i];
                        const int32_t rr = s[2 * i + 1];
                        monoBuf[i] = static_cast<int16_t>((l + rr) / 2);
                    }
                    outRing_.write(reinterpret_cast<const uint8_t*>(monoBuf.data()),
                        frames * sizeof(int16_t));
                }
            } else {
                outRing_.write(buf.data(), static_cast<size_t>(resp));
            }
        }
        if (finished) {
            break;
        }
    }
    if (!stopping_.load()) {
        // 非停止指令导致的退出（持续错误或输入断流过久）：置位 running_=false，
        // 让 push/pull 立即返回空，info 可查，避免 App 对着死管线空转
        running_.store(false);
        if (inputEnded_.load()) {
            NR_LOGE("input stream ended (starved too long), pipeline marked dead");
        } else {
            NR_LOGE("render loop exited unexpectedly, pipeline marked dead");
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
    {
        // 持锁置位+通知：与 OnRequestData 的谓词检查配对，
        // 消除"谓词检查后、进入等待前"的丢唤醒窗口（join 无超时，丢了就挂死）
        std::lock_guard<std::mutex> lk(cvMutex_);
        stopping_.store(true);
        dataCv_.notify_all();
    }
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
    if (vbNode_ != nullptr) {
        OH_AudioSuiteEngine_DestroyNode(vbNode_);
        vbNode_ = nullptr;
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
    size_t backlog = 0;
    {
        // 持 cvMutex_ 写入并通知：与 OnRequestData 的等待构成标准
        // "状态变更+通知"同一临界区，杜绝"检查后、等待前"的丢唤醒窗口
        std::lock_guard<std::mutex> lk(cvMutex_);
        inRing_.write(data, len);
        backlog = inRing_.available();
        dataCv_.notify_all();
    }
    // 48kHz×2B/ms = 96 B/ms
    return static_cast<int>(backlog / 96);
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
    // 输出环速率随模式变化（NR=16k，VB=48k）
    return static_cast<int>(outRing_.available() / (static_cast<size_t>(outRate_) * 2));
}

uint64_t NoiseReductionPipeline::OverwrittenBytes() const
{
    return inRing_.overwritten();
}

int NoiseReductionPipeline::SetVoiceBeautifierType(int vbType)
{
    if (vbType < 1 || vbType > 4) {
        return -1;
    }
    if (!running_.load() || mode_ != NR_MODE_VOICE_BEAUTIFIER || vbNode_ == nullptr) {
        return -2; // 非 VB 模式或未运行：调用方应回落重建管线
    }
    OH_AudioSuite_Result r = OH_AudioSuiteEngine_SetVoiceBeautifierType(vbNode_,
        static_cast<OH_VoiceBeautifierType>(vbType));
    if (r != AUDIOSUITE_SUCCESS) {
        NR_LOGE("hot set vb type %{public}d failed r=%{public}d", vbType, static_cast<int>(r));
        return -3;
    }
    vbType_ = vbType;
    NR_LOGD("hot set vb type=%{public}d ok", vbType);
    return 0;
}

