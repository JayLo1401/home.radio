// Raw ioctl(USBDEVFS_BULK) USB bulk transfer, bypassing Android's Java-level
// UsbDeviceConnection.bulkTransfer() JNI bridge. Added 2026-09-16 after
// decompiling the real, confirmed-working reference app (com.zoulou.dab /
// DAB-Z) and finding its native DAB decode library (libirtdab.so) directly
// imports the libc `ioctl` symbol - meaning its actual USB I/O doesn't
// exclusively go through Java's bulkTransfer() the way the public LGPL-2.1
// reference source we've otherwise matched byte-for-byte does. Likely
// reason: avoiding bulkTransfer()'s per-call JNI/Java marshaling overhead,
// which this project's own measurements showed made no difference when
// *reducing the number* of such calls, but never ruled out the per-call
// cost of the call itself.
//
// UsbDeviceConnection.getFileDescriptor() exposes the same underlying
// /dev/bus/usb/BBB/DDD file descriptor Java's own bulkTransfer()
// ultimately operates on - so this works against an already-open,
// already-interface-claimed connection; no separate open()/claimInterface()
// is needed here.

#include <jni.h>
#include <android/log.h>
#include <cerrno>
#include <cstring>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

#define LOG_TAG "DabProbe"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

extern "C" JNIEXPORT jint JNICALL
Java_org_lotzapp_home_1radio_dab_NativeUsbIo_bulkTransfer(
        JNIEnv *env, jobject /*thiz*/, jint fd, jint endpoint, jbyteArray data,
        jint offset, jint length, jint timeoutMs) {
    jbyte *buf = env->GetByteArrayElements(data, nullptr);
    if (!buf) return -1;

    struct usbdevfs_bulktransfer bulk{};
    bulk.ep = static_cast<unsigned int>(endpoint);
    bulk.len = static_cast<unsigned int>(length);
    bulk.timeout = static_cast<unsigned int>(timeoutMs);
    bulk.data = buf + offset;

    int ret = ioctl(fd, USBDEVFS_BULK, &bulk);
    if (ret < 0) {
        LOGW("USBDEVFS_BULK failed on ep=0x%02x len=%d: errno=%d (%s)", endpoint, length, errno, strerror(errno));
    }
    // Always commit (mode 0) rather than JNI_ABORT: for an IN transfer this
    // writes the received bytes back into the Java array; for OUT it's a
    // harmless no-op copy since the kernel doesn't modify the buffer.
    env->ReleaseByteArrayElements(data, buf, 0);
    return ret < 0 ? -1 : ret;
}
