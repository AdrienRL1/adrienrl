#import "HTTPSClient.h"
#import "Localization.h"
#import <CFNetwork/CFNetwork.h>   // CFNetworkCopySystemProxySettings (system HTTP proxy)
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/debug.h"

static NSError *mkErr(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"HTTPSClient" code:code
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// DNS-over-HTTPS fallback. When the system resolver can't look a host up — e.g. a carrier
// blocks it at the DNS level (the "DNS: nodename nor servname provided" failure some users in
// censored regions hit on every download) — resolve it ourselves via Google's DoH JSON API,
// reached by its LITERAL IP 8.8.8.8 so it needs no DNS itself. Certs aren't verified here
// (VERIFY_NONE), so the IP-as-SNI handshake is fine (tested OK). The JSON is extracted as the
// {...} span so it's robust to chunked transfer-encoding. Returns an A-record IP, or nil.
// Cached per host for the session. Only used as a FALLBACK after getaddrinfo fails.
static NSString *HC_resolveViaDoH(NSString *host) {
    if (!host.length) return nil;
    // Never DoH a literal IP — pointless, and prevents recursion via the 8.8.8.8 request below.
    struct in_addr a4; struct in6_addr a6;
    if (inet_pton(AF_INET, [host UTF8String], &a4) == 1 ||
        inet_pton(AF_INET6, [host UTF8String], &a6) == 1) return nil;

    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) { NSString *hit = [cache objectForKey:host]; if (hit) return hit; }

    NSString *u = [NSString stringWithFormat:@"https://8.8.8.8/resolve?name=%@&type=A", host];
    NSInteger code = 0;
    NSData *d = [HTTPSClient getSyncURL:u timeout:10 statusCode:&code error:NULL];
    if (!d.length || code != 200) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    NSRange lo = [s rangeOfString:@"{"];
    NSRange hi = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (lo.location == NSNotFound || hi.location == NSNotFound || hi.location < lo.location) return nil;
    NSData *jd = [[s substringWithRange:NSMakeRange(lo.location, hi.location - lo.location + 1)]
                    dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id ans = [(NSDictionary *)obj objectForKey:@"Answer"];
    if (![ans isKindOfClass:[NSArray class]]) return nil;
    for (id rec in (NSArray *)ans) {
        if (![rec isKindOfClass:[NSDictionary class]]) continue;
        if ([[rec objectForKey:@"type"] intValue] != 1) continue;   // A record (IPv4) only
        id ip = [rec objectForKey:@"data"];
        if ([ip isKindOfClass:[NSString class]] && [ip length]) {
            @synchronized (cache) { [cache setObject:ip forKey:host]; }
            return ip;
        }
    }
    return nil;
}

// Custom socket send/recv callbacks for mbedTLS (use raw sockets to bypass iOS TLS stack)
static int sock_send(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = send(fd, buf, len, 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return (int)n;
}

static int sock_recv(void *ctx, unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = recv(fd, buf, len, 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    if (n == 0) return MBEDTLS_ERR_SSL_CONN_EOF;
    return (int)n;
}

@implementation HTTPSClient

// Manual percent-encode for path, preserving URL-safe chars. iOS 5+ compatible.
// Read the iOS system's MANUAL HTTP/HTTPS proxy (Wi-Fi → HTTP Proxy → Manual), if any.
// Returns the proxy host (and *outPort) or nil. Auto-config (PAC) / SOCKS are intentionally
// ignored — only a simple host:port proxy is honored. (Reddit: "Need http proxy support".)
static NSString *HC_systemProxyHost(BOOL forHTTPS, int *outPort) {
    (void)forHTTPS;  // iOS exposes ONE manual proxy (the HTTP keys); it's used for HTTP AND
                     // HTTPS (the latter via a CONNECT tunnel). The HTTPS-specific keys are
                     // macOS-only, so we read only the HTTP keys here.
    NSDictionary *cfg = (NSDictionary *)CFBridgingRelease(CFNetworkCopySystemProxySettings());
    if (![cfg isKindOfClass:[NSDictionary class]]) return nil;
    if (![cfg[(NSString *)kCFNetworkProxiesHTTPEnable] boolValue]) return nil;
    NSString *host = cfg[(NSString *)kCFNetworkProxiesHTTPProxy];
    int port = [cfg[(NSString *)kCFNetworkProxiesHTTPPort] intValue];
    if (![host isKindOfClass:[NSString class]] || !host.length || port <= 0) return nil;
    if (outPort) *outPort = port;
    return host;
}

// Connect to proxyHost:proxyPort and, for an HTTPS target, open a CONNECT tunnel to
// targetHost:targetPort so the caller can TLS-handshake straight to the target. For a plain
// HTTP target, *outHTTPViaProxy is set YES (caller must use an absolute-URI request line).
// Returns a ready fd, or -1 on ANY failure (caller then falls back to a direct connect).
static int HC_proxyConnect(NSString *proxyHost, int proxyPort, NSString *targetHost, int targetPort,
                           BOOL isHTTPS, NSTimeInterval timeout, BOOL *outHTTPViaProxy) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    char portStr[16]; snprintf(portStr, sizeof(portStr), "%d", proxyPort);
    if (getaddrinfo([proxyHost UTF8String], portStr, &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    struct timeval tv; tv.tv_sec = (long)timeout; tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) { freeaddrinfo(res); close(fd); return -1; }
    freeaddrinfo(res);
    if (isHTTPS) {
        NSString *c = [NSString stringWithFormat:
            @"CONNECT %@:%d HTTP/1.0\r\nHost: %@:%d\r\n\r\n", targetHost, targetPort, targetHost, targetPort];
        NSData *cd = [c dataUsingEncoding:NSUTF8StringEncoding];
        if (send(fd, cd.bytes, cd.length, 0) != (ssize_t)cd.length) { close(fd); return -1; }
        char buf[1024]; ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) { close(fd); return -1; }
        buf[n] = 0;
        if (!strstr(buf, " 200")) { close(fd); return -1; }   // tunnel refused → fall back to direct
    } else if (outHTTPViaProxy) {
        *outHTTPViaProxy = YES;
    }
    return fd;
}

+ (NSString *)percentEncodePath:(NSString *)src {
    // If already encoded (contains %XX), return as-is
    if ([src rangeOfString:@"%"].location != NSNotFound) return src;
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~/!$&'*+,;=:@"];
    NSMutableString *out = [NSMutableString stringWithCapacity:src.length];
    NSData *bytes = [src dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        unsigned char c = p[i];
        if (c < 128 && [safe characterIsMember:c]) {
            [out appendFormat:@"%c", c];
        } else {
            [out appendFormat:@"%%%02X", c];
        }
    }
    return out;
}

// Sanitize a full URL string so [NSURL URLWithString:] won't return nil.
// NSURL chokes on unencoded spaces, accents, brackets, etc. in the path.
// We split scheme://host/path?query and percent-encode the path + query parts.
+ (NSString *)sanitizeURLString:(NSString *)urlStr {
    if (!urlStr.length) return urlStr;
    // Find scheme://
    NSRange schemeEnd = [urlStr rangeOfString:@"://"];
    if (schemeEnd.location == NSNotFound) {
        // No scheme — just encode the whole thing as path
        return [self percentEncodePath:urlStr];
    }
    NSUInteger afterScheme = NSMaxRange(schemeEnd);
    NSString *schemePart = [urlStr substringToIndex:afterScheme];  // "https://"
    NSString *rest = [urlStr substringFromIndex:afterScheme];

    // Find first '/' after the host
    NSRange firstSlash = [rest rangeOfString:@"/"];
    NSString *hostPart;
    NSString *pathQuery;
    if (firstSlash.location == NSNotFound) {
        hostPart = rest;
        pathQuery = @"";
    } else {
        hostPart = [rest substringToIndex:firstSlash.location];
        pathQuery = [rest substringFromIndex:firstSlash.location];
    }

    // Split path and query
    NSString *encodedPathQuery;
    NSRange queryStart = [pathQuery rangeOfString:@"?"];
    if (queryStart.location == NSNotFound) {
        encodedPathQuery = [self percentEncodePath:pathQuery];
    } else {
        NSString *p = [pathQuery substringToIndex:queryStart.location];
        NSString *q = [pathQuery substringFromIndex:NSMaxRange(queryStart)];

        // CRITICAL: if the query already contains %-encoded chars, treat it as
        // already-encoded and pass through verbatim. Otherwise we'd re-encode
        // % itself → %3A becomes %253A, invalidating any signature. This bites
        // hard on GitHub release downloads, where github.com 302-redirects to
        // a signed URL on release-assets.githubusercontent.com (Azure Blob) with
        // SAS query params like `sig=...%2F...`, `se=...%3A...`. Double-encoding
        // those broke the signature → Azure returned 403 → in-app updater failed.
        NSString *encQ;
        if ([q rangeOfString:@"%"].location != NSNotFound) {
            encQ = q;
        } else {
            // Query has no %-encoded chars yet — encode unsafe ones the standard way.
            NSCharacterSet *querySafe = [NSCharacterSet characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~&=:@/?"];
            NSMutableString *enc = [NSMutableString stringWithCapacity:q.length];
            NSData *qbytes = [q dataUsingEncoding:NSUTF8StringEncoding];
            const unsigned char *qp = qbytes.bytes;
            for (NSUInteger i = 0; i < qbytes.length; i++) {
                unsigned char c = qp[i];
                if (c < 128 && [querySafe characterIsMember:c]) {
                    [enc appendFormat:@"%c", c];
                } else {
                    [enc appendFormat:@"%%%02X", c];
                }
            }
            encQ = enc;
        }
        encodedPathQuery = [NSString stringWithFormat:@"%@?%@",
                              [self percentEncodePath:p], encQ];
    }

    return [NSString stringWithFormat:@"%@%@%@", schemePart, hostPart, encodedPathQuery];
}

+ (NSData *)buildHTTPRequestBody:(NSString *)method
                             path:(NSString *)path
                             host:(NSString *)host
                          headers:(NSDictionary *)extraHeaders
                             body:(NSData *)body {
    NSMutableString *h = [NSMutableString string];
    // Use HTTP/1.0 deliberately: our reader doesn't parse Transfer-Encoding: chunked,
    // which is the default response framing for HTTP/1.1. HTTP/1.0 servers reply with
    // Content-Length or close-to-signal-end. Both are handled below.
    [h appendFormat:@"%@ %@ HTTP/1.0\r\n", method ?: @"GET", path];
    [h appendFormat:@"Host: %@\r\n", host];
    // Use a browser-like UA — Google Translate TTS / some CDNs block unknown UAs.
    [h appendString:@"User-Agent: Mozilla/5.0 (iPad; CPU OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25\r\n"];
    [h appendString:@"Accept: */*\r\n"];
    [h appendString:@"Connection: close\r\n"];
    for (NSString *k in extraHeaders) {
        [h appendFormat:@"%@: %@\r\n", k, extraHeaders[k]];
    }
    if (body.length > 0) {
        [h appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    }
    [h appendString:@"\r\n"];
    NSMutableData *d = [NSMutableData dataWithData:[h dataUsingEncoding:NSUTF8StringEncoding]];
    if (body.length > 0) [d appendData:body];
    return d;
}

+ (NSData *)getSyncURL:(NSString *)urlStr
               timeout:(NSTimeInterval)timeout
            statusCode:(NSInteger *)outStatusCode
                 error:(NSError **)outError {
    return [self requestSync:@"GET" url:urlStr headers:nil body:nil
                       timeout:timeout statusCode:outStatusCode error:outError];
}

+ (NSData *)requestSync:(NSString *)method
                     url:(NSString *)urlStr
                 headers:(NSDictionary *)extraHeaders
                    body:(NSData *)reqBody
                 timeout:(NSTimeInterval)timeout
              statusCode:(NSInteger *)outStatusCode
                   error:(NSError **)outError {
    if (outStatusCode) *outStatusCode = 0;
    if (outError) *outError = nil;

    // Sanitize first: archive.org IPA URLs often contain spaces ("iOS 5/", "iPhoneOS 2/").
    // NSURL URLWithString: returns nil on those — pre-encode the path/query.
    NSString *cleanUrl = [self sanitizeURLString:urlStr];
    NSURL *url = [NSURL URLWithString:cleanUrl];
    if (!url || !url.host) {
        if (outError) *outError = mkErr(1, [NSString stringWithFormat:@"URL invalide: %@",
                                              urlStr.length > 80 ? [urlStr substringToIndex:80] : urlStr]);
        return nil;
    }
    BOOL isHTTPS = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSInteger port = url.port ? url.port.integerValue : (isHTTPS ? 443 : 80);
    NSString *host = url.host;
    NSString *path = url.path.length ? url.path : @"/";
    if (url.query.length) {
        path = [NSString stringWithFormat:@"%@?%@", path, url.query];
    }

    // ---- TCP connection ----
    // Honor a manual iOS HTTP/HTTPS proxy (Wi-Fi → HTTP Proxy) if one is set: route through it
    // (CONNECT tunnel for HTTPS). No proxy → the direct connect below runs EXACTLY as before
    // (zero change for proxy-less users). A proxy failure also falls through to direct.
    BOOL httpViaProxy = NO;
    int fd = -1;
    { int pPort = 0; NSString *proxy = HC_systemProxyHost(isHTTPS, &pPort);
      if (proxy.length) fd = HC_proxyConnect(proxy, pPort, host, (int)port, isHTTPS, timeout, &httpViaProxy); }
    if (fd < 0) {
        struct addrinfo hints = {0}, *res = NULL;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        char portStr[16];
        snprintf(portStr, sizeof(portStr), "%d", (int)port);
        int gaErr = getaddrinfo([host UTF8String], portStr, &hints, &res);
        if (gaErr != 0 || !res) {
            // System DNS failed — fall back to DNS-over-HTTPS, then connect to the resolved IP
            // (SNI/Host stay the original host, set below, so TLS + CDN routing still work).
            NSString *dohIP = HC_resolveViaDoH(host);
            if (dohIP.length) {
                struct addrinfo nh = {0};
                nh.ai_family = AF_UNSPEC; nh.ai_socktype = SOCK_STREAM; nh.ai_flags = AI_NUMERICHOST;
                res = NULL;
                gaErr = getaddrinfo([dohIP UTF8String], portStr, &nh, &res);
            }
            if (gaErr != 0 || !res) {
                if (outError) *outError = mkErr(2, [NSString stringWithFormat:@"DNS failed: %s",
                                                      gai_strerror(gaErr)]);
                return nil;
            }
        }
        fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd < 0) {
            freeaddrinfo(res);
            if (outError) *outError = mkErr(3, @"socket() failed");
            return nil;
        }
        // Socket timeouts (use timeout for both send and recv)
        struct timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
            freeaddrinfo(res);
            close(fd);
            if (outError) *outError = mkErr(4, [NSString stringWithFormat:@"connect() failed: %s",
                                                  strerror(errno)]);
            return nil;
        }
        freeaddrinfo(res);
    }
    // A plain-HTTP request through a proxy must use an absolute-URI request line.
    if (httpViaProxy && !isHTTPS) {
        path = (port == 80) ? [NSString stringWithFormat:@"http://%@%@", host, path]
                            : [NSString stringWithFormat:@"http://%@:%d%@", host, (int)port, path];
    }

    NSData *body = nil;
    NSData *reqData = [self buildHTTPRequestBody:method path:path host:host
                                          headers:extraHeaders body:reqBody];

    if (!isHTTPS) {
        ssize_t sent = send(fd, reqData.bytes, reqData.length, 0);
        if (sent != (ssize_t)reqData.length) {
            close(fd);
            if (outError) *outError = mkErr(5, @"send() failed");
            return nil;
        }
        body = [self readHTTPResponseFromSocket:fd statusCode:outStatusCode];
        close(fd);
        return body;
    }

    // ---- TLS handshake via mbedTLS ----
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;

    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    int ret = 0;
    const char *pers = "IPAInstaller";
    NSError *err = nil;

    do {
        ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                    (const unsigned char *)pers, strlen(pers));
        if (ret != 0) { err = mkErr(10, @"ctr_drbg_seed failed"); break; }

        ret = mbedtls_ssl_config_defaults(&conf,
                                          MBEDTLS_SSL_IS_CLIENT,
                                          MBEDTLS_SSL_TRANSPORT_STREAM,
                                          MBEDTLS_SSL_PRESET_DEFAULT);
        if (ret != 0) { err = mkErr(11, @"ssl_config_defaults failed"); break; }

        // No cert verification (insecure but acceptable for public IPA downloads)
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);

        // Force TLS 1.2 (most compatible with archive.org and our build)
        mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);

        ret = mbedtls_ssl_setup(&ssl, &conf);
        if (ret != 0) { err = mkErr(12, @"ssl_setup failed"); break; }

        ret = mbedtls_ssl_set_hostname(&ssl, [host UTF8String]);
        if (ret != 0) { err = mkErr(13, @"ssl_set_hostname failed"); break; }

        // BIO with our raw socket
        mbedtls_ssl_set_bio(&ssl, &fd, sock_send, sock_recv, NULL);

        // Handshake
        while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
            if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
                char errbuf[256] = {0};
                mbedtls_strerror(ret, errbuf, sizeof(errbuf));
                err = mkErr(14, [NSString stringWithFormat:@"TLS handshake: %s (-0x%x)",
                                  errbuf, -ret]);
                break;
            }
        }
        if (err) break;

        // Send HTTP request (with method, headers, body)
        const unsigned char *reqBytes = (const unsigned char *)reqData.bytes;
        size_t reqLen = reqData.length;
        size_t written = 0;
        while (written < reqLen) {
            int n = mbedtls_ssl_write(&ssl, reqBytes + written, reqLen - written);
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n < 0) {
                err = mkErr(15, [NSString stringWithFormat:@"ssl_write -0x%x", -n]);
                break;
            }
            written += n;
        }
        if (err) break;

        // Read response
        NSMutableData *raw = [NSMutableData data];
        unsigned char buf[8192];
        while (1) {
            int n = mbedtls_ssl_read(&ssl, buf, sizeof(buf));
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) break;
            if (n == MBEDTLS_ERR_SSL_CONN_EOF) break;
            if (n <= 0) {
                if (raw.length > 0) break;
                err = mkErr(16, [NSString stringWithFormat:@"ssl_read -0x%x", -n]);
                break;
            }
            [raw appendBytes:buf length:n];
        }
        if (err) break;

        // Parse HTTP response
        body = [self parseHTTPResponse:raw statusCode:outStatusCode];

        mbedtls_ssl_close_notify(&ssl);
    } while (0);

    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    close(fd);

    if (err) {
        if (outError) *outError = err;
        return nil;
    }
    return body;
}

