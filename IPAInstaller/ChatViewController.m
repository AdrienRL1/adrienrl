#import "ChatViewController.h"
#import "ChatMessage.h"
#import "LocalCatalog.h"
#import "InstallManager.h"
#import "CatalogFilter.h"
#import "AppDetailViewController.h"
#import "IOS6Theme.h"
#import "IconLoader.h"
#import "ChatBubbleView.h"
#import "Localization.h"
#import "FeedbackViewController.h"
#import "PollinationsLLM.h"
#import <objc/runtime.h>
#import "DeviceInfo.h"   // exact device model + chip + RAM for the AI

@interface ChatViewController ()
@property (nonatomic, strong) NSMutableArray *messages;           // ChatMessage instances
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *inputBar;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL waiting;
// Cached content view per displayable message — built once, re-attached to cell on scroll.
// Avoids the ~60 subviews/cell rebuild on every cellForRow which kills scroll smoothness on iPad 1.
@property (nonatomic, strong) NSMutableArray *cachedRowViews;
@end

@implementation ChatViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"chat.title");
    self.view.backgroundColor = [IOS6Theme chatBackgroundColor];
    self.messages = [NSMutableArray array];

    // NOTE (v1.4): the chat does NOT drive the model with a conversation-style system
    // prompt. The real model work lives in PollinationsLLM as two focused calls — query
    // expansion, then a GROUNDED selection pass over the real apps we found. We keep a
    // tiny placeholder system message only so the transcript array has a stable shape;
    // it is never sent to the model nor shown in the UI.
    [self.messages addObject:[ChatMessage system:@"AppDrop vintage-iOS app finder."]];

    self.cachedRowViews = [NSMutableArray array];
    [self buildUI];
    [self.tableView reloadData];
}

- (void)buildUI {
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width;
    CGFloat inputH = 50;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, w, b.size.height - inputH)
                                                   style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [IOS6Theme chatBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.opaque = YES;
    [self.view addSubview:self.tableView];

    // Input bar — brushed metal style with subtle gradient (gray button image stretched as bg)
    self.inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - inputH, w, inputH)];
    self.inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.inputBar.opaque = YES;
    // Use a UIImageView with stretchable tabBarBackground-ish gradient inverted (light to slightly darker)
    UIImageView *barBg = [[UIImageView alloc] initWithFrame:self.inputBar.bounds];
    barBg.image = [IOS6Theme grayButtonNormal];  // light metallic gradient
    barBg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    barBg.contentMode = UIViewContentModeScaleToFill;
    [self.inputBar addSubview:barBg];
    // Top hairline (dark line above input bar)
    UIView *topBorder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0.5)];
    topBorder.backgroundColor = [UIColor colorWithWhite:0.40 alpha:1.0];
    topBorder.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.inputBar addSubview:topBorder];
    [self.view addSubview:self.inputBar];

    CGFloat sendW = 64;
    CGFloat padding = 6;
    CGFloat fieldH = inputH - 2 * padding;

    // (Mic button removed: voice input handled by the iOS keyboard's native dictation key,
    // which works iOS 5.1+ in every keyboard language, no extra setup, no API key needed.)
    // Text field — rounded with subtle inset shadow
    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(padding, padding,
                                                                       w - sendW - 3*padding,
                                                                       fieldH)];
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.placeholder = T(@"chat.placeholder");
    self.inputField.font = [IOS6Theme bodyFont];
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.delegate = self;
    self.inputField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.inputBar addSubview:self.inputField];

    // Send button — primary blue glossy
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sendBtn.frame = CGRectMake(w - sendW - padding, padding, sendW, fieldH);
    self.sendBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.sendBtn setTitle:T(@"chat.send") forState:UIControlStateNormal];
    [IOS6Theme styleButton:self.sendBtn];
    self.sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.sendBtn addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:self.sendBtn];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    // Voice mode toggle removed — voice input via iOS keyboard, voice output via AVFoundation
    // (no longer auto-triggered after each reply).
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    [self installFeedbackBarButton];   // persistent Feedback button (left) on the AI root

    // Keyboard handling for input field
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(keyboardWillShow:)
                                                  name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(keyboardWillHide:)
                                                  name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)n {
    NSDictionary *u = n.userInfo;
    CGRect endScreen = [u[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // Convert from window/screen coords into our view's coords — in landscape on iOS 5/6,
    // the raw keyboard rect is in screen orientation (portrait), so width and height
    // are swapped from what we want. convertRect:fromView:nil does the right thing.
    CGRect endInView = [self.view convertRect:endScreen fromView:nil];
    // The keyboard's "visible portion" inside our view = intersection with our bounds.
    CGRect intersection = CGRectIntersection(self.view.bounds, endInView);
    CGFloat kbH = CGRectIsNull(intersection) ? 0 : intersection.size.height;
    CGRect b = self.view.bounds;
    CGFloat inputH = self.inputBar.frame.size.height;
    self.inputBar.frame = CGRectMake(0, b.size.height - inputH - kbH, b.size.width, inputH);
    self.tableView.frame = CGRectMake(0, 0, b.size.width, b.size.height - inputH - kbH);
    [self scrollToBottom];
}

- (void)keyboardWillHide:(NSNotification *)n {
    CGRect b = self.view.bounds;
    CGFloat inputH = self.inputBar.frame.size.height;
    self.inputBar.frame = CGRectMake(0, b.size.height - inputH, b.size.width, inputH);
    self.tableView.frame = CGRectMake(0, 0, b.size.width, b.size.height - inputH);
}

#pragma mark - Send

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self sendTapped];
    return NO;
}

