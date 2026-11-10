#include "rtltcp_source.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <memory>
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
#include "json.h"
#include "r82xx.h"

namespace hrdab {

namespace {

constexpr uint8_t kCmdFrequency = 0x01;
constexpr uint8_t kCmdSampleRate = 0x02;
constexpr uint8_t kCmdGainMode = 0x03;
constexpr uint8_t kCmdGain = 0x04;
constexpr uint8_t kCmdAgcMode = 0x08;

// rtl_tcp Jay extended, wire name rtltcp_v2 (rtltcp.server docs/protocol-v2.md).
constexpr uint8_t kHelloV2[5] = {0xF2, 'R', 'T', 'L', '2'};
constexpr uint8_t kFrameIq = 0x01;
constexpr uint8_t kFrameJson = 0x02;
constexpr uint8_t kFrameCommand = 0x03;
constexpr uint32_t kMaxFrame = 16u << 20;
constexpr uint32_t kMaxJsonFrame = 1u << 20;
// No data for this long on a v2 session: ping; twice as long: reconnect.
constexpr int kV2PingAfterMs = 5000;
constexpr int kV2DeadAfterMs = 20000;
constexpr int kHandshakeTimeoutS = 12;

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

bool timedOut()
{
    return WSAGetLastError() == WSAETIMEDOUT;
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

bool timedOut()
{
    return errno == EAGAIN || errno == EWOULDBLOCK;
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

bool RtlTcpSource::sendFrame(uint8_t type, const uint8_t* data, size_t len)
{
    std::vector<uint8_t> buf(5 + len);
    buf[0] = type;
    buf[1] = static_cast<uint8_t>(len >> 24);
    buf[2] = static_cast<uint8_t>(len >> 16);
    buf[3] = static_cast<uint8_t>(len >> 8);
    buf[4] = static_cast<uint8_t>(len);
    if (len) std::memcpy(buf.data() + 5, data, len);
    std::lock_guard<std::mutex> lock(sockMutex_);
    if (sock_ < 0) return false;
    return sendSock(sock_, buf.data(), buf.size()) == static_cast<long>(buf.size());
}

bool RtlTcpSource::sendJson(const std::string& json)
{
    return sendFrame(kFrameJson, reinterpret_cast<const uint8_t*>(json.data()), json.size());
}

bool RtlTcpSource::sendCommand(uint8_t cmd, uint32_t param)
{
    uint8_t buf[5] = {cmd, static_cast<uint8_t>(param >> 24), static_cast<uint8_t>(param >> 16),
                      static_cast<uint8_t>(param >> 8), static_cast<uint8_t>(param)};
    if (framed_) return sendFrame(kFrameCommand, buf, sizeof(buf));
    std::lock_guard<std::mutex> lock(sockMutex_);
    if (sock_ < 0) return false;
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

void RtlTcpSource::status(bool isError, const std::string& message)
{
    HR_LOGI("rtl_tcp: %s", message.c_str());
    if (onStatus) onStatus(isError, message);
}

void RtlTcpSource::fail(const std::string& message)
{
    fatal_ = true;
    status(true, message);
}

std::string RtlTcpSource::stickLabel() const
{
    return stickName_.empty() ? "USB-Stick am rtl_tcp-Server" : "\xE2\x80\x9E" + stickName_ + "\xE2\x80\x9C";
}

namespace {

// Reads exactly len bytes during the handshake (2 s socket timeout).
bool readExact(intptr_t s, uint8_t* data, size_t len)
{
    size_t got = 0;
    while (got < len) {
        const long n = recvSock(s, data + got, len - got);
        if (n > 0) {
            got += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && interrupted()) continue;
        return false;
    }
    return true;
}

// 1 = data (or EOF) to read, 0 = nothing within timeoutMs, -1 = error.
int waitReadable(intptr_t s, int timeoutMs)
{
    fd_set readable;
    FD_ZERO(&readable);
    FD_SET(static_cast<SockT>(s), &readable);
    timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
    const int r = select(static_cast<int>(s + 1), &readable, nullptr, nullptr, &tv);
    if (r < 0) return interrupted() ? 0 : -1;
    return r > 0 ? 1 : 0;
}

uint32_t be32(const uint8_t* p)
{
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

// Login is gone from the protocol (rtltcp.server and rtl.over.internet do
// that now); an old server that still asks gets this answer.
const char* const kAuthUnsupported =
    "rtl_tcp-Server verlangt eine Anmeldung, das wird nicht mehr unterstützt. "
    "Bitte den rtltcp.server im lokalen Netz verwenden.";

// "Graz · Stabantenne" from server_info.device (location - or a remote
// stick's site - and antenna); empty if neither is set. Not device.name:
// that is often generated from the serial number and tells a listener
// nothing.
std::string stickNameOf(const Json& device)
{
    std::string location = device.stringOr("location", "");
    if (location.empty()) location = device["remote"].stringOr("site", "");
    const std::string antenna = device.stringOr("antenna", "");
    if (location.empty()) return antenna;
    return antenna.empty() ? location : location + " \xC2\xB7 " + antenna;
}

// The user-facing text of a v2 error message; [stickName] see stickNameOf
// (may be empty).
std::string errorText(const Json& msg, const std::string& stickName)
{
    const std::string code = msg.stringOr("code", "");
    const std::string message = msg.stringOr("message", "");
    if (code == "BUSY") {
        const std::string who = stickName.empty() ? "rtl_tcp-Server" : "\xE2\x80\x9E" + stickName + "\xE2\x80\x9C";
        const std::string client = msg.stringOr("client", "");
        return client.empty() ? who + " wird bereits von einem anderen Gerät verwendet"
                              : who + " wird bereits von " + client + " verwendet";
    }
    if (code == "AUTH_REQUIRED" || code == "AUTH_FAILED") return kAuthUnsupported;
    if (code == "KICKED") return "Vom rtl_tcp-Server getrennt";
    if (code == "PROTOCOL_ERROR") return "rtl_tcp-Server meldet einen Protokollfehler" + (message.empty() ? "" : ": " + message);
    return "rtl_tcp-Server: " + (message.empty() ? code : message);
}

} // namespace

// One frame during the handshake (blocking, 2 s timeout); unknown types are
// skipped by the caller.
bool RtlTcpSource::readFrame(intptr_t s, uint8_t& type, std::string& payload)
{
    uint8_t head[5];
    if (!readExact(s, head, sizeof(head))) return false;
    type = head[0];
    const uint32_t len = be32(head + 1);
    if (len > kMaxFrame) return false;
    payload.resize(len);
    return len == 0 || readExact(s, reinterpret_cast<uint8_t*>(&payload[0]), len);
}

// After "RTL2": server_info, then the first status (or I/Q) - only then is
// the stick ours. A busy server sends BUSY right after server_info and
// closes; commands sent before that would make the connection reset and
// lose the message.
RtlTcpSource::Connect RtlTcpSource::handshakeV2(intptr_t s)
{
    bool gotInfo = false;
    for (;;) {
        uint8_t type;
        std::string payload;
        if (!readFrame(s, type, payload)) return Connect::Failed;
        if (type == kFrameIq && gotInfo) return Connect::Ok;
        if (type != kFrameJson) continue;
        const Json msg = Json::parse(payload);
        const std::string kind = msg.stringOr("type", "");
        if (kind == "error") {
            if (msg.boolOr("fatal", true)) {
                fail(errorText(msg, stickName_));
                return Connect::Fatal;
            }
            HR_LOGW("rtl_tcp: %s", errorText(msg, stickName_).c_str());
        } else if (kind == "server_info") {
            if (msg.stringOr("auth", "none") == "required") {
                fail(kAuthUnsupported);
                return Connect::Fatal;
            }
            deviceName_ = msg["device"].stringOr("name", "");
            stickName_ = stickNameOf(msg["device"]);
            HR_LOGI("rtl_tcp: rtl_tcp Jay extended, %s %s, stick \"%s\"", msg.stringOr("server", "?").c_str(),
                    msg.stringOr("version", "?").c_str(), deviceName_.c_str());
            gotInfo = true;
        } else if (kind == "status") {
            handleMessage(msg);
            if (gotInfo) return Connect::Ok;
        }
    }
}

RtlTcpSource::Connect RtlTcpSource::connectOnce()
{
    framed_ = false;
    deviceName_.clear();
    stickName_.clear();
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* res = nullptr;
    const std::string port = std::to_string(port_);
    if (getaddrinfo(host_.c_str(), port.c_str(), &hints, &res) != 0 || !res) return Connect::Failed;
    intptr_t s = -1;
    for (addrinfo* ai = res; ai; ai = ai->ai_next) {
        s = openSock(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;
        // A server whose stick idles opens it on connect and only then sends
        // the greeting - typically 1-2 s, up to 10 s (rtltcp.server's "v1
        // client waits for stick"). 2 s here made the first connect fail.
        setTimeouts(s, kHandshakeTimeoutS);
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
    if (s < 0) return Connect::Failed;
    {
        std::lock_guard<std::mutex> lock(sockMutex_);
        sock_ = s;
    }

    // HELLO before reading anything; a classic server takes it as an
    // unknown command and ignores it.
    if (sendSock(s, kHelloV2, sizeof(kHelloV2)) != static_cast<long>(sizeof(kHelloV2))) {
        closeSocket();
        return Connect::Failed;
    }
    uint8_t greeting[12];
    if (!readExact(s, greeting, sizeof(greeting))) {
        closeSocket();
        // Closed without a word = the server refused (busy, no stick).
        return Connect::Refused;
    }
    if (std::memcmp(greeting, "RTL2", 4) == 0) {
        framed_ = true;
        const Connect c = handshakeV2(s);
        if (c != Connect::Ok) {
            closeSocket();
            framed_ = false;
            return c;
        }
    } else if (std::memcmp(greeting, "RTL0", 4) == 0) {
        HR_LOGI("rtl_tcp: classic rtl_tcp server");
    } else {
        closeSocket();
        return Connect::Failed;
    }
    sendCommand(kCmdSampleRate, sampleRate());
    sendCommand(kCmdAgcMode, 0);
    sendCommand(kCmdGainMode, 1); // manual - the receiver runs its own AGC
    if (gainIndex_ >= 0) sendCommand(kCmdGain, static_cast<uint32_t>(R82xx::gainTenthsDb(gainIndex_)));
    if (freqHz_ != 0) sendCommand(kCmdFrequency, freqHz_);
    return Connect::Ok;
}

// A JSON frame on a running v2 session.
bool RtlTcpSource::handleMessage(const Json& msg)
{
    const std::string kind = msg.stringOr("type", "");
    std::string text;
    bool isError = false;
    if (kind == "status") {
        const std::string state = msg.stringOr("state", "");
        if (state == "ready" || state == "device_restored") {
            // Only worth saying when something was wrong before.
            if (lastStatus_.empty()) return true;
            text = stickLabel() + " bereit";
        } else if (state == "starting") {
            text = stickName_.empty() ? "Empfänger am rtl_tcp-Server startet …" : stickLabel() + " startet …";
            isError = true;
        } else if (state == "device_not_ready") {
            text = stickLabel() + " nicht bereit";
            isError = true;
        } else if (state == "device_lost") {
            text = stickLabel() + " getrennt – verbinde neu …";
            isError = true;
        } else {
            return true;
        }
    } else if (kind == "error") {
        if (msg.boolOr("fatal", false)) {
            fail(errorText(msg, stickName_));
            return false;
        }
        // INVALID_COMMAND etc.: the session goes on.
        HR_LOGW("rtl_tcp: %s", errorText(msg, stickName_).c_str());
        return true;
    } else if (kind == "ping") {
        JsonWriter w;
        w.beginObject().str("type", "pong").num("id", msg.intOr("id", 0)).endObject();
        sendJson(w.text());
        return true;
    } else {
        return true; // pong, unknown types
    }
    if (text == lastStatus_) return true;
    lastStatus_ = isError ? text : std::string();
    status(isError, text);
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
    // After a fatal error the thread has ended on its own: a new start (the
    // user plays again) is the retry.
    if (running_ && !fatal_) return true;
    if (thread_.joinable()) stop();
    ring_ = &ring;
    fatal_ = false;
    lastStatus_.clear();
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
        const Connect c = connectOnce();
        if (c == Connect::Fatal) return; // fail() has told the user
        if (c != Connect::Ok) {
            if (!reportedDown) {
                status(true, c == Connect::Refused
                                 ? "rtl_tcp-Server " + host_ + ":" + std::to_string(port_) + " hat die Verbindung abgelehnt"
                                 : "rtl_tcp-Quelle " + host_ + ":" + std::to_string(port_) + " nicht erreichbar");
                reportedDown = true;
            }
            // A refusing server is not hammered.
            const int waits = c == Connect::Refused ? 50 : 10;
            for (int i = 0; i < waits && running_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        if (reportedDown || everConnected) status(false, "Verbindung zur rtl_tcp-Quelle hergestellt");
        everConnected = true;
        reportedDown = false;
        const auto connectedAt = std::chrono::steady_clock::now();
        intptr_t s;
        {
            std::lock_guard<std::mutex> lock(sockMutex_);
            s = sock_;
        }
        if (!framed_) {
            while (running_) {
                const long n = recvSock(s, buf.data(), buf.size());
                if (n > 0) {
                    ring_->write(buf.data(), static_cast<size_t>(n));
                    continue;
                }
                if (n < 0 && interrupted()) continue;
                break;
            }
        } else {
            // Frame parser over the byte stream: 5-byte header, then the
            // payload - I/Q straight into the ring, JSON collected.
            uint8_t head[5];
            size_t headGot = 0;
            uint8_t type = 0;
            uint32_t remaining = 0;
            std::string json;
            auto idleSince = std::chrono::steady_clock::now();
            bool pinged = false;
            bool ok = true;
            while (running_ && ok) {
                // select instead of the socket timeout: after a timed-out
                // recv Winsock leaves the socket in an undefined state.
                const int ready = waitReadable(s, 1000);
                if (ready < 0) break;
                if (ready == 0) {
                    // No I/Q while the stick is away - normal on v2; the
                    // server says when it's back. Ping to tell a dead link
                    // from a quiet one.
                    const auto idleMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                            std::chrono::steady_clock::now() - idleSince)
                                            .count();
                    if (idleMs > kV2DeadAfterMs) break;
                    if (idleMs > kV2PingAfterMs && !pinged) {
                        sendJson("{\"type\":\"ping\",\"id\":1}");
                        pinged = true;
                    }
                    continue;
                }
                const long n = recvSock(s, buf.data(), buf.size());
                if (n <= 0) {
                    if (n < 0 && (interrupted() || timedOut())) continue;
                    break;
                }
                idleSince = std::chrono::steady_clock::now();
                pinged = false;
                const uint8_t* p = buf.data();
                size_t left = static_cast<size_t>(n);
                while (left > 0 && ok) {
                    if (headGot < sizeof(head)) {
                        const size_t take = std::min(left, sizeof(head) - headGot);
                        std::memcpy(head + headGot, p, take);
                        headGot += take;
                        p += take;
                        left -= take;
                        if (headGot < sizeof(head)) break;
                        type = head[0];
                        remaining = be32(head + 1);
                        json.clear();
                        if (remaining > kMaxFrame) {
                            HR_LOGE("rtl_tcp: frame of %u bytes - stream out of sync", remaining);
                            ok = false;
                            break;
                        }
                        if (remaining == 0) {
                            headGot = 0;
                            if (type == kFrameJson) ok = handleMessage(Json::parse(json));
                        }
                        continue;
                    }
                    const size_t take = std::min<size_t>(left, remaining);
                    if (type == kFrameIq) {
                        ring_->write(p, take);
                    } else if (type == kFrameJson && json.size() + take <= kMaxJsonFrame) {
                        json.append(reinterpret_cast<const char*>(p), take);
                    }
                    p += take;
                    left -= take;
                    remaining -= static_cast<uint32_t>(take);
                    if (remaining == 0) {
                        headGot = 0;
                        if (type == kFrameJson) ok = handleMessage(Json::parse(json));
                    }
                }
            }
        }
        closeSocket();
        framed_ = false;
        if (fatal_) return; // fatal error from the server - no reconnect
        if (running_) {
            status(true, "Verbindung zur rtl_tcp-Quelle verloren");
            reportedDown = true;
            // Dropped right after connecting (e.g. a server that keeps
            // refusing): no tight reconnect loop.
            if (std::chrono::steady_clock::now() - connectedAt < std::chrono::seconds(2)) {
                for (int i = 0; i < 50 && running_; i++) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }
    }
}

} // namespace hrdab