// Read raw HTTP response from plain socket
+ (NSData *)readHTTPResponseFromSocket:(int)fd statusCode:(NSInteger *)outStatusCode {
    NSMutableData *raw = [NSMutableData data];
    unsigned char buf[8192];
    while (1) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [raw appendBytes:buf length:n];
    }
    return [self parseHTTPResponse:raw statusCode:outStatusCode];
}

// Parse HTTP response, return body bytes
+ (NSData *)parseHTTPResponse:(NSData *)raw statusCode:(NSInteger *)outStatusCode {
    if (raw.length == 0) return nil;
    const char *bytes = (const char *)raw.bytes;
    NSUInteger len = raw.length;

    // Find \r\n\r\n (end of headers)
    NSUInteger headerEnd = NSNotFound;
    for (NSUInteger i = 0; i + 3 < len; i++) {
        if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
            bytes[i+2] == '\r' && bytes[i+3] == '\n') {
            headerEnd = i;
            break;
        }
    }
    if (headerEnd == NSNotFound) return nil;

    // Parse status line: "HTTP/1.x 200 OK\r\n"
    if (outStatusCode) {
        NSString *firstLine = [[NSString alloc] initWithBytes:bytes
                                                        length:MIN(headerEnd, 64)
                                                      encoding:NSASCIIStringEncoding];
        NSArray *parts = [firstLine componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            *outStatusCode = [parts[1] integerValue];
        }
    }

    NSUInteger bodyStart = headerEnd + 4;
    if (bodyStart >= len) return [NSData data];
    return [NSData dataWithBytes:bytes + bodyStart length:len - bodyStart];
}

