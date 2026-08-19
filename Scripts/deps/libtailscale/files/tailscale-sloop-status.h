
// Added by Sloop (Scripts/libtailscale-sloop-status.go): writes
// "<BackendState>\n<AuthURL>" into buf. BackendState is tsnet's own
// vocabulary ("NeedsLogin", "Starting", "Running"); AuthURL is empty unless
// this device is waiting to be authorized.
//
// Appended to upstream's tailscale.h rather than shipped as a second header:
// cgo emits TsnetSloopStatus as a plain C symbol in the same archive, and a
// separate header would need its own entry in the module map for no gain.
extern int TsnetSloopStatus(int sd, char* buf, size_t buflen);