- (void)sendTapped {
    NSString *text = [self.inputField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!text.length || self.waiting) return;
    self.inputField.text = @"";
    [self.inputField resignFirstResponder];

    [self.messages addObject:[ChatMessage user:text]];
    [self reloadAndScroll];
    [self runHeuristicSearchForText:text];
}

// Multi-language LLM-driven search. Pollinations is the only chat backend.
// v2.0.24 flow:
//   1) Call LLM with vintage-iOS expert prompt. LLM returns titles + keywords + reply.
//   2) Search catalog by BOTH titles (boosted score) and keywords (broader).
//   3) If catalog returns < 3 hits → call LLM again with "alternative titles" prompt,
//      excluding the titles we already tried. Search again, merge results.
- (void)runHeuristicSearchForText:(NSString *)text {
    // v1.4: pure device questions are answered instantly & locally (no network).
    if ([self isDeviceQuestion:text]) {
        NSString *r = [NSString stringWithFormat:T(@"chat.device_answer"), [DeviceInfo aiSummary]];
        [self finishChatWithApps:@[] reply:r];
        return;
    }

    self.waiting = YES;
    self.sendBtn.enabled = NO;
    [self.spinner startAnimating];

    [[PollinationsLLM shared] askForKeywordsAndReply:text
                completion:^(NSArray *titles, NSArray *keywords, NSString *reply, NSError *err) {
        if (err || (!titles.count && !keywords.count)) {
            [self finishChatWithApps:@[] reply:T(@"chat.llm_unavailable")];
            return;
        }
        [self runCatalogSearchWithTitles:titles
                                  keywords:keywords
                                 replyText:reply
                          originalUserText:text];
    }];
}

