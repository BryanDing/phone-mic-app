/*
 * 线程安全的定长环形字节缓冲。
 * 写入侧：ArkTS 主线程 push PCM；读取侧：OHAudioSuite RequestDataCallback
 * （在 native 渲染线程上下文被调用）。
 * 写满时覆盖最旧数据——实时音频流"丢旧保新"好于阻塞上游。
 */
#ifndef PHONEMIC_RING_BUFFER_H
#define PHONEMIC_RING_BUFFER_H

#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

class RingBuffer {
public:
    explicit RingBuffer(size_t capacity) : buf_(capacity), cap_(capacity) {}

    /** 写入数据；返回实际写入字节数（等于 dataLen，除非容量为 0）。 */
    size_t write(const uint8_t* data, size_t dataLen)
    {
        if (data == nullptr || dataLen == 0 || cap_ == 0) {
            return 0;
        }
        std::lock_guard<std::mutex> lk(mtx_);
        // 需要丢弃的最旧字节数（覆盖策略）
        size_t space = cap_ - avail_;
        if (dataLen > space) {
            size_t drop = dataLen - space;
            head_ = (head_ + drop) % cap_;
            avail_ -= drop;
            overwritten_ += drop;
        }
        size_t first = (dataLen <= cap_ - tail_) ? dataLen : (cap_ - tail_);
        std::memcpy(buf_.data() + tail_, data, first);
        if (first < dataLen) {
            std::memcpy(buf_.data(), data + first, dataLen - first);
        }
        tail_ = (tail_ + dataLen) % cap_;
        avail_ += dataLen;
        return dataLen;
    }

    /** 读取数据；返回实际读出的字节数（不足则给现有全部）。 */
    size_t read(uint8_t* out, size_t wantLen)
    {
        if (out == nullptr || wantLen == 0 || cap_ == 0) {
            return 0;
        }
        std::lock_guard<std::mutex> lk(mtx_);
        size_t n = (wantLen < avail_) ? wantLen : avail_;
        if (n == 0) {
            return 0;
        }
        size_t first = (n <= cap_ - head_) ? n : (cap_ - head_);
        std::memcpy(out, buf_.data() + head_, first);
        if (first < n) {
            std::memcpy(out + first, buf_.data(), n - first);
        }
        head_ = (head_ + n) % cap_;
        avail_ -= n;
        return n;
    }

    size_t available() const
    {
        std::lock_guard<std::mutex> lk(mtx_);
        return avail_;
    }

    uint64_t overwritten() const
    {
        return overwritten_;
    }

    void clear()
    {
        std::lock_guard<std::mutex> lk(mtx_);
        head_ = tail_ = avail_ = 0;
        overwritten_ = 0;
    }

private:
    mutable std::mutex mtx_;
    std::vector<uint8_t> buf_;
    size_t cap_;
    size_t head_ = 0; // 读位置
    size_t tail_ = 0; // 写位置
    size_t avail_ = 0;
    uint64_t overwritten_ = 0; // 累计被覆盖丢弃的字节（背压诊断）
};

#endif // PHONEMIC_RING_BUFFER_H