+ (void)getURL:(NSString *)url
        timeout:(NSTimeInterval)timeout
     completion:(void (^)(NSData *, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger code = 0;
        NSError *err = nil;
        NSData *body = [self getSyncURL:url timeout:timeout
                              statusCode:&code error:&err];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(body, code, err);
            });
        }
    });
}

+ (void)postURL:(NSString *)url
        headers:(NSDictionary *)headers
            body:(NSData *)body
         timeout:(NSTimeInterval)timeout
      completion:(void (^)(NSData *, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger code = 0;
        NSError *err = nil;
        NSData *resp = [self requestSync:@"POST" url:url headers:headers body:body
                                  timeout:timeout statusCode:&code error:&err];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(resp, code, err);
            });
        }
    });
}

#pragma mark - Streaming download with redirects

+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)filePath
            progress:(void (^)(long long, long long))progressBlock
          completion:(void (^)(BOOL, NSInteger, NSError *))completion {
    [self downloadURL:url toFile:filePath isCancelled:nil
              progress:progressBlock completion:completion];
}

+ (void)downloadChunk:(NSString *)url
              fromByte:(long long)startByte
                toByte:(long long)endByte
                toFile:(NSString *)chunkPath
           isCancelled:(BOOL (^)(void))isCancelled
              progress:(void (^)(long long, long long))progressBlock
            completion:(void (^)(BOOL, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Same archive.org HTTPS→HTTP front-end downgrade as downloadURL:
        NSString *effectiveURL = url;
        if ([url hasPrefix:@"https://"]
            && ([url rangeOfString:@"archive.org"].location != NSNotFound)) {
            effectiveURL = [@"http://" stringByAppendingString:[url substringFromIndex:8]];
        }
        NSInteger status = 0;
        NSError *err = nil;
        BOOL ok = NO;
        // Retry on transient server errors. Partial chunk file survives between
        // attempts and downloadSync resumes via Range: bytes=N-end.
        for (int attempt = 0; attempt < 4; attempt++) {
            if (isCancelled && isCancelled()) {
                err = mkErr(99, T(@"common.cancelled"));
                status = -1;
                break;
            }
            status = 0; err = nil;
            ok = [self downloadSync:effectiveURL toFile:chunkPath
                         chunkStart:startByte chunkEnd:endByte
                        outFullSize:NULL
                        isCancelled:isCancelled
                           progress:progressBlock
                         statusCode:&status error:&err
                      redirectsLeft:10];
            if (ok) break;
            if (err.code == 99) break;
            BOOL retryable = (status == 502 || status == 503 || status == 504);
            if (!retryable) break;
            NSTimeInterval delay = 1.0 * (1 << attempt);
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:delay];
            while ([until timeIntervalSinceNow] > 0) {
                if (isCancelled && isCancelled()) break;
                [NSThread sleepForTimeInterval:0.2];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, status, err); });
        }
    });
}

