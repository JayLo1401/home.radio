#ifndef DIRECT_RTLSDR_INPUT_H
#define DIRECT_RTLSDR_INPUT_H

/*
 * home_radio addition (2026-09-19) - not part of any vendored library.
 *
 * An InputInterface (see dabcore/backend/radio-controller.h) that feeds the
 * DAB+ decoder directly from librtlsdr, with no TCP involved at all - the
 * "own USB service" mode's answer to the fact that CRTL_TCP_Client
 * (dabcore/input/rtl_tcp.cpp) talks to our rtl_tcp server over a real
 * loopback socket, even though both ends run in this same process.
 *
 * This does NOT touch rtl_tcp_main()/rtl_tcp.c at all - that vendored
 * server (used for "external app"/"network service" modes, and for the raw
 * RTL-SDR test screen) keeps working exactly as before. Direct mode is a
 * separate, parallel path: it opens its own rtlsdr_dev_t from the same
 * Android USB fd and runs its own rtlsdr_read_async() loop. Since a single
 * USB device can only be claimed by one open rtlsdr_dev_t at a time, direct
 * mode and the rtl_tcp server are mutually exclusive on the same dongle -
 * matching the RTL-SDR Test screen's own "USB-Dienst stoppen" /
 * "Sendersuchlauf starten" affecting the same physical resource anyway.
 *
 * Ported from CRTL_TCP_Client's own gain-adjustment logic
 * (dabcore/input/rtl_tcp.cpp's agcTimer(), including this project's own
 * 2026-09-19 hysteresis fix - see that function's comment for why) since
 * there is no rtl_tcp server in the loop here to do it - reading the gain
 * table from the real device via rtlsdr_get_tuner_gains() instead of
 * CRTL_TCP_Client's hardcoded per-tuner-type arrays.
 */

#include "radio-controller.h"
#include "ringbuffer.h"
#include "rtl-sdr.h"

#include <atomic>
#include <cstdint>
#include <string>
#include <thread>
#include <vector>

class DirectRtlSdrInput : public InputInterface {
public:
	explicit DirectRtlSdrInput(RadioControllerInterface& radioController);
	~DirectRtlSdrInput() override;

	/* Opens the device from an already-permitted Android USB file
	 * descriptor (see rtlsdr_open_from_fd() in librtlsdr.c). Must be
	 * called once before restart(). Returns false on failure. */
	bool openFromFd(int fd);

	void setFrequency(int frequency) override;
	int getFrequency(void) const override;
	bool is_ok(void) override;
	bool restart(void) override;
	void stop(void) override;
	void reset(void) override;
	int32_t getSamples(DSPCOMPLEX* buffer, int32_t size) override;
	std::vector<DSPCOMPLEX> getSpectrumSamples(int size) override;
	int32_t getSamplesToRead(void) override;
	float setGain(int gain) override;
	float getGain(void) const override;
	int getGainCount(void) override;
	void setAgc(bool agc) override;
	std::string getDescription(void) override;

private:
	static void rtlsdrCallbackStatic(unsigned char* buf, uint32_t len, void* ctx);
	void onSamples(unsigned char* buf, uint32_t len);
	void readLoop();
	void agcLoop();
	static int64_t nowUs();

	RadioControllerInterface& radioController;
	rtlsdr_dev_t* dev = nullptr;
	std::vector<int> gainTable; // tenths of dB, ascending - from rtlsdr_get_tuner_gains()

	std::atomic<bool> deviceRunning{false}; // true once restart() started the threads
	std::atomic<bool> cancelRequested{false};
	std::thread readThread;
	std::thread agcThread;

	RingBuffer<uint8_t> sampleBuffer;

	std::atomic<int> frequencyHz{0};
	std::atomic<int> gainIndex{0};
	std::atomic<bool> agcEnabled{true};

	// Updated by onSamples() (the librtlsdr callback thread), read+reset by
	// agcLoop() - same idea as CRTL_TCP_Client's minAmplitude/maxAmplitude.
	std::atomic<uint8_t> minAmplitude{255};
	std::atomic<uint8_t> maxAmplitude{0};
	std::atomic<int64_t> lastGainDecreaseTimeUs{0};
};

#endif
