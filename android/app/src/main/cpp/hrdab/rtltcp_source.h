#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <thread>

#include "sample_source.h"

namespace hrdab {

// Client for the rtl_tcp network protocol (12-byte "RTL0" greeting, then
// raw 8-bit I/Q; 5-byte big-endian commands upstream). Reconnects on its own
// and re-applies frequency and gain after every reconnect.
class RtlTcpSource : public SampleSource {
public:
    RtlTcpSource(std::string host, int port);
    ~RtlTcpSource() override;

    bool start(ByteRing& ring) override;
    void stop() override;
    bool setFrequency(uint32_t hz) override;
    int gainCount() const override;
    bool setGainIndex(int index) override;
    int gainTenthsDb(int index) const override;
    // Sent with command 0x02 on every (re)connect; the receiver only changes
    // it while stopped, i.e. before the next connect.
    bool setSampleRate(uint32_t hz) override;

private:
    void loop();
    bool connectOnce();
    bool sendCommand(uint8_t cmd, uint32_t param);
    void closeSocket();

    std::string host_;
    int port_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::mutex sockMutex_;
    int sock_ = -1;
    ByteRing* ring_ = nullptr;
    std::atomic<uint32_t> freqHz_{0};
    std::atomic<int> gainIndex_{-1};
};

} // namespace hrdab