// Catalog search with two signal sources:
//   titles   — boost weight ×3 because they're specific LLM guesses
//   keywords — broader matches at normal weight
// If too few results, kick off a retry pass with alternative titles.
- (void)runCatalogSearchWithTitles:(NSArray *)titles
                            keywords:(NSArray *)keywords
                           replyText:(NSString *)reply
                    originalUserText:(NSString *)userText {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *appsByBid = [NSMutableDictionary dictionary];
        NSMutableDictionary *scoreByBid = [NSMutableDictionary dictionary];
        CatalogFilter *cf = [CatalogFilter load_];

        // Pass 1: titles (specific guesses) — high weight.
        for (NSString *t in titles) {
            if (![t isKindOfClass:[NSString class]] || !t.length) continue;
            NSDictionary *res = [[LocalCatalog shared] searchWithQuery:t
                                                                  minIOS:nil
                                                                  maxIOS:nil
                                                                  unique:YES
                                                                    sort:@"recent"
                                                              descending:YES
                                                             deviceClass:cf.deviceClass
                                                             category:nil
                                                             subgenre:nil
                                                                  offset:0
                                                                   limit:10];
            for (NSDictionary *app in res[@"results"] ?: @[]) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                if (!appsByBid[bid]) appsByBid[bid] = app;
                // Title matches count 3× — they're specific guesses, not vocab.
                scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 3);
            }
        }
        // Pass 2: keywords — broader, low weight.
        for (NSString *kw in keywords) {
            if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
            NSDictionary *res = [[LocalCatalog shared] searchWithQuery:kw
                                                                  minIOS:nil
                                                                  maxIOS:nil
                                                                  unique:YES
                                                                    sort:@"recent"
                                                              descending:YES
                                                             deviceClass:cf.deviceClass
                                                             category:nil
                                                             subgenre:nil
                                                                  offset:0
                                                                   limit:15];
            for (NSDictionary *app in res[@"results"] ?: @[]) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                if (!appsByBid[bid]) appsByBid[bid] = app;
                scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 1);
            }
        }
        // Sort by score (DESC), then pk (DESC for newer-first within tie).
        NSArray *bids = [appsByBid.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSComparisonResult c = [scoreByBid[b] compare:scoreByBid[a]];
            if (c != NSOrderedSame) return c;
            return [appsByBid[b][@"id"] compare:appsByBid[a][@"id"]];
        }];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *bid in bids) {
            [out addObject:appsByBid[bid]];
            if (out.count >= 20) break;  // v1.4: bigger pool for the grounding pass
        }

        // v1.4 FAST PATH (1 LLM call total): if the catalog holds an app whose title
        // EXACTLY matches one of the model's specific guesses, that's a high-confidence
        // real hit — skip the grounding round-trip and answer now with a locally-built,
        // fully-grounded reply (names come straight from real catalog apps). This halves
        // latency for the common "famous / well-described app" case.
        NSMutableArray *guesses = [NSMutableArray array];
        for (NSString *t in titles) {
            NSString *n = NormalizeTitle(t);
            if (n.length) [guesses addObject:n];
        }
        NSMutableArray *confident = [NSMutableArray array];
        NSMutableSet *seenTitles = [NSMutableSet set];   // one card per distinct title
        for (NSDictionary *app in out) {
            NSString *c = NormalizeTitle(app[@"title"]);
            if (!c.length || [seenTitles containsObject:c]) continue;  // skip dup titles
            BOOL hit = NO;
            for (NSString *g in guesses) {
                if ([c isEqualToString:g]) { hit = YES; break; }   // exact title match
                // Fuzzy: one title contains the other, but only for guesses long
                // enough to be unambiguous (avoids "face" matching "Facebook").
                if (g.length >= 5 &&
                    ([c rangeOfString:g].location != NSNotFound ||
                     (c.length >= 5 && [g rangeOfString:c].location != NSNotFound))) {
                    hit = YES; break;
                }
            }
            if (hit) {
                [seenTitles addObject:c];
                [confident addObject:app];
                if (confident.count >= 6) break;
            }
        }
        // Any query that references the device ("...sur mon iPad", "does X run on my
        // iPad?") skips the local fast path so the LLM can give a device-aware answer
        // (it has the model/chip/RAM/iOS context in its system prompt).
        if (confident.count > 0 && ![self mentionsDevice:userText]) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *app in confident) {
                NSString *t = [app[@"title"] isKindOfClass:[NSString class]] ? app[@"title"] : nil;
                if (t.length) [names addObject:t];
            }
            NSString *localReply = [NSString stringWithFormat:T(@"chat.found_named"),
                                     [names componentsJoinedByString:@", "]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishChatWithApps:confident reply:localReply];
            });
            return;
        }

        // Few hits? Retry with alternative titles from the LLM.
        // Threshold tuned: 3 because the catalog is so noisy that 1-2 results often
        // turn out to be coincidental keyword matches, not the real app.
        BOOL needRetry = (out.count < 3 && userText.length);
        if (needRetry) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self retryWithAlternativesForUserText:userText
                                          previousTitles:titles
                                       firstPassResults:out
                                              replyText:reply];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // v1.4: don't answer from the LLM's memory reply — ground it in the real
            // apps we just found and let the model pick only among those.
            [self groundCandidates:out userText:userText];
        });
    });
}

