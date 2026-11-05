#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include "sample_source.h"

namespace hrdab {

class Json;

// Protocol settings of one rtl_tcp server (chosen by hand in the app, no
// auto-detection). v1 = classic rtl_tcp, exactly the old behaviour.
struct RtlTcpOptions {
    bool v2 = false;   // rtltcp_v2: HELLO, framed stream, status/error messages
    bool auth = false; // log in (SCRAM-SHA-256) when the server requires it
    std::string user;
    std::string password;
};

// Client for the rtl_tcp network protocol (12-byte "RTL0" greeting, then
// raw 8-bit I/Q; 5-byte big-endian commands upstream). Reconnects on its own
// and re-applies frequency and gain after every reconnect.
//
// With RtlTcpOptions::v2 it speaks rtltcp_v2 (rtltcp.server,
// docs/protocol-v2.md): everything after the "RTL2" header is framed
// (u8 type | u32 length | payload) - I/Q payloads go to the ring as before,
// JSON frames become onStatus messages. While the server reports the stick
// as not ready / lost the connection is kept (the server says when it's
// back); after a fatal error (busy, login, kicked) it does not reconnect
// until the next start(). A plain rtl_tcp server answers HELLO with "RTL0"
// and the session continues as v1.
class RtlTcpSource : public SampleSource {
public:
    RtlTcpSource(std::string host, int port, RtlTcpOptions options = {});
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

    std::string host_;
    int port_;
    RtlTcpOptions options_;
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
