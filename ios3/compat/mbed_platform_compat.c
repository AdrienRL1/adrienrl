// mbedtls platform_util replacements that avoid clock_gettime/CLOCK_MONOTONIC,
// which do not exist on iOS 3.1. Built instead of mbedtls library/platform_util.c.
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <stdlib.h>
#include <stdint.h>

typedef int64_t mbedtls_ms_time_t;

void mbedtls_platform_zeroize(void *buf, size_t len) {
    if (buf != NULL && len > 0) {
        volatile unsigned char *p = (volatile unsigned char *)buf;
        while (len--) *p++ = 0;
    }
}

void mbedtls_zeroize_and_free(void *buf, size_t len) {
    if (buf != NULL) { mbedtls_platform_zeroize(buf, len); free(buf); }
}

struct tm *mbedtls_platform_gmtime_r(const time_t *tt, struct tm *tm_buf) {
    return gmtime_r(tt, tm_buf);
}

mbedtls_ms_time_t mbedtls_ms_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (mbedtls_ms_time_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}
