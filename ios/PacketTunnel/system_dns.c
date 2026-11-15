#include "system_dns.h"

#include <arpa/inet.h>
#include <resolv.h>
#include <string.h>

int flclash_system_dns(char *buffer, size_t size) {
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        return -1;
    }
    union res_sockaddr_union servers[MAXNS];
    int count = res_getservers(&state, servers, MAXNS);
    buffer[0] = '\0';
    size_t used = 0;
    for (int i = 0; i < count; i++) {
        char address[INET6_ADDRSTRLEN] = {0};
        if (servers[i].sin.sin_family == AF_INET) {
            inet_ntop(AF_INET, &servers[i].sin.sin_addr, address, sizeof(address));
        } else if (servers[i].sin6.sin6_family == AF_INET6) {
            inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, address, sizeof(address));
        } else {
            continue;
        }
        size_t length = strlen(address);
        if (used + length + 2 > size) {
            break;
        }
        if (used > 0) {
            buffer[used++] = ',';
        }
        memcpy(buffer + used, address, length + 1);
        used += length;
    }
    res_ndestroy(&state);
    return count;
}