// Second LLM round when first pass had too few catalog hits. We tell the LLM the
// previous guesses didn't work and ask for different alternatives, then re-search.
- (void)retryWithAlternativesForUserText:(NSString *)userText
                            previousTitles:(NSArray *)previousTitles
                          firstPassResults:(NSArray *)firstPassResults
                                  replyText:(NSString *)reply {
    NSLog(@"[chat] first pass %lu hits — retrying with alternative titles",
          (unsigned long)firstPassResults.count);
    [[PollinationsLLM shared] askForAlternativeTitles:userText
                                           alreadyTried:previousTitles
                                             completion:^(NSArray *titles2, NSArray *kws2,
                                                            NSString *reply2, NSError *err) {
        if (err || (!titles2.count && !kws2.count)) {
            // Retry itself failed — ground whatever the first pass turned up (even if
            // slim) so we still don't invent. Better than a memory-only reply.
            [self groundCandidates:firstPassResults userText:userText];
            return;
        }
        // Merge first-pass + alternative-pass results.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableDictionary *appsByBid = [NSMutableDictionary dictionary];
            NSMutableDictionary *scoreByBid = [NSMutableDictionary dictionary];
            CatalogFilter *cf = [CatalogFilter load_];
            // Seed with first-pass hits (preserve them, lower priority).
            for (NSDictionary *app in firstPassResults) {
                NSString *bid = app[@"bundleId"];
                if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                appsByBid[bid] = app;
                scoreByBid[bid] = @1;
            }
            // Alternative titles — high weight (these are LLM's "rethought" guesses).
            for (NSString *t in titles2) {
                if (![t isKindOfClass:[NSString class]] || !t.length) continue;
                NSDictionary *res = [[LocalCatalog shared] searchWithQuery:t
                                                                      minIOS:nil maxIOS:nil
                                                                      unique:YES sort:@"recent"
                                                                  descending:YES
                                                                 deviceClass:cf.deviceClass
                                                                 category:nil
                                                                 subgenre:nil
                                                                      offset:0 limit:10];
                for (NSDictionary *app in res[@"results"] ?: @[]) {
                    NSString *bid = app[@"bundleId"];
                    if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                    if (!appsByBid[bid]) appsByBid[bid] = app;
                    scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 3);
                }
            }
            for (NSString *kw in kws2) {
                if (![kw isKindOfClass:[NSString class]] || !kw.length) continue;
                NSDictionary *res = [[LocalCatalog shared] searchWithQuery:kw
                                                                      minIOS:nil maxIOS:nil
                                                                      unique:YES sort:@"recent"
                                                                  descending:YES
                                                                 deviceClass:cf.deviceClass
                                                                 category:nil
                                                                 subgenre:nil
                                                                      offset:0 limit:15];
                for (NSDictionary *app in res[@"results"] ?: @[]) {
                    NSString *bid = app[@"bundleId"];
                    if (!bid.length) bid = [NSString stringWithFormat:@"_id_%@", app[@"id"]];
                    if (!appsByBid[bid]) appsByBid[bid] = app;
                    scoreByBid[bid] = @([scoreByBid[bid] integerValue] + 1);
                }
            }
            NSArray *bids = [appsByBid.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSComparisonResult c = [scoreByBid[b] compare:scoreByBid[a]];
                if (c != NSOrderedSame) return c;
                return [appsByBid[b][@"id"] compare:appsByBid[a][@"id"]];
            }];
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *bid in bids) {
                [out addObject:appsByBid[bid]];
                if (out.count >= 20) break;  // v1.4: bigger pool for the grounding pass
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                // v1.4: ground the merged candidates instead of using a memory reply.
                [self groundCandidates:out userText:userText];
            });
        });
    }];
}

// Normalise a title for confident exact-match comparison: lowercase, keep only
// alphanumerics (so "Cut the Rope!" == "cut the rope" == "CutTheRope").
static NSString *NormalizeTitle(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *lower = [s lowercaseString];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [out appendFormat:@"%C", c];
    }
    return out;
}

// Real hardware + OS so the AI can suggest apps that run on THIS device. hw.machine
// is the exact model id (e.g. "iPad4,4" = iPad mini 2) which the model recognises;
// we add the idiom + the exact iOS version.
// "What's my iPad? / how much RAM? / which iOS?" — a pure question about the device
// itself (NOT an app search). Answered instantly & locally, no network.
- (BOOL)isDeviceQuestion:(NSString *)text {
    NSString *t = [text lowercaseString];
    if (!t.length) return NO;
    NSArray *appWords = @[@"app", @"appli", @"jeu", @"game", @"trouve", @"cherche",
                          @"recommand", @"suggèr", @"suggere", @"installe", @"télécharge",
                          @"telecharge", @"download", @"looking for", @"find me"];
    for (NSString *w in appWords) if ([t rangeOfString:w].location != NSNotFound) return NO;
    NSArray *devWords = @[@"mon ipad", @"mon iphone", @"mon ipod", @"mon appareil",
                          @"ma tablette", @"mon modèle", @"mon modele", @"cet appareil",
                          @"ce modèle", @"my ipad", @"my iphone", @"my ipod", @"my device",
                          @"my model", @"this device"];
    BOOL refsDevice = NO;
    for (NSString *w in devWords) if ([t rangeOfString:w].location != NSNotFound) { refsDevice = YES; break; }
    if (!refsDevice) return NO;
    NSArray *qWords = @[@"quel", @"quelle", @"quoi", @"combien", @"what", @"which",
                        @"how much", @"how many", @"ram", @"mémoire", @"memoire", @"memory",
                        @"processeur", @"processor", @"puce", @"chip", @"cpu", @"spec",
                        @"modèle", @"modele", @"model", @"version", @"?"];
    for (NSString *w in qWords) if ([t rangeOfString:w].location != NSNotFound) return YES;
    return NO;
}

