/*
 * NAPI 导出层。ArkTS 侧：import nr from 'libentry_nr.so'
 */
#include <napi/native_api.h>

#include <cstring>
#include <vector>

#include <hilog/log.h>

#include "nr_pipeline.h"

namespace {
constexpr size_t kPullChunkBytes = 2048; // 每次 pull 最大字节（16k×2B≈64ms）
} // namespace

static napi_value NrInit(napi_env env, napi_callback_info info)
{
    int rc = NoiseReductionPipeline::Get().Init();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NrRelease(napi_env env, napi_callback_info info)
{
    NoiseReductionPipeline::Get().Release();
    return nullptr;
}

static napi_value NrPush(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_value r;
        napi_create_int32(env, -1, &r);
        return r;
    }
    bool isAb = false;
    napi_is_arraybuffer(env, argv[0], &isAb);
    if (!isAb) {
        napi_value r;
        napi_create_int32(env, -2, &r);
        return r;
    }
    void* data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, argv[0], &data, &len);
    if (data == nullptr || len == 0) {
        napi_value r;
        napi_create_int32(env, -3, &r);
        return r;
    }
    auto& pl = NoiseReductionPipeline::Get();
    if (!pl.IsRunning()) {
        napi_value r;
        napi_create_int32(env, -4, &r);
        return r;
    }
    int backlog = pl.Push(static_cast<uint8_t*>(data), len);
    napi_value r;
    napi_create_int32(env, backlog, &r);
    return r;
}

static napi_value NrPull(napi_env env, napi_callback_info info)
{
    auto& pl = NoiseReductionPipeline::Get();
    // 尽量取空队列（最多 kPullChunkBytes 一次）
    static thread_local std::vector<uint8_t> tmp;
    tmp.resize(kPullChunkBytes);
    size_t got = 0;
    if (pl.IsRunning()) {
        got = pl.Pull(tmp.data(), tmp.size());
    }
    napi_value ab = nullptr;
    // 鸿蒙 NAPI 坑（官方差异文档实锤）：napi_create_arraybuffer 的 data 参数
    // 不能直接传 nullptr——即便长度 >0 也会返回 napi_generic_failure，
    // 必须传"指向空指针的指针"让 NAPI 自行分配。这也是最初闪退的深层原因：
    // 创建失败时返回了未初始化句柄。
    void* data = nullptr;
    napi_status st = napi_create_arraybuffer(env, got, &data, &ab);
    if (st != napi_ok || ab == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "PhoneMicNr",
            "napi_create_arraybuffer failed st=%{public}d got=%{public}zu", (int)st, got);
        // 兜底：返回 undefined（ArkTS 侧有 instanceof 防御），绝不再返回坏句柄
        napi_value und;
        napi_get_undefined(env, &und);
        return und;
    }
    if (got > 0) {
        if (data == nullptr) {
            // 官方文档：byte_length 为 0 或超大时 data 返回 nullptr，需判空
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, "PhoneMicNr",
                "arraybuffer data is null, got=%{public}zu", got);
        } else {
            std::memcpy(data, tmp.data(), got);
        }
    }
    return ab;
}

static napi_value NrInfo(napi_env env, napi_callback_info info)
{
    auto& pl = NoiseReductionPipeline::Get();
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
        "running=%d in_backlog_ms=%d out_backlog_ms=%d overwritten=%llu",
        pl.IsRunning() ? 1 : 0, pl.InputBacklogMs(), pl.OutputBacklogMs(),
        static_cast<unsigned long long>(pl.OverwrittenBytes()));
    napi_value s;
    napi_create_string_utf8(env, buf, (n > 0 ? n : 0), &s);
    return s;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"init", nullptr, NrInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, NrRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"push", nullptr, NrPush, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pull", nullptr, NrPull, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"info", nullptr, NrInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

// so 名 libentry_nr.so → 模块名 "entry_nr"
static napi_module nrModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_register_func = Init,
    .nm_modname = "entry_nr",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_START
__attribute__((constructor)) static void RegisterEntryNrModule(void)
{
    napi_module_register(&nrModule);
}
EXTERN_C_END
