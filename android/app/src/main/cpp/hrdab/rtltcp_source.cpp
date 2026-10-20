#include "rtltcp_source.h"

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#include "common.h"
#include "r82xx.h"

namespace hrdab {

namespace {

constexpr uint8_t kCmdFrequency = 0x01;
constexpr uint8_t kCmdSampleRate = 0x02;
constexpr uint8_t kCmdGainMode = 0x03;
constexpr uint8_t kCmdGain = 0x04;
constexpr uint8_t kCmdAgcMode = 0x08;

} // namespace

RtlTcpSource::RtlTcpSource(std::string host, int port) : host_(std::move(host)), port_(port) {}

RtlTcpSource::~RtlTcpSource()
{
    stop();
}

// The gain table follows the R820T steps; most rtl_tcp servers use that
// tuner and round any other request to their nearest supported value.
int RtlTcpSource::gainCount() const
{
    return R82xx::kGainSteps;
}

int RtlTcpSource::gainTenthsDb(int index) const
{
    return R82xx::gainTenthsDb(index);
}

bool RtlTcpSource::sendCommand(uint8_t cmd, uint32_t param)
{
    std::lock_guard<std::mutex> lock(sockMutex_);
    if (sock_ < 0) return false;
    uint8_t buf[5] = {cmd, static_cast<uint8_t>(param >> 24), static_cast<uint8_t>(param >> 16),
                      static_cast<uint8_t>(param >> 8), static_cast<uint8_t>(param)};
    return send(sock_, buf, sizeof(buf), MSG_NOSIGNAL) == static_cast<ssize_t>(sizeof(buf));
}

bool RtlTcpSource::setFrequency(uint32_t hz)
{
    freqHz_ = hz;
    return sendCommand(kCmdFrequency, hz) || !running_;
}

bool RtlTcpSource::setGainIndex(int index)
{
    gainIndex_ = index;
    return sendCommand(kCmdGain, static_cast<uint32_t>(R82xx::gainTenthsDb(index))) || !running_;
}

void RtlTcpSource::closeSocket()
{
    std::lock_guard<std::mutex> lock(sockMutex_);
    if (sock_ >= 0) {
        shutdown(sock_, SHUT_RDWR);
        close(sock_);
        sock_ = -1;
    }
}

bool RtlTcpSource::connectOnce()
{
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    const std::string port = std::to_string(port_);
    if (getaddrinfo(host_.c_str(), port.c_str(), &hints, &res) != 0 || !res) return false;
    int s = -1;
    for (addrinfo* ai = res; ai; ai = ai->ai_next) {
        s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
        timeval tv{2, 0};
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        int one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int rcvbuf = 1 << 20;
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        if (connect(s, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(s);
        s = -1;
    }
    freeaddrinfo(res);
    if (s < 0) return false;

    uint8_t greeting[12];
    size_t got = 0;
    while (got < sizeof(greeting)) {
        const ssize_t n = recv(s, greeting + got, sizeof(greeting) - got, 0);
        if (n <= 0) {
            close(s);
            return false;
        }
        got += static_cast<size_t>(n);
    }
    if (std::memcmp(greeting, "RTL0", 4) != 0) {
        close(s);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(sockMutex_);
        sock_ = s;
    }
    sendCommand(kCmdSampleRate, kSampleRate);
    sendCommand(kCmdAgcMode, 0);
    sendCommand(kCmdGainMode, 1); // manual - the receiver runs its own AGC
    if (gainIndex_ >= 0) sendCommand(kCmdGain, static_cast<uint32_t>(R82xx::gainTenthsDb(gainIndex_)));
    if (freqHz_ != 0) sendCommand(kCmdFrequency, freqHz_);
    return true;
}

bool RtlTcpSource::start(ByteRing& ring)
{
    if (running_) return true;
    ring_ = &ring;
    running_ = true;
    thread_ = std::thread(&RtlTcpSource::loop, this);
    return true;
}

void RtlTcpSource::stop()
{
    if (!thread_.joinable()) return;
    running_ = false;
    closeSocket();
    thread_.join();
}

void RtlTcpSource::loop()
{
    setpriority(PRIO_PROCESS, 0, -19);
    std::vector<uint8_t> buf(65536);
    bool everConnected = false;
    bool reportedDown = false;
    while (running_) {
        if (!connectOnce()) {
            if (!reportedDown && onStatus) {
                onStatus(true, "rtl_tcp-Quelle " + host_ + ":" + std::to_string(port_) + " nicht erreichbar");
                reportedDown = true;
            }
            for (int i = 0; i < 10 && running_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        if ((reportedDown || everConnected) && onStatus) onStatus(false, "Verbindung zur rtl_tcp-Quelle hergestellt");
        everConnected = true;
        reportedDown = false;
        int s;
        {
            std::lock_guard<std::mutex> lock(sockMutex_);
            s = sock_;
        }
        while (running_) {
            const ssize_t n = recv(s, buf.data(), buf.size(), 0);
            if (n > 0) {
                ring_->write(buf.data(), static_cast<size_t>(n));
                continue;
            }
            if (n < 0 && (errno == EINTR)) continue;
            break;
        }
        closeSocket();
        if (running_ && onStatus) {
            onStatus(true, "Verbindung zur rtl_tcp-Quelle verloren");
            reportedDown = true;
        }
    }
}

} // namespace hrdab