// "Does this app run / is it compatible with my iPad?" — route to the LLM (grounding)
// so it can give a device-aware answer, instead of the local 1-call fast path.
- (BOOL)isCompatQuestion:(NSString *)text {
    NSString *t = [text lowercaseString];
    if (!t.length) return NO;
    NSArray *devWords = @[@"mon ipad", @"mon iphone", @"mon ipod", @"mon appareil",
                          @"ma tablette", @"sur mon", @"my ipad", @"my iphone", @"my device", @"on my"];
    BOOL refsDevice = NO;
    for (NSString *w in devWords) if ([t rangeOfString:w].location != NSNotFound) { refsDevice = YES; break; }
    if (!refsDevice) return NO;
    NSArray *compatWords = @[@"compatib", @"tourne", @"marche", @"fonctionne", @"supporte",
                             @"run", @"work", @"capable"];
    for (NSString *w in compatWords) if ([t rangeOfString:w].location != NSNotFound) return YES;
    return NO;
}

// Does the user reference their device at all? ("...sur mon iPad", "pour mon appareil"…)
// If so we route to the LLM (grounding) instead of the local fast path, so the reply
// can actually be tailored to / mention the device.
- (BOOL)mentionsDevice:(NSString *)text {
    NSString *t = [text lowercaseString];
    NSArray *devWords = @[@"mon ipad", @"mon iphone", @"mon ipod", @"mon appareil",
                          @"ma tablette", @"sur mon", @"pour mon", @"mon modèle", @"mon modele",
                          @"my ipad", @"my iphone", @"my ipod", @"my device", @"on my", @"for my"];
    for (NSString *w in devWords) if ([t rangeOfString:w].location != NSNotFound) return YES;
    return NO;
}

// Decode the catalog `platform` bitmask into a human device string for the model.
// Matches AppDetailViewController: bit 2 = iPhone, 4 = iPad, 8 = AppleTV, 16 = Watch.
// "iPhone/iPad" means universal.
- (NSString *)deviceStringForMask:(NSInteger)mask {
    NSMutableArray *p = [NSMutableArray array];
    if (mask & 2)  [p addObject:@"iPhone"];
    if (mask & 4)  [p addObject:@"iPad"];
    if (mask & 8)  [p addObject:@"AppleTV"];
    if (mask & 16) [p addObject:@"Watch"];
    return p.count ? [p componentsJoinedByString:@"/"] : @"?";
}

// v1.4 GROUNDING — the anti-hallucination step. We have REAL catalog candidates;
// hand the model a numbered list and let it pick only the ones that truly match +
// write a reply about just those. The model answers by number, so it cannot invent
// an app outside the list. No match (or a failed call) → honest empty state.
- (void)groundCandidates:(NSArray *)candidates userText:(NSString *)userText {
    if (candidates.count == 0) {
        [self finishChatWithApps:@[] reply:T(@"chat.not_found")];
        return;
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < candidates.count; i++) {
        NSDictionary *app = candidates[i];
        NSString *title = [app[@"title"]   isKindOfClass:[NSString class]] ? app[@"title"]   : @"?";
        NSString *ver   = [app[@"version"] isKindOfClass:[NSString class]] ? app[@"version"] : @"?";
        NSString *minOS = [app[@"minOS"]   isKindOfClass:[NSString class]] ? app[@"minOS"]   : @"?";
        NSString *devices = [self deviceStringForMask:[app[@"platform"] integerValue]];
        long long bytes = [app[@"size"] longLongValue];
        NSString *sizeStr = bytes > 0
            ? [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)] : @"?";
        // Rich line so the model knows each app's device compatibility, min iOS and
        // size — it can mention these and prioritise by them when the user cares.
        [lines addObject:[NSString stringWithFormat:@"%lu. %@ — v%@ — %@ — iOS %@+ — %@",
                          (unsigned long)(i + 1), title, ver, devices, minOS, sizeStr]];
    }
    [[PollinationsLLM shared] selectMatchingCandidates:lines
                                              userText:userText
                                            completion:^(NSArray *matchNumbers, NSString *reply,
                                                          BOOL found, NSError *err) {
        if (err) {
            // Grounding call failed: show the top few real candidates with a NEUTRAL
            // reply that does NOT claim they match — they're just raw search results.
            NSArray *top = candidates.count > 6
                ? [candidates subarrayWithRange:NSMakeRange(0, 6)] : candidates;
            [self finishChatWithApps:top reply:T(@"chat.search_results_neutral")];
            return;
        }
        if (!found || matchNumbers.count == 0) {
            [self finishChatWithApps:@[] reply:(reply.length ? reply : T(@"chat.not_found"))];
            return;
        }
        // Map 1-based numbers back to real app dicts (validate range, dedupe, keep order).
        NSMutableArray *selected = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSNumber *n in matchNumbers) {
            if (![n respondsToSelector:@selector(integerValue)]) continue;
            NSInteger idx = n.integerValue - 1;
            if (idx < 0 || idx >= (NSInteger)candidates.count) continue;
            if ([seen containsObject:@(idx)]) continue;
            [seen addObject:@(idx)];
            [selected addObject:candidates[idx]];
            if (selected.count >= 6) break;
        }
        if (selected.count == 0) {
            [self finishChatWithApps:@[] reply:(reply.length ? reply : T(@"chat.not_found"))];
            return;
        }
        [self finishChatWithApps:selected
                           reply:(reply.length ? reply
                                  : [NSString stringWithFormat:T(@"chat.found_apps"),
                                     (unsigned long)selected.count])];
    }];
}

