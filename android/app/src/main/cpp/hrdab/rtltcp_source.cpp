#include "rtltcp_source.h"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <vector>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mutex>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "common.h"
#include "r82xx.h"

namespace hrdab {

namespace {

constexpr uint8_t kCmdFrequency = 0x01;
constexpr uint8_t kCmdSampleRate = 0x02;
constexpr uint8_t kCmdGainMode = 0x03;
constexpr uint8_t kCmdGain = 0x04;
constexpr uint8_t kCmdAgcMode = 0x08;

// The few socket calls that differ between POSIX and Winsock.
#ifdef _WIN32
using SockLen = int;
constexpr int kSendFlags = 0;

void netInit()
{
    static std::once_flag once;
    std::call_once(once, [] {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
    });
}

void closeSock(intptr_t s)
{
    closesocket(static_cast<SOCKET>(s));
}

void shutdownSock(intptr_t s)
{
    shutdown(static_cast<SOCKET>(s), SD_BOTH);
}

intptr_t openSock(int family, int type, int protocol)
{
    const SOCKET s = socket(family, type, protocol);
    return s == INVALID_SOCKET ? -1 : static_cast<intptr_t>(s);
}

void setTimeouts(intptr_t s, int seconds)
{
    const DWORD ms = static_cast<DWORD>(seconds * 1000);
    setsockopt(static_cast<SOCKET>(s), SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
    setsockopt(static_cast<SOCKET>(s), SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&ms), sizeof(ms));
}

bool interrupted()
{
    return WSAGetLastError() == WSAEINTR;
}
#else
using SockLen = socklen_t;
constexpr int kSendFlags = MSG_NOSIGNAL;

void netInit() {}

void closeSock(intptr_t s)
{
    close(static_cast<int>(s));
}

void shutdownSock(intptr_t s)
{
    shutdown(static_cast<int>(s), SHUT_RDWR);
}

intptr_t openSock(int family, int type, int protocol)
{
    return socket(family, type, protocol);
}

void setTimeouts(intptr_t s, int seconds)
{
    timeval tv{seconds, 0};
    setsockopt(static_cast<int>(s), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(static_cast<int>(s), SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

bool interrupted()
{
    return errno == EINTR;
}
#endif

using SockT = decltype(socket(0, 0, 0)); // int / SOCKET

void setOpt(intptr_t s, int level, int name, int value)
{
    setsockopt(static_cast<SockT>(s), level, name, reinterpret_cast<const char*>(&value),
               static_cast<SockLen>(sizeof(value)));
}

long sendSock(intptr_t s, const uint8_t* data, size_t len)
{
    return static_cast<long>(send(static_cast<SockT>(s), reinterpret_cast<const char*>(data),
                                  static_cast<int>(len), kSendFlags));
}

long recvSock(intptr_t s, uint8_t* data, size_t len)
{
    return static_cast<long>(
        recv(static_cast<SockT>(s), reinterpret_cast<char*>(data), static_cast<int>(len), 0));
}

} // namespace

RtlTcpSource::RtlTcpSource(std::string host, int port) : host_(std::move(host)), port_(port)
{
    netInit();
}

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
    return sendSock(sock_, buf, sizeof(buf)) == static_cast<long>(sizeof(buf));
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

bool RtlTcpSource::setSampleRate(uint32_t hz)
{
    SampleSource::setSampleRate(hz);
    // Connected (should not happen, see header): switch right away too.
    sendCommand(kCmdSampleRate, hz);
    return true;
}

void RtlTcpSource::closeSocket()
{
    std::lock_guard<std::mutex> lock(sockMutex_);
    if (sock_ >= 0) {
        shutdownSock(sock_);
        closeSock(sock_);
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
    intptr_t s = -1;
    for (addrinfo* ai = res; ai; ai = ai->ai_next) {
        s = openSock(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
        setTimeouts(s, 2);
        setOpt(s, IPPROTO_TCP, TCP_NODELAY, 1);
        setOpt(s, SOL_SOCKET, SO_RCVBUF, 1 << 20);
        if (connect(static_cast<SockT>(s), ai->ai_addr, static_cast<SockLen>(ai->ai_addrlen)) ==
            0) {
            break;
        }
        closeSock(s);
        s = -1;
    }
    freeaddrinfo(res);
    if (s < 0) return false;

    uint8_t greeting[12];
    size_t got = 0;
    while (got < sizeof(greeting)) {
        const long n = recvSock(s, greeting + got, sizeof(greeting) - got);
        if (n <= 0) {
            closeSock(s);
            return false;
        }
        got += static_cast<size_t>(n);
    }
    if (std::memcmp(greeting, "RTL0", 4) != 0) {
        closeSock(s);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(sockMutex_);
        sock_ = s;
    }
    sendCommand(kCmdSampleRate, sampleRate());
    sendCommand(kCmdAgcMode, 0);
    sendCommand(kCmdGainMode, 1); // manual - the receiver runs its own AGC
    if (gainIndex_ >= 0) sendCommand(kCmdGain, static_cast<uint32_t>(R82xx::gainTenthsDb(gainIndex_)));
    if (freqHz_ != 0) sendCommand(kCmdFrequency, freqHz_);
    return true;
}

bool RtlTcpSource::probe(const std::string& host, int port, int timeoutMs)
{
    netInit();
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) return false;
    bool ok = false;
    for (addrinfo* ai = res; ai && !ok; ai = ai->ai_next) {
        const intptr_t s = openSock(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
#ifdef _WIN32
        u_long nonBlocking = 1;
        ioctlsocket(static_cast<SOCKET>(s), FIONBIO, &nonBlocking);
#else
        fcntl(static_cast<int>(s), F_SETFL, fcntl(static_cast<int>(s), F_GETFL, 0) | O_NONBLOCK);
#endif
        connect(static_cast<SockT>(s), ai->ai_addr, static_cast<SockLen>(ai->ai_addrlen));
        fd_set writable, failed;
        FD_ZERO(&writable);
        FD_ZERO(&failed);
        FD_SET(static_cast<SockT>(s), &writable);
        FD_SET(static_cast<SockT>(s), &failed);
        timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
        if (select(static_cast<int>(s + 1), nullptr, &writable, &failed, &tv) > 0 &&
            FD_ISSET(static_cast<SockT>(s), &writable)) {
            int err = 0;
            SockLen len = sizeof(err);
            getsockopt(static_cast<SockT>(s), SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
            ok = err == 0;
        }
        closeSock(s);
    }
    freeaddrinfo(res);
    return ok;
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
    raiseThreadPriority(-19);
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
        intptr_t s;
        {
            std::lock_guard<std::mutex> lock(sockMutex_);
            s = sock_;
        }
        while (running_) {
            const long n = recvSock(s, buf.data(), buf.size());
            if (n > 0) {
                ring_->write(buf.data(), static_cast<size_t>(n));
                continue;
            }
            if (n < 0 && interrupted()) continue;
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
