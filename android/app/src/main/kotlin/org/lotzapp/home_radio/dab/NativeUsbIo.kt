package org.lotzapp.home_radio.dab

/**
 * Raw ioctl(USBDEVFS_BULK) bulk transfer, bypassing Android's Java-level
 * UsbDeviceConnection.bulkTransfer() - see usb_ioctl.cpp's doc comment for
 * why (the real, working reference app's native library directly imports
 * `ioctl`, meaning it doesn't exclusively use the Java bulkTransfer() path
 * the public LGPL-2.1 reference source we've been matching uses). Operates
 * on the same already-open, already interface-claimed connection via its
 * raw file descriptor (UsbDeviceConnection.getFileDescriptor()) - no
 * separate device open/claim needed.
 */
object NativeUsbIo {
    init {
        System.loadLibrary("dabnative")
    }

    /**
     * @param endpoint the endpoint ADDRESS (UsbEndpoint.address - direction
     * bit included), not just its number.
     * @return bytes transferred, or -1 on failure/timeout.
     */
    external fun bulkTransfer(fd: Int, endpoint: Int, data: ByteArray, offset: Int, length: Int, timeoutMs: Int): Int
}
