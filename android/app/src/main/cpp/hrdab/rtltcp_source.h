#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include "sample_source.h"

namespace hrdab {

class Json;

// Client for the rtl_tcp network protocol (12-byte "RTL0" greeting, then
// raw 8-bit I/Q; 5-byte big-endian commands upstream). Reconnects on its own
// and re-applies frequency and gain after every reconnect.
//
// Every connection starts with HELLO_V2; the server's answer decides the
// protocol (rtltcp.server docs/protocol-v2.md §2):
// - "RTL2": rtl_tcp Jay extended (wire name rtltcp_v2) - everything after
//   the header is framed (u8 type | u32 length | payload), I/Q payloads go
//   to the ring as before, JSON frames become onStatus messages. While the
//   server reports the stick as not ready / lost the connection is kept (the
//   server says when it's back); after a fatal error (busy, kicked) it does
//   not reconnect until the next start().
// - "RTL0": classic rtl_tcp, which ignores HELLO as an unknown command.
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

    // Whether something accepts a TCP connection at host:port within
    // timeoutMs (desktop "setServer"; Android probes from Kotlin).
    static bool probe(const std::string& host, int port, int timeoutMs);

private:
    enum class Connect { Ok, Failed, Refused, Fatal };

    void loop();
    Connect connectOnce();
    Connect handshakeV2(intptr_t s);
    bool readFrame(intptr_t s, uint8_t& type, std::string& payload);
    bool sendFrame(uint8_t type, const uint8_t* data, size_t len);
    bool sendJson(const std::string& json);
    bool sendCommand(uint8_t cmd, uint32_t param);
    void closeSocket();
    // A JSON frame during the session; false = fatal error, stop.
    bool handleMessage(const Json& msg);
    // Shows a fatal error and remembers it (no reconnect).
    void fail(const std::string& message);
    void status(bool isError, const std::string& message);
    // "„Standort1 Stick 1“" from server_info, else the generic stick wording.
    std::string stickLabel() const;

    std::string host_;
    int port_;
    std::string deviceName_; // server_info.device.name of the current v2 session
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> fatal_{false};
    std::atomic<bool> framed_{false}; // current connection is a v2 session
    std::mutex sockMutex_;
    intptr_t sock_ = -1; // fd, or SOCKET on Windows
    ByteRing* ring_ = nullptr;
    std::atomic<uint32_t> freqHz_{0};
    std::atomic<int> gainIndex_{-1};
    std::string lastStatus_; // last v2 message shown, to avoid repeats
};

} // namespace hrdab