+ (void)probeURL:(NSString *)url
       completion:(void (^)(long long totalSize, BOOL rangeSupported, NSError *err))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Strategy: do a tiny Range request (bytes=0-0) via the full redirect-
        // following downloadSync chunk path. The chunk writes 1 byte to a temp
        // file (which we discard) and we get the resource's full size via
        // outFullSize (from the Content-Range header parsed inside downloadSync).
        //
        // Apply the same archive.org HTTPS→HTTP downgrade as downloadURL: so
        // the chain ends on a CDN node where TLS works.
        NSString *effectiveURL = url;
        if ([url hasPrefix:@"https://"]
            && ([url rangeOfString:@"archive.org"].location != NSNotFound)) {
            effectiveURL = [@"http://" stringByAppendingString:[url substringFromIndex:8]];
        }

        NSString *tmpPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"_probe_%@",
                                              [[NSUUID UUID] UUIDString]]];
        long long fullSize = -1;
        NSInteger code = 0;
        NSError *err = nil;
        BOOL ok = [self downloadSync:effectiveURL toFile:tmpPath
                          chunkStart:0 chunkEnd:0
                         outFullSize:&fullSize
                         isCancelled:nil
                            progress:nil
                          statusCode:&code error:&err
                       redirectsLeft:10];
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

        // 206 = server honored Range and gave us Content-Range with the total.
        // 200 = server doesn't support Range — parallel chunks won't work.
        BOOL rangeSupported = (code == 206 && fullSize > 0);
        if (!ok && code != 206) {
            // Network / DNS / etc. — bubble up. Caller falls back to single-stream.
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(-1, NO, err);
            });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(fullSize, rangeSupported, nil);
        });
    });
}

