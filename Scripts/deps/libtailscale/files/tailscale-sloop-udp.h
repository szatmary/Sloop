
// Added by Sloop (Scripts/libtailscale-sloop-udp.go): dials addr ("host:port")
// over the tailnet and writes a *datagram* socket fd to conn_out, where one
// write is one UDP packet. tailscale_dial's own fd is a stream and cannot carry
// UDP whatever network string it is given — a stream has no message boundaries,
// and mosh puts one SSP frame in each packet.
extern int TsnetDialUDP(tailscale sd, const char* addr, tailscale_conn* conn_out);
