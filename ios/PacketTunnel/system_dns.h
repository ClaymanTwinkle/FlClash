#ifndef FLCLASH_SYSTEM_DNS_H
#define FLCLASH_SYSTEM_DNS_H

#include <stddef.h>

// The resolvers of the network the device is on, comma-separated, read before
// the tunnel installs its own; returns how many there were, or -1.
int flclash_system_dns(char *buffer, size_t size);

#endif
