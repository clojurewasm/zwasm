# Pinned std.Io.net windows sockets are raw NT/AFD handles — winsock APIs are unusable on them

The Zig 0.16 `std.Io.Threaded` windows networking backend creates
sockets via NT syscalls (AFD device), NOT winsock: WSAStartup is never
called anywhere in the stdlib, and the resulting HANDLEs are not
registered with the winsock provider. Consequences for any direct
`extern "ws2_32"` call on those handles:

- WSAPoll first fails 10093 WSANOTINITIALISED (no WSAStartup in the
  process); after a manual WSAStartup it fails 10038 WSAENOTSOCK (the
  handle is not a winsock SOCKET). select() etc. share the fate.
- The working readiness primitive is the NT-native IOCTL_AFD_POLL
  (0x00012024) issued on the socket handle itself via
  `ntdll.NtDeviceIoControlFile` (the wepoll/libuv/mio approach):
  AFD_POLL_INFO{timeout=0, 1 handle, AFD_POLL_* events}; STATUS_TIMEOUT
  or 0 returned handles = not ready. POLL_IN ⇒
  RECEIVE|DISCONNECT|ABORT|ACCEPT|CONNECT_FAIL, POLL_OUT ⇒ SEND.
- Sibling stdlib gap: the AFD connect path leaves NTSTATUS 0xC0000236
  (CONNECTION_REFUSED) unmapped → error.Unexpected (D-323).

Investigation pattern that found it (D-319, probes #1–#6): a windows
hang at 1h-timeout granularity was bisected with a `-Dd319-probe`
build flag (selective de-skip), then per-probe WSAGetLastError/NTSTATUS
logging — each probe cycle landed a PERMANENT diagnostic before
re-running. The "hang" was a guest poll loop spinning on never-ready
readiness; nothing was deadlocked.