+ (void)downloadURL:(NSString *)url
              toFile:(NSString *)filePath
         isCancelled:(BOOL (^)(void))isCancelled
            progress:(void (^)(long long, long long))progressBlock
          completion:(void (^)(BOOL, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // archive.org's front-end (Fastly) flags mbedTLS's JA3 fingerprint and returns 503
        // to "old TLS clients". We bypass it by hitting the HTTP endpoint on archive.org,
        // which redirects (302) to an HTTP CDN URL. The CDN then responds with 301 → HTTPS
        // (HSTS), but the CDN nodes (dn*.ca.archive.org / ia*.us.archive.org) are stock
        // nginx with Let's Encrypt certs — mbedTLS handshakes fine with them. So the chain
        // ends up: http://archive.org → http://CDN → https://CDN → 200 OK.
        NSString *effectiveURL = url;
        if ([url hasPrefix:@"https://"]
            && ([url rangeOfString:@"archive.org"].location != NSNotFound)) {
            effectiveURL = [@"http://" stringByAppendingString:[url substringFromIndex:8]];
            NSLog(@"[HTTPSClient] Downgraded archive.org entry URL to HTTP (front-end bypass)");
        }
        NSInteger status = 0;
        NSError *err = nil;
        BOOL ok = NO;
        // Retry on transient server errors (502 / 503 / 504). Exponential backoff: 1s, 2s, 4s.
        // Partial files survive between attempts and HTTPSClient resumes them via
        // Range: bytes=N-. Cleanup of the partial file is now the caller's responsibility
        // (InstallManager already deletes on terminal failure / user cancel).
        for (int attempt = 0; attempt < 4; attempt++) {
            if (isCancelled && isCancelled()) {
                err = mkErr(99, T(@"common.cancelled"));
                status = -1;
                break;
            }
            status = 0; err = nil;
            // Whole-file mode: chunkStart=-1, chunkEnd=-1 → use file-size-based
            // resume (legacy behavior).
            ok = [self downloadSync:effectiveURL toFile:filePath
                         chunkStart:-1 chunkEnd:-1
                        outFullSize:NULL
                        isCancelled:isCancelled
                           progress:progressBlock
                         statusCode:&status error:&err
                      redirectsLeft:10];
            if (ok) break;
            // Cancellation surfaces as err.code == 99 — don't retry.
            if (err.code == 99) break;
            BOOL retryable = (status == 502 || status == 503 || status == 504);
            if (!retryable) break;
            NSTimeInterval delay = 1.0 * (1 << attempt);  // 1, 2, 4, 8 sec
            NSLog(@"[HTTPSClient] HTTP %ld — retry %d in %.0fs", (long)status, attempt + 1, delay);
            // Sleep in small slices so cancellation can interrupt the backoff too.
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:delay];
            while ([until timeIntervalSinceNow] > 0) {
                if (isCancelled && isCancelled()) break;
                [NSThread sleepForTimeInterval:0.2];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, status, err); });
        }
    });
}

