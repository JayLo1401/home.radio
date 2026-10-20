#pragma once

#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace hrdab {

// Single producer / single consumer byte FIFO between the sample source
// (USB or TCP) and the OFDM thread. The producer never blocks: when the
// consumer falls behind, new data is dropped and counted, so a slow
// consumer can never stall USB transfers.
class ByteRing {
public:
    explicit ByteRing(size_t capacity) : buf_(capacity) {}

    size_t write(const uint8_t* data, size_t len)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const size_t free = buf_.size() - fill_;
        const size_t n = len < free ? len : free;
        dropped_ += len - n;
        size_t w = (rd_ + fill_) % buf_.size();
        size_t first = n < buf_.size() - w ? n : buf_.size() - w;
        std::memcpy(&buf_[w], data, first);
        std::memcpy(&buf_[0], data + first, n - first);
        fill_ += n;
        cv_.notify_one();
        return n;
    }

    // Blocks until `len` bytes were read or abort() was called; returns the
    // number of bytes read.
    size_t read(uint8_t* out, size_t len)
    {
        size_t done = 0;
        std::unique_lock<std::mutex> lock(mutex_);
        while (done < len) {
            cv_.wait(lock, [&] { return fill_ > 0 || aborted_ || interrupted_; });
            if (aborted_) break;
            if (interrupted_) {
                interrupted_ = false;
                break;
            }
            const size_t want = len - done;
            const size_t n = want < fill_ ? want : fill_;
            size_t first = n < buf_.size() - rd_ ? n : buf_.size() - rd_;
            std::memcpy(out + done, &buf_[rd_], first);
            std::memcpy(out + done + first, &buf_[0], n - first);
            rd_ = (rd_ + n) % buf_.size();
            fill_ -= n;
            done += n;
        }
        return done;
    }

    void clear()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        rd_ = 0;
        fill_ = 0;
    }

    // Wakes a blocked read() once, without data (used for resets).
    void interrupt()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        interrupted_ = true;
        cv_.notify_all();
    }

    void abort()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        aborted_ = true;
        cv_.notify_all();
    }

    void reopen()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        aborted_ = false;
        interrupted_ = false;
        rd_ = 0;
        fill_ = 0;
    }

    size_t freeSpace()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return buf_.size() - fill_;
    }

    size_t takeDropped()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const size_t d = dropped_;
        dropped_ = 0;
        return d;
    }

private:
    std::vector<uint8_t> buf_;
    std::mutex mutex_;
    std::condition_variable cv_;
    size_t rd_ = 0;
    size_t fill_ = 0;
    size_t dropped_ = 0;
    bool aborted_ = false;
    bool interrupted_ = false;
};

} // namespace hrdab
