#include "system_dns.h"

#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>

// dnsinfo.h ships in no SDK. These are the DNSINFO_VERSION 20170629 layouts
// from apple-oss-distributions/configd, which libsystem_configuration fills;
// dns_configuration_copy and dns_configuration_free are its exports.
#pragma pack(4)
typedef struct {
    struct in_addr address;
    struct in_addr mask;
} flclash_dns_sortaddr;

typedef struct {
    char *domain;
    int32_t n_nameserver;
    struct sockaddr **nameserver;
    uint16_t port;
    int32_t n_search;
    char **search;
    int32_t n_sortaddr;
    flclash_dns_sortaddr **sortaddr;
    char *options;
    uint32_t timeout;
    uint32_t search_order;
    uint32_t if_index;
    uint32_t flags;
    uint32_t reach_flags;
    uint32_t service_identifier;
    char *cid;
    char *if_name;
} flclash_dns_resolver;

typedef struct {
    int32_t n_resolver;
    flclash_dns_resolver **resolver;
    int32_t n_scoped_resolver;
    flclash_dns_resolver **scoped_resolver;
    uint64_t generation;
    int32_t n_service_specific_resolver;
    flclash_dns_resolver **service_specific_resolver;
    uint32_t version;
} flclash_dns_config;
#pragma pack()

static flclash_dns_resolver *pick_resolver(flclash_dns_config *config, uint32_t if_index) {
    if (if_index != 0) {
        for (int32_t i = 0; i < config->n_scoped_resolver; i++) {
            flclash_dns_resolver *resolver = config->scoped_resolver[i];
            if (resolver->if_index == if_index && resolver->n_nameserver > 0) {
                return resolver;
            }
        }
        return NULL;
    }
    for (int32_t i = 0; i < config->n_resolver; i++) {
        flclash_dns_resolver *resolver = config->resolver[i];
        if (resolver->domain == NULL && resolver->n_nameserver > 0) {
            return resolver;
        }
    }
    return NULL;
}

int flclash_network_dns(uint32_t if_index, char *buffer, size_t size) {
    flclash_dns_config *(*copy)(void) = dlsym(RTLD_DEFAULT, "dns_configuration_copy");
    void (*release)(flclash_dns_config *) = dlsym(RTLD_DEFAULT, "dns_configuration_free");
    if (copy == NULL || release == NULL || size == 0) {
        return -1;
    }
    flclash_dns_config *config = copy();
    if (config == NULL) {
        return -1;
    }
    buffer[0] = '\0';
    size_t used = 0;
    int count = 0;
    flclash_dns_resolver *resolver = pick_resolver(config, if_index);
    for (int32_t i = 0; resolver != NULL && i < resolver->n_nameserver; i++) {
        struct sockaddr *server = resolver->nameserver[i];
        char address[INET6_ADDRSTRLEN] = {0};
        if (server->sa_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)server)->sin_addr, address, sizeof(address));
        } else if (server->sa_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)server)->sin6_addr, address, sizeof(address));
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
        count++;
    }
    release(config);
    return count;
}
