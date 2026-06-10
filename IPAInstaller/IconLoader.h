#import <UIKit/UIKit.h>

// Lightweight async icon loader optimized for old armv7 devices (iPad 1 A4 / 256 MB RAM).
// - Off-main decoding (background serial queue)
// - Pre-rendered to a target size with rounded corners baked in (no offscreen render at scroll)
// - NSCache with size limit
// - Per-URL request dedup
@interface IconLoader : NSObject

+ (instancetype)shared;

// Returns cached image immediately if available. Otherwise nil and triggers async load.
// When loaded, the completion block fires on the main queue with the image.
- (UIImage *)cachedImageForURL:(NSString *)url targetSize:(CGSize)size;
// Returns an opaque cancel token (nil if served instantly from the RAM cache). Pass it to
// -cancelRequest: when the requesting cell is reused, so a fast scroll doesn't pile up stale
// decodes ahead of the now-visible tiles.
- (id)loadImageForURL:(NSString *)url
              targetSize:(CGSize)size
                via:(NSString *)proxyURL
              completion:(void (^)(UIImage *image))completion;

// Cancel a request started by -loadImageForURL: (safe with nil / an already-finished token).
- (void)cancelRequest:(id)token;

// Suspend/resume to pause loads during fast scrolling
- (void)suspend;
- (void)resume;

- (void)clearCache;

@end
