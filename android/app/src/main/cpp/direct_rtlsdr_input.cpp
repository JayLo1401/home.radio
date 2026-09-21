/*
 * home_radio addition (2026-09-19) - see direct_rtlsdr_input.h.
 */

#include "direct_rtlsdr_input.h"

#include <android/log.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <sys/resource.h>
#include <sys/time.h>

#define LOG_TAG "DirectRtlSdrInput"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {
constexpr int kSampleBufferElements = 32 * 32768; // matches CRTL_TCP_Client's own sampleBuffer size
constexpr int kInputRateHz = 2048000; // INPUT_RATE from dab-constants.h - DAB+ always uses this
}

DirectRtlSdrInput::DirectRtlSdrInput(RadioControllerInterface& radioController)
	: radioController(radioController), sampleBuffer(kSampleBufferElements)
{
}

DirectRtlSdrInput::~DirectRtlSdrInput()
{
	stop();
	if (dev) {
		rtlsdr_close(dev);
		dev = nullptr;
	}
}

bool DirectRtlSdrInput::openFromFd(int fd)
{
	if (dev) return true; // already open

	int r = rtlsdr_open_from_fd(&dev, fd);
	if (r < 0 || !dev) {
		LOGE("rtlsdr_open_from_fd failed: %d", r);
		dev = nullptr;
		return false;
	}

	rtlsdr_set_sample_rate(dev, kInputRateHz);

	int count = rtlsdr_get_tuner_gains(dev, nullptr);
	if (count > 0) {
		gainTable.resize(count);
		rtlsdr_get_tuner_gains(dev, gainTable.data());
	}
	// Manual gain (matches CRTL_TCP_Client - the hardware AGC is not used,
	// this class implements the same kind of software AGC instead). Start
	// LOW rather than at the top step. An earlier version of this function
	// started at the highest step (reasoning: 0 dB is too weak to pull
	// DAB+ out of the noise floor on a weak signal) - reverted (2026-09-19)
	// after the real welle.io app, tested against the same dongle/antenna,
	// reported "ADC overloaded" and this project's own agcLoop() below only
	// backs an overload off one gain step per 50ms tick: starting at the
	// top on a strong-signal setup means several hundred ms of genuinely
	// clipped, corrupted samples on every single (re)tune before it even
	// reaches a usable gain - actively worse for OFDM sync than a station
	// merely being a bit weak while agcLoop() climbs up towards the right
	// level from here, which is the safer direction to start from wrong in.
	rtlsdr_set_tuner_gain_mode(dev, 1);
	int startIndex = gainTable.empty() ? 0 : static_cast<int>(gainTable.size()) / 6;
	gainIndex.store(startIndex);
	if (!gainTable.empty()) {
		rtlsdr_set_tuner_gain(dev, gainTable[startIndex]);
	}
	rtlsdr_set_agc_mode(dev, 0);

	LOGI("openFromFd: ok, %d gain steps, starting at index %d", count, startIndex);
	return true;
}

void DirectRtlSdrInput::setFrequency(int frequency)
{
	frequencyHz.store(frequency);
	if (dev) {
		rtlsdr_set_center_freq(dev, static_cast<uint32_t>(frequency));
	}
}

int DirectRtlSdrInput::getFrequency(void) const
{
	return frequencyHz.load();
}

bool DirectRtlSdrInput::is_ok(void)
{
	return dev != nullptr;
}

void DirectRtlSdrInput::rtlsdrCallbackStatic(unsigned char* buf, uint32_t len, void* ctx)
{
	static_cast<DirectRtlSdrInput*>(ctx)->onSamples(buf, len);
}

void DirectRtlSdrInput::onSamples(unsigned char* buf, uint32_t len)
{
	if (!deviceRunning.load()) return;
	sampleBuffer.putDataIntoBuffer(buf, static_cast<int32_t>(len));

	// Same overload-tracking CRTL_TCP_Client's receiveData() does, feeding
	// agcLoop() below.
	uint8_t lo = 255, hi = 0;
	for (uint32_t i = 0; i < len; i++) {
		if (buf[i] < lo) lo = buf[i];
		if (buf[i] > hi) hi = buf[i];
	}
	minAmplitude.store(lo);
	maxAmplitude.store(hi);
}

void DirectRtlSdrInput::readLoop()
{
	setpriority(PRIO_PROCESS, 0, -19); // see the same boost in rtl_tcp.c
	if (!dev) return;
	rtlsdr_reset_buffer(dev);
	int r = rtlsdr_read_async(dev, &DirectRtlSdrInput::rtlsdrCallbackStatic, this, 0, 0);
	LOGI("readLoop: rtlsdr_read_async returned %d", r);
	// A retry-on-failure version of this loop was tried here (2026-09-19)
	// after a Xiaomi Mi Box repeatedly hit rtlsdr_read_async() returning
	// -1/LIBUSB_ERROR_IO - but it made that device's playback go from
	// "plays, audibly choppy" to producing no audio at all. Immediately
	// re-issuing rtlsdr_read_async() (plus rtlsdr_reset_buffer()) right
	// after a failure likely raced against agcLoop()'s own concurrent USB
	// control transfers (gain changes) on the same already-marginal
	// connection, making the instability worse instead of recovering from
	// it. Reverted; a failure here still ends the session same as before.
}