- (void)finishChatWithApps:(NSArray *)apps reply:(NSString *)reply {
    self.waiting = NO;
    [self.spinner stopAnimating];
    self.sendBtn.enabled = YES;

    ChatMessage *am = [[ChatMessage alloc] init];
    am.role = @"assistant";
    am.content = reply.length
        ? reply
        : [NSString stringWithFormat:T(@"chat.found_apps"), (unsigned long)apps.count];
    am.attachedApps = apps;
    [self.messages addObject:am];
    [self reloadAndScroll];
}

// v1.9.0: removed tool-call chat path (requestAssistantTurn/executeToolCalls/searchCatalogTool/
// runTool:), voice recording (micDown/micUp/micCancel + AVAudioRecorder), voice mode
// (toggleVoiceMode/speakText:/hideSpeakingLabel/interruptSpeech/autoStartListening + AVAudioPlayer),
// and AVAudioPlayerDelegate. Chat is now Pollinations-only via runHeuristicSearchForText:.

#pragma mark - Table

- (void)reloadAndScroll {
    // Rebuild the cached row views from scratch so they're always laid out with the
    // CURRENT table width. A view cached before the table reached its final width kept
    // a stale height that no longer matched its cell → overlapping/clipped cards and
    // big empty gaps when a new message was appended.
    [self.cachedRowViews removeAllObjects];
    [self.tableView reloadData];
    [self scrollToBottom];
}

- (void)scrollToBottom {
    NSInteger n = [self displayableMessageCount];
    if (n == 0) return;
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:n - 1 inSection:0]
                            atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

// Tool messages are now hidden from UI — they were just noise. The apps from search_catalog
// appear as tappable cards under the assistant reply that references them.
- (NSInteger)displayableMessageCount {
    NSInteger n = 0;
    for (ChatMessage *m in self.messages) {
        if ([m.role isEqualToString:@"user"] ||
            ([m.role isEqualToString:@"assistant"] && m.content.length)) n++;
    }
    return n;
}

