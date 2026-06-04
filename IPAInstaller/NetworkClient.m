#import "NetworkClient.h"

// One instance per request. Acts as NSURLConnectionDelegate to accept all server certs.
@interface NCRequest : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, copy) void (^completion)(NSData *, NSHTTPURLResponse *, NSError *);
@property (nonatomic, strong) NSURLConnection *connection;
@end

@implementation NCRequest

- (void)start:(NSURLRequest *)req {
    self.buffer = [NSMutableData data];
    // Retain self until connection completes (NSURLConnection has weak ref to delegate)
    self.connection = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:YES];
    if (!self.connection && self.completion) {
        self.completion(nil, nil,
            [NSError errorWithDomain:@"NetworkClient" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"Cannot start connection"}]);
    }
}

#pragma mark - Trust bypass

- (BOOL)connection:(NSURLConnection *)c canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)sp {
    return [sp.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
}

- (void)connection:(NSURLConnection *)c didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)ch {
    if ([ch.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        // Trust whatever server provides — bypass iOS 6 outdated root CA store
        NSURLCredential *cred = [NSURLCredential credentialForTrust:ch.protectionSpace.serverTrust];
        [ch.sender useCredential:cred forAuthenticationChallenge:ch];
    } else {
        [ch.sender continueWithoutCredentialForAuthenticationChallenge:ch];
    }
}

#pragma mark - Data delegate

- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)resp {
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        self.response = (NSHTTPURLResponse *)resp;
    }
    [self.buffer setLength:0];
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
    [self.buffer appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    if (self.completion) {
        self.completion(self.buffer, self.response, nil);
    }
    self.connection = nil;
}

- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)err {
    if (self.completion) {
        self.completion(nil, self.response, err);
    }
    self.connection = nil;
}

@end


@implementation NetworkClient

static NSMutableSet *_inflight = nil;

+ (void)initialize {
    if (self == [NetworkClient class]) {
        _inflight = [NSMutableSet set];
    }
}

+ (void)getURL:(NSString *)url
       timeout:(NSTimeInterval)t
    completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))cb {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:t > 0 ? t : 30];
    [req setHTTPMethod:@"GET"];
    NCRequest *r = [[NCRequest alloc] init];
    @synchronized (_inflight) { [_inflight addObject:r]; }
    AD_WEAK NCRequest *weakR = r;
    r.completion = ^(NSData *d, NSHTTPURLResponse *resp, NSError *err) {
        if (cb) {
            dispatch_async(dispatch_get_main_queue(), ^{ cb(d, resp, err); });
        }
        NCRequest *strongR = weakR;
        if (strongR) {
            @synchronized (_inflight) { [_inflight removeObject:strongR]; }
        }
    };
    [r start:req];
}

+ (void)postURL:(NSString *)url
            body:(NSData *)body
     contentType:(NSString *)ct
         timeout:(NSTimeInterval)t
      completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))cb {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:t > 0 ? t : 30];
    [req setHTTPMethod:@"POST"];
    if (ct) [req setValue:ct forHTTPHeaderField:@"Content-Type"];
    if (body) [req setHTTPBody:body];
    NCRequest *r = [[NCRequest alloc] init];
    @synchronized (_inflight) { [_inflight addObject:r]; }
    AD_WEAK NCRequest *weakR = r;
    r.completion = ^(NSData *d, NSHTTPURLResponse *resp, NSError *err) {
        if (cb) {
            dispatch_async(dispatch_get_main_queue(), ^{ cb(d, resp, err); });
        }
        NCRequest *strongR = weakR;
        if (strongR) {
            @synchronized (_inflight) { [_inflight removeObject:strongR]; }
        }
    };
    [r start:req];
}

@end
