// Optimized builds define _FORTIFY_SOURCE, whose glibc open() wrappers use
// GCC builtins that translate-c rejects. Fortification only affects C callers.
#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