- (ChatMessage *)displayableMessageAtIndex:(NSInteger)idx {
    NSInteger i = 0;
    for (ChatMessage *m in self.messages) {
        BOOL displayable = [m.role isEqualToString:@"user"] ||
            ([m.role isEqualToString:@"assistant"] && m.content.length);
        if (!displayable) continue;
        if (i == idx) return m;
        i++;
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [self displayableMessageCount];
}

#define kChatBubblePadding 12.0
#define kChatHMargin      14.0
#define kChatAppCardH     72.0
#define kChatAppCardGap   6.0
// CRITICAL: the row-height calc and the actual bubble build MUST use the same max
// width fraction, or the real bubble ends up taller than the reserved cell height
// and overflows onto the next cell (clipped/overlapping bubbles).
#define kChatBubbleMaxFrac 0.78

- (CGFloat)bubbleHeightForText:(NSString *)text width:(CGFloat)maxW {
    if (!text.length) return 0;
    CGSize sz = [text sizeWithFont:[IOS6Theme bodyFont]
                  constrainedToSize:CGSizeMake(maxW - 2 * kChatBubblePadding - 10, 5000)
                      lineBreakMode:NSLineBreakByWordWrapping];
    return sz.height + 2 * kChatBubblePadding;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    ChatMessage *m = [self displayableMessageAtIndex:ip.row];
    if (!m) return 44;
    CGFloat maxBubbleW = tv.bounds.size.width * kChatBubbleMaxFrac;
    CGFloat h = [self bubbleHeightForText:m.content ?: @"" width:maxBubbleW];
    // Add app cards below if attached
    NSInteger nApps = m.attachedApps.count;
    if (nApps > 0) {
        h += 10 + nApps * (kChatAppCardH + kChatAppCardGap);
    }
    return MAX(50, h + 12);  // top + bottom padding
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"chatCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.contentView.backgroundColor = [IOS6Theme chatBackgroundColor];
        cell.contentView.opaque = YES;
        cell.contentView.clipsToBounds = YES;   // never let content spill onto neighbour cells
        cell.backgroundColor = [IOS6Theme chatBackgroundColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    ChatMessage *m = [self displayableMessageAtIndex:ip.row];
    if (!m) {
        for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];
        return cell;
    }

    // Fast path: lookup the cached content view for this displayable index.
    // If already built, just re-attach it to the (possibly new) cell.contentView.
    while ((NSInteger)self.cachedRowViews.count <= ip.row) {
        [self.cachedRowViews addObject:[NSNull null]];
    }
    id cached = self.cachedRowViews[ip.row];
    UIView *content = nil;
    if ([cached isKindOfClass:[UIView class]]) {
        content = (UIView *)cached;
    } else {
        content = [self buildContentViewForMessage:m width:tv.bounds.size.width];
        self.cachedRowViews[ip.row] = content;
    }

    // Detach the cell's previous subviews (may belong to another message after reuse).
    // We do NOT destroy them — they're owned by their respective cached entries.
    for (UIView *v in [cell.contentView.subviews copy]) {
        [v removeFromSuperview];
    }
    [cell.contentView addSubview:content];
    return cell;
}

// Build the full content view (bubble + app cards) for a message ONCE.
// All subviews (bubble drawRect, card UIImageView × N, labels × N) are created here
// and never touched again — just re-parented as cells scroll in/out.
- (UIView *)buildContentViewForMessage:(ChatMessage *)m width:(CGFloat)w {
    CGFloat maxBubbleW = w * kChatBubbleMaxFrac;
    BOOL isUser = [m.role isEqualToString:@"user"];
    CGFloat bubbleH = [self bubbleHeightForText:m.content ?: @"" width:maxBubbleW];
    CGSize sz = [(m.content ?: @"") sizeWithFont:[IOS6Theme bodyFont]
                                 constrainedToSize:CGSizeMake(maxBubbleW - 2 * kChatBubblePadding - 10, 5000)
                                     lineBreakMode:NSLineBreakByWordWrapping];
    CGFloat bubbleW = sz.width + 2 * kChatBubblePadding + 10;
    if (bubbleW < 70) bubbleW = 70;
    CGFloat bubbleX = isUser ? (w - bubbleW - kChatHMargin) : kChatHMargin;

    // Compute total height (matches tableView:heightForRowAtIndexPath:)
    CGFloat totalH = MAX(50, bubbleH + 12);
    if (m.attachedApps.count) {
        totalH = bubbleH + 10 + m.attachedApps.count * (kChatAppCardH + kChatAppCardGap) + 12;
    }
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, totalH)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.opaque = YES;
    container.backgroundColor = [IOS6Theme chatBackgroundColor];

    ChatBubbleView *bubble = [[ChatBubbleView alloc] initWithFrame:CGRectMake(bubbleX, 6, bubbleW, bubbleH)];
    bubble.isUser = isUser;
    bubble.messageText = m.content ?: @"";
    [container addSubview:bubble];

    if (m.attachedApps.count) {
        CGFloat y = 6 + bubbleH + 10;
        for (NSDictionary *app in m.attachedApps) {
            UIView *card = [self buildAppCard:app width:w - 2 * kChatHMargin y:y];
            [container addSubview:card];
            y += kChatAppCardH + kChatAppCardGap;
        }
    }
    return container;
}

