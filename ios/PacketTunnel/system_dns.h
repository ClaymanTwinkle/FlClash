#ifndef FLCLASH_SYSTEM_DNS_H
#define FLCLASH_SYSTEM_DNS_H

#include <stddef.h>
#include <stdint.h>

// The resolvers iOS uses for one interface, or the default ones for index 0,
// comma-separated; returns how many, or -1 when the configuration is unreadable.
int flclash_network_dns(uint32_t if_index, char *buffer, size_t size);

#endif
