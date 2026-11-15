#include "utun.h"

#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// The iOS SDK leaves out sys/kern_control.h, so the control-socket types and
// the ioctl that name a utun socket are declared here, as WireGuard does.
#define FLCLASH_AF_SYSTEM 32
#define FLCLASH_CTLIOCGINFO 0xc0644e03UL

struct flclash_ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};

struct flclash_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

int flclash_utun_fd(void) {
    struct flclash_ctl_info info;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name) - 1);
    for (int fd = 0; fd <= 1024; fd++) {
        struct flclash_sockaddr_ctl addr;
        socklen_t len = sizeof(addr);
        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != FLCLASH_AF_SYSTEM) {
            continue;
        }
        if (info.ctl_id == 0 && ioctl(fd, FLCLASH_CTLIOCGINFO, &info) != 0) {
            continue;
        }
        if (addr.sc_id == info.ctl_id) {
            return fd;
        }
    }
    return -1;
}