int64_t DirectRtlSdrInput::nowUs()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return static_cast<int64_t>(tv.tv_sec) * 1000000 + tv.tv_usec;
}

void DirectRtlSdrInput::agcLoop()
{
	while (deviceRunning.load()) {
		std::this_thread::sleep_for(std::chrono::milliseconds(50));
		if (!agcEnabled.load() || gainTable.empty()) continue;

		const uint8_t lo = minAmplitude.load();
		const uint8_t hi = maxAmplitude.load();
		const int idx = gainIndex.load();

		if (lo == 0 || hi == 255) {
			// Overload - decrease immediately, same as CRTL_TCP_Client.
			if (idx > 0) {
				gainIndex.store(idx - 1);
				if (dev) rtlsdr_set_tuner_gain(dev, gainTable[idx - 1]);
				lastGainDecreaseTimeUs.store(nowUs());
			}
			continue;
		}

		if (idx >= static_cast<int>(gainTable.size()) - 1) continue;

		// Same hysteresis fix as rtl_tcp.cpp's agcTimer() (see that
		// function's own comment for the full "why"): only try to
		// increase once 2s have passed since the last overload-driven
		// decrease, and require real headroom (not just "technically no
		// clip on this one buffer"), otherwise gain hunts back and forth
		// between two adjacent steps forever and OFDM sync never gets a
		// stable signal level long enough to lock.
		const bool cooledDown = (nowUs() - lastGainDecreaseTimeUs.load()) > 2000000;
		if (!cooledDown) continue;

		const float currentDb = gainTable[idx] / 10.0f;
		const float newDb = gainTable[idx + 1] / 10.0f;
		const float linGain = std::pow(10.0f, (newDb - currentDb) / 20.0f);
		const int newMax = static_cast<int>(hi * linGain);
		const int newMin = static_cast<int>(lo / linGain);
		if (newMin >= 10 && newMax <= 235) {
			gainIndex.store(idx + 1);
			if (dev) rtlsdr_set_tuner_gain(dev, gainTable[idx + 1]);
		}
	}
}

bool DirectRtlSdrInput::restart(void)
{
	if (!dev) return false;
	if (deviceRunning.load()) return true;
	deviceRunning.store(true);
	sampleBuffer.FlushRingBuffer();
	readThread = std::thread(&DirectRtlSdrInput::readLoop, this);
	agcThread = std::thread(&DirectRtlSdrInput::agcLoop, this);
	return true;
}

void DirectRtlSdrInput::stop(void)
{
	if (!deviceRunning.load()) return;
	deviceRunning.store(false);
	if (dev) rtlsdr_cancel_async(dev);
	if (readThread.joinable()) readThread.join();
	if (agcThread.joinable()) agcThread.join();
}

void DirectRtlSdrInput::reset(void)
{
	sampleBuffer.FlushRingBuffer();
}

int32_t DirectRtlSdrInput::getSamples(DSPCOMPLEX* buffer, int32_t size)
{
	std::vector<uint8_t> raw(static_cast<size_t>(size) * 2);
	int32_t got = sampleBuffer.getDataFromBuffer(raw.data(), size * 2);
	int32_t n = got / 2;
	for (int32_t i = 0; i < n; i++) {
		buffer[i] = DSPCOMPLEX((static_cast<float>(raw[i * 2]) - 128.0f) / 128.0f,
					(static_cast<float>(raw[i * 2 + 1]) - 128.0f) / 128.0f);
	}
	return n;
}

std::vector<DSPCOMPLEX> DirectRtlSdrInput::getSpectrumSamples(int size)
{
	std::vector<DSPCOMPLEX> out(size);
	int32_t n = getSamples(out.data(), size);
	out.resize(n);
	return out;
}

int32_t DirectRtlSdrInput::getSamplesToRead(void)
{
	return sampleBuffer.GetRingBufferReadAvailable() / 2;
}

float DirectRtlSdrInput::setGain(int gain)
{
	if (gainTable.empty()) return 0;
	int idx = gain;
	if (idx < 0) idx = 0;
	if (idx >= static_cast<int>(gainTable.size())) idx = static_cast<int>(gainTable.size()) - 1;
	gainIndex.store(idx);
	if (dev) rtlsdr_set_tuner_gain(dev, gainTable[idx]);
	return gainTable[idx] / 10.0f;
}

float DirectRtlSdrInput::getGain(void) const
{
	if (gainTable.empty()) return 0;
	int idx = gainIndex.load();
	return gainTable[idx] / 10.0f;
}

int DirectRtlSdrInput::getGainCount(void)
{
	return static_cast<int>(gainTable.size());
}

void DirectRtlSdrInput::setAgc(bool agc)
{
	agcEnabled.store(agc);
}

std::string DirectRtlSdrInput::getDescription(void)
{
	return "RTL-SDR (direct USB, no TCP)";
}