// Sync, on background queue. Follows redirects via tail recursion.
//
// Two modes:
//   - Whole-file (chunkStart == -1): the local file at `filePath` is treated
//     as a partial download of the whole file. We send Range: bytes=N- with
//     N = current local file size to resume. Total reported in progress is
//     the full file size from Content-Length / Content-Range.
//   - Chunk (chunkStart >= 0): the local file is a partial chunk covering
//     server bytes [chunkStart, chunkEnd]. We send Range: bytes=A-B with
//     A = chunkStart + localChunkSize, B = chunkEnd. Total reported is the
//     chunk size (chunkEnd - chunkStart + 1) so the caller can aggregate
//     progress across multiple parallel chunks.
//
// `outFullSize` (optional): when the server replies 206 with a Content-Range
// "bytes A-B/TOTAL" header, *outFullSize is set to TOTAL. Used by probeURL:
// to learn the resource's full size from a tiny Range request. Pass NULL
// if not needed.
+ (BOOL)downloadSync:(NSString *)urlStr
              toFile:(NSString *)filePath
          chunkStart:(long long)chunkStart
            chunkEnd:(long long)chunkEnd
         outFullSize:(long long *)outFullSize
         isCancelled:(BOOL (^)(void))isCancelled
            progress:(void (^)(long long, long long))progressBlock
          statusCode:(NSInteger *)outStatus
               error:(NSError **)outError
       redirectsLeft:(int)redirectsLeft {
    if (isCancelled && isCancelled()) {
        if (outError) *outError = mkErr(99, T(@"common.cancelled"));
        if (outStatus) *outStatus = -1;
        return NO;
    }
    if (redirectsLeft < 0) {
        if (outError) *outError = mkErr(30, T(@"common.too_many_redirects"));
        return NO;
    }
    NSString *cleanUrl = [self sanitizeURLString:urlStr];
    NSURL *url = [NSURL URLWithString:cleanUrl];
    if (!url || !url.host) {
        if (outError) *outError = mkErr(1, [NSString stringWithFormat:@"URL invalide: %@",
                                              urlStr.length > 80 ? [urlStr substringToIndex:80] : urlStr]); return NO;
    }
    BOOL isHTTPS = [url.scheme.lowercaseString isEqualToString:@"https"];
    NSInteger port = url.port ? url.port.integerValue : (isHTTPS ? 443 : 80);
    NSString *host = url.host;
    NSString *path = url.path.length ? url.path : @"/";
    // Manual percent-encoding: encode space/parens etc. but keep slash/dash/dot/etc.
    // (iOS 7+ NSCharacterSet URLPathAllowedCharacterSet unavailable on iOS 5/6)
    NSString *encPath = [self percentEncodePath:path];
    if (url.query.length) encPath = [NSString stringWithFormat:@"%@?%@", encPath, url.query];

    // ---- TCP (honor a manual iOS HTTP/HTTPS proxy if set; direct otherwise) ----
    BOOL httpViaProxy = NO;
    int fd = -1;
    { int pPort = 0; NSString *proxy = HC_systemProxyHost(isHTTPS, &pPort);
      if (proxy.length) fd = HC_proxyConnect(proxy, pPort, host, (int)port, isHTTPS, 60, &httpViaProxy); }
    if (fd < 0) {
        struct addrinfo hints = {0}, *res = NULL;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        char portStr[16];
        snprintf(portStr, sizeof(portStr), "%d", (int)port);
        int gaErr = getaddrinfo([host UTF8String], portStr, &hints, &res);
        if (gaErr != 0 || !res) {
            // System DNS failed (e.g. a carrier blocks the host at DNS level) — fall back to
            // DNS-over-HTTPS (8.8.8.8 by literal IP) and connect to the resolved IP. SNI/Host
            // stay the original host (set below) so archive.org's CDN still routes correctly.
            NSString *dohIP = HC_resolveViaDoH(host);
            if (dohIP.length) {
                struct addrinfo nh = {0};
                nh.ai_family = AF_UNSPEC; nh.ai_socktype = SOCK_STREAM; nh.ai_flags = AI_NUMERICHOST;
                res = NULL;
                gaErr = getaddrinfo([dohIP UTF8String], portStr, &nh, &res);
            }
            if (gaErr != 0 || !res) {
                if (outError) *outError = mkErr(2, [NSString stringWithFormat:@"DNS: %s", gai_strerror(gaErr)]);
                return NO;
            }
        }
        fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd < 0) {
            freeaddrinfo(res);
            if (outError) *outError = mkErr(3, @"socket()");
            return NO;
        }
        struct timeval tv = { 60, 0 };  // generous timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
            freeaddrinfo(res); close(fd);
            if (outError) *outError = mkErr(4, [NSString stringWithFormat:@"connect: %s", strerror(errno)]);
            return NO;
        }
        freeaddrinfo(res);
    }
    if (httpViaProxy && !isHTTPS) {
        encPath = (port == 80) ? [NSString stringWithFormat:@"http://%@%@", host, encPath]
                               : [NSString stringWithFormat:@"http://%@:%d%@", host, (int)port, encPath];
    }

    // ---- TLS setup (if HTTPS) ----
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    BOOL sslReady = NO;
    NSError *err = nil;

    if (isHTTPS) {
        mbedtls_ssl_init(&ssl);
        mbedtls_ssl_config_init(&conf);
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&drbg);
        do {
            const char *pers = "IPAInstall-dl";
            if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                                       (const unsigned char *)pers, strlen(pers)) != 0)
                { err = mkErr(10, @"drbg"); break; }
            if (mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT,
                                            MBEDTLS_SSL_TRANSPORT_STREAM,
                                            MBEDTLS_SSL_PRESET_DEFAULT) != 0)
                { err = mkErr(11, @"ssl_config"); break; }
            mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
            mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
            mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
            mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
            if (mbedtls_ssl_setup(&ssl, &conf) != 0) { err = mkErr(12, @"setup"); break; }
            if (mbedtls_ssl_set_hostname(&ssl, [host UTF8String]) != 0) { err = mkErr(13, @"hostname"); break; }
            mbedtls_ssl_set_bio(&ssl, &fd, sock_send, sock_recv, NULL);
            int ret;
            BOOL handshakeFailed = NO;
            while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
                if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
                    char buf[128] = {0};
                    mbedtls_strerror(ret, buf, sizeof(buf));
                    err = mkErr(14, [NSString stringWithFormat:@"handshake: %s", buf]);
                    handshakeFailed = YES;
                    break;
                }
            }
            if (handshakeFailed) break;
            sslReady = YES;
        } while (0);
        if (err) {
            mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
            mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy);
            close(fd);
            if (outError) *outError = err;
            return NO;
        }
    }

    // ---- Send HTTP request ----
    // HTTP/1.0 + browser UA. Sticking to HTTP/1.0 because our body-reading loop doesn't
    // parse Transfer-Encoding: chunked (the default HTTP/1.1 framing).
    //
    // Resume / Range support:
    //   Whole-file mode (chunkStart < 0): the local file is treated as a partial
    //   resume of the whole resource. We send Range: bytes=N- with N = current local
    //   file size. Server replies 206 → we append; 200 → server ignored Range, we
    //   truncate and restart.
    //
    //   Chunk mode (chunkStart >= 0): the local file is a partial chunk covering
    //   server bytes [chunkStart, chunkEnd]. We send Range: bytes=A-B with
    //   A = chunkStart + (local file size), B = chunkEnd. The 200-fallback can't
    //   work in chunk mode (we'd be writing more than chunk size), so on a 200
    //   response with chunk mode we abort with an error.
    //
    // archive.org S3 auth: when the host is *.archive.org and the user has saved S3
    // keys (Settings → Archive.org login), we inject an Authorization header. This is
    // the "low-security" S3 auth scheme archive.org uses for API calls. It can help
    // with per-IP rate limiting and sometimes gives priority routing for downloads.
    long long localExisting = 0;
    NSDictionary *existing = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    if (existing) {
        localExisting = [existing[NSFileSize] longLongValue];
    }
    // Compute the server-side Range request:
    //   reqRangeStart: first byte to ask for (in the resource's coordinate system)
    //   reqRangeEnd:   last byte to ask for (or -1 = open-ended)
    long long reqRangeStart, reqRangeEnd;
    BOOL chunkMode = (chunkStart >= 0);
    if (chunkMode) {
        // Defensive: clamp localExisting to chunk size in case the chunk file is
        // somehow bigger than the chunk (shouldn't happen, but if it does we don't
        // want a negative range).
        long long chunkSize = chunkEnd - chunkStart + 1;
        if (localExisting > chunkSize) localExisting = chunkSize;
        reqRangeStart = chunkStart + localExisting;
        reqRangeEnd = chunkEnd;
        if (reqRangeStart > reqRangeEnd) {
            // Chunk already complete — short-circuit success without hitting network.
            if (progressBlock) progressBlock(chunkSize, chunkSize);
            if (outStatus) *outStatus = 206;
            return YES;
        }
    } else {
        reqRangeStart = localExisting;
        reqRangeEnd = -1;
    }

    NSMutableString *reqBuilder = [NSMutableString stringWithCapacity:512];
    [reqBuilder appendFormat:@"GET %@ HTTP/1.0\r\n", encPath];
    [reqBuilder appendFormat:@"Host: %@\r\n", host];
    [reqBuilder appendString:@"User-Agent: Mozilla/5.0 (iPad; CPU OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25\r\n"];
    [reqBuilder appendString:@"Accept: */*\r\n"];
    [reqBuilder appendString:@"Connection: close\r\n"];
    if (chunkMode) {
        [reqBuilder appendFormat:@"Range: bytes=%lld-%lld\r\n", reqRangeStart, reqRangeEnd];
        NSLog(@"[HTTPSClient] Chunk request: bytes %lld-%lld (local has %lld of chunk)",
              reqRangeStart, reqRangeEnd, localExisting);
    } else if (reqRangeStart > 0) {
        [reqBuilder appendFormat:@"Range: bytes=%lld-\r\n", reqRangeStart];
        NSLog(@"[HTTPSClient] Resuming from byte %lld", reqRangeStart);
    }
    // archive.org S3 auth (any *.archive.org host)
    if ([host.lowercaseString hasSuffix:@"archive.org"]) {
        NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
        NSString *accessKey = [def stringForKey:@"IPAInstall.ArchiveAccessKey"];
        NSString *secretKey = [def stringForKey:@"IPAInstall.ArchiveSecretKey"];
        if (accessKey.length && secretKey.length) {
            [reqBuilder appendFormat:@"Authorization: LOW %@:%@\r\n", accessKey, secretKey];
        }
    }
    [reqBuilder appendString:@"\r\n"];
    NSString *req = reqBuilder;
    const char *reqBytes = [req UTF8String];
    size_t reqLen = strlen(reqBytes);

    // resumeFrom is the legacy variable used downstream (file-write logic). In
    // chunk mode it represents the byte count we already have locally for the
    // chunk; in whole-file mode it's the byte count we already have for the
    // whole file. The downstream "received" counter is initialized to this.
    long long resumeFrom = localExisting;
    if (sslReady) {
        size_t written = 0;
        while (written < reqLen) {
            int n = mbedtls_ssl_write(&ssl, (const unsigned char *)reqBytes + written, reqLen - written);
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n < 0) { err = mkErr(15, @"ssl_write"); break; }
            written += n;
        }
    } else {
        ssize_t s = send(fd, reqBytes, reqLen, 0);
        if (s != (ssize_t)reqLen) err = mkErr(15, @"send");
    }
    if (err) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = err;
        return NO;
    }

    // ---- Read headers (find \r\n\r\n) ----
    NSMutableData *headerBuf = [NSMutableData data];
    NSInteger headerEnd = -1;
    BOOL cancelledMidHeader = NO;
    while (headerEnd < 0 && headerBuf.length < 16384) {
        if (isCancelled && isCancelled()) { cancelledMidHeader = YES; break; }
        unsigned char tmp[2048];
        int n;
        if (sslReady) {
            n = mbedtls_ssl_read(&ssl, tmp, sizeof(tmp));
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n <= 0) break;
        } else {
            ssize_t r = recv(fd, tmp, sizeof(tmp), 0);
            if (r <= 0) break;
            n = (int)r;
        }
        [headerBuf appendBytes:tmp length:n];
        const char *hb = (const char *)headerBuf.bytes;
        NSUInteger hbLen = headerBuf.length;
        for (NSUInteger i = 0; i + 3 < hbLen; i++) {
            if (hb[i]=='\r' && hb[i+1]=='\n' && hb[i+2]=='\r' && hb[i+3]=='\n') {
                headerEnd = i + 4;
                break;
            }
        }
    }
    if (cancelledMidHeader) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = mkErr(99, T(@"common.cancelled"));
        if (outStatus) *outStatus = -1;
        return NO;
    }
    if (headerEnd < 0) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = mkErr(20, T(@"install.error.no_headers"));
        return NO;
    }

    // Parse status line + Content-Length + Location
    NSString *headerStr = [[NSString alloc] initWithBytes:headerBuf.bytes
                                                    length:headerEnd
                                                  encoding:NSASCIIStringEncoding];
    NSInteger statusCode = 0;
    {
        NSRange firstLineEnd = [headerStr rangeOfString:@"\r\n"];
        NSString *firstLine = firstLineEnd.location != NSNotFound
            ? [headerStr substringToIndex:firstLineEnd.location] : headerStr;
        NSArray *parts = [firstLine componentsSeparatedByString:@" "];
        if (parts.count >= 2) statusCode = [parts[1] integerValue];
    }
    if (outStatus) *outStatus = statusCode;

    // Redirect handling
    if (statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308) {
        NSString *location = nil;
        NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
        for (NSString *ln in lines) {
            NSRange r = [ln rangeOfString:@"Location:" options:NSCaseInsensitiveSearch];
            if (r.location == 0) {
                location = [[ln substringFromIndex:r.length]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                break;
            }
        }
        if (sslReady) { mbedtls_ssl_close_notify(&ssl); mbedtls_ssl_free(&ssl);
                        mbedtls_ssl_config_free(&conf); mbedtls_ctr_drbg_free(&drbg);
                        mbedtls_entropy_free(&entropy); sslReady = NO; }
        close(fd); fd = -1;
        if (!location.length) {
            if (outError) *outError = mkErr(31,
                [NSString stringWithFormat:T(@"install.error.redirect_no_location"),
                  (long)statusCode]);
            return NO;
        }
        // Relative redirect (no scheme) — resolve against current URL.
        if (![location hasPrefix:@"http://"] && ![location hasPrefix:@"https://"]) {
            NSURL *base = [NSURL URLWithString:cleanUrl];
            NSURL *absURL = [NSURL URLWithString:location relativeToURL:base];
            if (absURL.absoluteString.length) {
                location = absURL.absoluteString;
            }
        }
        // IMPORTANT: do NOT force HTTPS Locations back to HTTP — archive.org's CDN nodes
        // (dn*.ca.archive.org / ia*.us.archive.org) issue 301 redirects from HTTP to HTTPS
        // via HSTS. Forcing them back to HTTP causes an infinite redirect loop.
        // mbedTLS handshakes fine against the CDN nodes (Let's Encrypt, standard nginx TLS).
        // Only the archive.org front-end (Fastly) has the JA3 fingerprint problem, and
        // that one we already bypass by starting with `http://archive.org/...` as the
        // initial URL in downloadURL:.
        NSLog(@"[HTTPSClient] redirect %ld → %@", (long)statusCode, location);
        // IMPORTANT: reset outStatus to 0 so the recursive call's value (whatever the chain
        // ends up returning, 200 / 404 / etc.) is what gets surfaced — not this 30x.
        if (outStatus) *outStatus = 0;
        // Recurse with new URL — pass chunk params through unchanged.
        return [self downloadSync:location toFile:filePath
                        chunkStart:chunkStart chunkEnd:chunkEnd
                       outFullSize:outFullSize
                       isCancelled:isCancelled
                          progress:progressBlock
                        statusCode:outStatus error:outError
                     redirectsLeft:redirectsLeft - 1];
    }

    // 416 Range Not Satisfiable — file we have on disk is >= server's file size.
    // Most likely the partial file is stale (server file changed) or already complete.
    // Delete it and let the caller retry from scratch (next attempt will see no
    // partial file, omit the Range header, and refetch from byte 0).
    if (statusCode == 416 && resumeFrom > 0) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        NSLog(@"[HTTPSClient] 416 with resumeFrom=%lld — discarding partial, retrying from scratch", resumeFrom);
        return [self downloadSync:urlStr toFile:filePath
                       chunkStart:chunkStart chunkEnd:chunkEnd
                      outFullSize:outFullSize
                      isCancelled:isCancelled
                         progress:progressBlock
                       statusCode:outStatus error:outError
                    redirectsLeft:redirectsLeft];
    }

    if (statusCode < 200 || statusCode >= 300) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = mkErr(statusCode, [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
        return NO;
    }

    // In chunk mode a 200 response is a fatal mismatch: we asked for bytes A-B
    // explicitly and the server sent the whole file. We can't proceed because the
    // chunk file would be filled with unrelated bytes. Bail and let the caller
    // either retry or fall back to single-stream whole-file download.
    if (chunkMode && statusCode == 200) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = mkErr(206, @"Server ignored Range header (chunk mode requires 206)");
        return NO;
    }

    // Whether the server honored our Range request. If we sent Range but got 200 (not 206),
    // the server is sending the whole file — we must truncate any existing partial bytes
    // and restart from offset 0.
    BOOL isPartialResponse = (statusCode == 206);
    BOOL effectiveResume = isPartialResponse && resumeFrom > 0;

    // Parse Content-Length for progress total.
    // For 206 Partial Content, Content-Length is the size of the slice we're getting —
    // the full file size is given by Content-Range: bytes A-B/TOTAL. Parse both.
    long long total = -1;
    long long contentLength = -1;
    {
        NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
        for (NSString *ln in lines) {
            NSRange clr = [ln rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch];
            if (clr.location == 0) {
                contentLength = [[ln substringFromIndex:clr.length]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].longLongValue;
                continue;
            }
            NSRange crr = [ln rangeOfString:@"Content-Range:" options:NSCaseInsensitiveSearch];
            if (crr.location == 0) {
                // Format: "Content-Range: bytes 100-999/1000"
                NSString *val = [[ln substringFromIndex:crr.length]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSRange slash = [val rangeOfString:@"/"];
                if (slash.location != NSNotFound && slash.location + 1 < val.length) {
                    NSString *totalStr = [val substringFromIndex:slash.location + 1];
                    long long parsed = [totalStr longLongValue];
                    if (parsed > 0) {
                        total = parsed;
                        if (outFullSize) *outFullSize = parsed;  // expose for probe
                    }
                }
            }
        }
    }
    // If Content-Range didn't give us a total, derive it from Content-Length + offset.
    if (total < 0) {
        if (effectiveResume && contentLength > 0) {
            total = resumeFrom + contentLength;
        } else if (contentLength > 0) {
            total = contentLength;
        }
    }
    // In chunk mode, override total with the chunk size so the caller's progress
    // block sees this chunk's progress (received_in_chunk / chunk_size). The
    // caller (ParallelDownloader) aggregates across chunks to get full-file %.
    if (chunkMode) {
        total = chunkEnd - chunkStart + 1;
    }

    // ---- Write body to file, with progress ----
    // Append mode if the server honored our Range, write mode otherwise (which truncates
    // any existing partial file — appropriate when we got 200 instead of 206).
    FILE *outFile = fopen([filePath fileSystemRepresentation], effectiveResume ? "ab" : "wb");
    if (!outFile) {
        if (sslReady) { mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf);
                        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&entropy); }
        close(fd);
        if (outError) *outError = mkErr(40, @"Cannot open output file");
        return NO;
    }
    if (effectiveResume) {
        NSLog(@"[HTTPSClient] Server honored Range — appending %lld more bytes (total %lld)",
              contentLength, total);
    } else if (resumeFrom > 0) {
        NSLog(@"[HTTPSClient] Server ignored Range (HTTP %ld) — restarting from 0", (long)statusCode);
    }

    // For 206, the bytes we've ALREADY downloaded count toward the "received" total
    // shown to the user. So we start the counter at resumeFrom.
    long long received = effectiveResume ? resumeFrom : 0;
    // First, write the part of headerBuf that's body
    if ((NSUInteger)headerEnd < headerBuf.length) {
        NSUInteger leftover = headerBuf.length - headerEnd;
        fwrite((const char *)headerBuf.bytes + headerEnd, 1, leftover, outFile);
        received += leftover;
        if (progressBlock) progressBlock(received, total);
    }

    NSDate *lastProgress = [NSDate date];
    unsigned char chunk[16384];
    BOOL cancelledMidBody = NO;
    while (1) {
        if (isCancelled && isCancelled()) { cancelledMidBody = YES; break; }
        int n;
        if (sslReady) {
            n = mbedtls_ssl_read(&ssl, chunk, sizeof(chunk));
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || n == MBEDTLS_ERR_SSL_CONN_EOF) break;
            if (n <= 0) {
                if (n != 0) {
                    char buf[128] = {0};
                    mbedtls_strerror(n, buf, sizeof(buf));
                    err = mkErr(41, [NSString stringWithFormat:@"ssl_read: %s", buf]);
                }
                break;
            }
        } else {
            ssize_t r = recv(fd, chunk, sizeof(chunk), 0);
            if (r <= 0) break;
            n = (int)r;
        }
        if (fwrite(chunk, 1, n, outFile) != (size_t)n) {
            err = mkErr(42, @"fwrite failed (disk full?)");
            break;
        }
        received += n;
        if (progressBlock) {
            NSDate *now = [NSDate date];
            if ([now timeIntervalSinceDate:lastProgress] > 0.3) {
                progressBlock(received, total);
                lastProgress = now;
            }
        }
    }
    fclose(outFile);
    if (cancelledMidBody) {
        err = mkErr(99, T(@"common.cancelled"));
        if (outStatus) *outStatus = -1;
        // remove partial file
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    }
    if (progressBlock) progressBlock(received, total);  // final

    if (sslReady) {
        mbedtls_ssl_close_notify(&ssl);
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_ctr_drbg_free(&drbg);
        mbedtls_entropy_free(&entropy);
    }
    if (fd >= 0) close(fd);
    if (err) {
        if (outError) *outError = err;
        return NO;
    }
    return YES;
}

@end
