#ifndef RTL_TCP_BRIDGE_H
#define RTL_TCP_BRIDGE_H

/*
 * Declarations for the small Android-specific additions to rtl_tcp.c (see
 * that file for details). Kept in a separate header rather than rtl-sdr.h
 * since these are specific to our bundled rtl_tcp server, not the library.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Must be called with a valid, permitted USB file descriptor before
 * rtl_tcp_main() - makes rtl_tcp_main() open that device via
 * rtlsdr_open_from_fd() instead of enumerating USB devices. */
void rtl_tcp_set_usb_fd(int fd);

/* Same signature/behavior as rtl_tcp's own CLI main(): argv[0] should be a
 * dummy program name, the rest are the usual rtl_tcp options (-a, -p, -f,
 * -s, -g, ...). Blocks until the server is stopped - call on a dedicated
 * thread. Returns <0 on startup failure (e.g. device open failure). */
int rtl_tcp_main(int argc, char **argv);

/* Signals a running rtl_tcp_main() call to shut down and return. */
void rtl_tcp_request_exit(void);

#ifdef __cplusplus
}
#endif

#endif /* RTL_TCP_BRIDGE_H */