// Build a tappable iOS 6-style app card: pre-rendered card-bg PNG + icon + title/subtitle/cta.
// No runtime cornerRadius — the PNG already has rounded corners + border baked in.
- (UIView *)buildAppCard:(NSDictionary *)app width:(CGFloat)width y:(CGFloat)y {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(kChatHMargin, y, width, kChatAppCardH)];
    card.userInteractionEnabled = YES;
    card.opaque = NO;  // pixels outside the rounded card are transparent

    // Stretchable card background PNG (white gradient + border + 12pt rounded corners baked)
    UIImageView *bg = [[UIImageView alloc] initWithFrame:card.bounds];
    bg.image = [IOS6Theme cardBackground];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [card addSubview:bg];

    CGFloat iconSize = 52;
    CGFloat pad = 10;

    // Icon — IconLoader returns pre-rounded pixels (radius baked into the bitmap),
    // so we DON'T set cornerRadius on the layer (which would force offscreen rendering and
    // kill scroll perf on iPad 1/4).
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(pad, pad, iconSize, iconSize)];
    iv.backgroundColor = [UIColor clearColor];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.opaque = NO;
    [card addSubview:iv];

    NSString *iconUrl = app[@"icon"];
    if (iconUrl.length) {
        CGSize sz = CGSizeMake(iconSize, iconSize);
        UIImage *cached = [[IconLoader shared] cachedImageForURL:iconUrl targetSize:sz];
        if (cached) {
            iv.image = cached;
        } else {
            [[IconLoader shared] loadImageForURL:iconUrl
                                       targetSize:sz
                                              via:nil
                                       completion:^(UIImage *img) { if (img) iv.image = img; }];
        }
    }

    CGFloat textX = pad + iconSize + pad;
    CGFloat textW = width - iconSize - 3 * pad - 22;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(textX, pad + 2, textW, 20)];
    title.text = app[@"title"] ?: @"?";
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = [IOS6Theme labelDark];
    title.backgroundColor = [UIColor clearColor];
    [card addSubview:title];

    long long sizeBytes = [app[@"size"] longLongValue];
    NSString *sizeStr;
    if (sizeBytes <= 0) sizeStr = @"?";
    else if (sizeBytes < 1024LL*1024) sizeStr = [NSString stringWithFormat:@"%.0f Ko", sizeBytes / 1024.0];
    else if (sizeBytes < 1024LL*1024*1024) sizeStr = [NSString stringWithFormat:@"%.1f Mo", sizeBytes / (1024.0*1024)];
    else sizeStr = [NSString stringWithFormat:@"%.2f Go", sizeBytes / (1024.0*1024*1024)];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(textX, 27, textW, 16)];
    sub.text = [NSString stringWithFormat:@"v%@  •  iOS %@+  •  %@",
                  app[@"version"] ?: @"?", app[@"minOS"] ?: @"?", sizeStr];
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [IOS6Theme labelGray];
    sub.backgroundColor = [UIColor clearColor];
    [card addSubview:sub];

    UILabel *cta = [[UILabel alloc] initWithFrame:CGRectMake(textX, 45, textW, 16)];
    cta.text = T(@"chat.tap_to_install");
    cta.font = [UIFont boldSystemFontOfSize:11];
    cta.textColor = [IOS6Theme primaryBlue];
    cta.backgroundColor = [UIColor clearColor];
    [card addSubview:cta];

    // Disclosure indicator
    UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectMake(width - 22, 26, 14, 20)];
    arrow.text = @"›";
    arrow.font = [UIFont boldSystemFontOfSize:24];
    arrow.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    arrow.backgroundColor = [UIColor clearColor];
    [card addSubview:arrow];

    NSDictionary *appCapture = app;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(appCardTapped:)];
    [card addGestureRecognizer:tap];
    objc_setAssociatedObject(card, "ipa.appdict", appCapture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return card;
}

- (void)appCardTapped:(UITapGestureRecognizer *)gr {
    NSDictionary *app = objc_getAssociatedObject(gr.view, "ipa.appdict");
    if (!app) return;
    AppDetailViewController *vc = [[AppDetailViewController alloc] initWithApp:app];
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - Rotation: invalidate cached row views

// On rotation, the cached row views were built for the old screen width — their bubbles
// + app cards now overflow or have huge gaps. Drop the cache so cells rebuild at the new width.
- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
                                 duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.cachedRowViews removeAllObjects];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    // Rebuild table cells (and bubble + app card content views) at the new orientation width.
    [UIView setAnimationsEnabled:NO];
    [self.tableView reloadData];
    [UIView setAnimationsEnabled:YES];
    [self scrollToBottom];
}

@end
