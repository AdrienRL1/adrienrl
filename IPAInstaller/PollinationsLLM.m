#import "PollinationsLLM.h"
#import "CheckpointLog.h"
#import "HTTPSClient.h"
#import "DeviceInfo.h"

static NSString *const kEndpoint = @"https://text.pollinations.ai/openai";

// The shared "vintage iOS expert" system prompt. Drilled in: pre-iOS 7 era only,
// specific titles, structured JSON output, multilingual intro. Examples are critical
// because GPT-OSS-20B is a small model — without concrete examples it tends to
// suggest modern (post-2015) apps that aren't in our catalog.
static NSString *const kSystemPromptBase =
    @"You are an expert on vintage iOS apps from 2008-2014 — the pre-iOS 7 \n"
    @"skeuomorphic era when the App Store had Doodle Jump, Cut the Rope, Angry \n"
    @"Birds, Plants vs Zombies, Fruit Ninja, Tiny Wings, Temple Run, Where's My \n"
    @"Water, Bejeweled, Tap Tap Revenge, Talking Tom, Subway Surfers, Infinity \n"
    @"Blade, Real Racing, Flight Control, Bubble Ball, Bad Piggies, Jetpack \n"
    @"Joyride, Tiny Tower, Pou, etc.\n"
    @"\n"
    @"The user describes an app they remember (any language). Identify the SPECIFIC \n"
    @"title(s) they likely mean. The catalog only contains apps from this era \n"
    @"(roughly 2008 through 2014). DO NOT suggest apps released after 2015 — they \n"
    @"won't be in the catalog.\n"
    @"\n"
    @"Be specific. 'Puzzle game with green creature' → 'Cut the Rope'. 'Bird game with \n"
    @"slingshot' → 'Angry Birds'. Use your knowledge of titles, characters, art style, \n"
    @"gameplay, developer studios, era trends.\n"
    @"\n"
    @"Output a single JSON object — NO markdown, NO code fences, NO preamble:\n"
    @"{\n"
    @"  \"titles\":   [\"App Title 1\", \"App Title 2\", ...],   // 3-6 specific titles\n"
    @"  \"keywords\": [\"word1\", \"word2\", ...],                // 4-6 short English search terms\n"
    @"  \"reply\":    \"1-2 sentence reply in the user's language\"\n"
    @"}\n"
    @"\n"
    @"Examples:\n"
    @"\n"
    @"User: \"There was a game where you cut ropes to feed candy to a green creature\"\n"
    @"{\"titles\":[\"Cut the Rope\",\"Cut the Rope: Experiments\",\"Cut the Rope Free\"],\n"
    @" \"keywords\":[\"cut\",\"rope\",\"candy\",\"om nom\"],\n"
    @" \"reply\":\"That's Cut the Rope, the 2010 puzzle hit from ZeptoLab where you feed candy to the green creature Om Nom.\"}\n"
    @"\n"
    @"User: \"Un jeu où on lance des oiseaux sur des cochons verts\"\n"
    @"{\"titles\":[\"Angry Birds\",\"Angry Birds Seasons\",\"Angry Birds Rio\",\"Angry Birds Space\"],\n"
    @" \"keywords\":[\"angry birds\",\"slingshot\",\"pigs\"],\n"
    @" \"reply\":\"C'est Angry Birds, le classique de Rovio (2009) où tu utilises une fronde pour lancer des oiseaux sur des cochons verts.\"}\n"
    @"\n"
    @"User: \"Un jeu où un chat parle et répète ce que tu dis\"\n"
    @"{\"titles\":[\"Talking Tom Cat\",\"Talking Tom Cat 2\",\"Talking Tom Cat Free\"],\n"
    @" \"keywords\":[\"talking tom\",\"cat\",\"voice\"],\n"
    @" \"reply\":\"Tu parles de Talking Tom Cat (2010), où un chat répète ce que tu dis avec une voix amusante.\"}\n"
    @"\n"
    @"User: \"うろ覚えだけど、岩の上を跳ねるピンクのキャラクター\"\n"
    @"{\"titles\":[\"Doodle Jump\",\"Tiny Wings\"],\n"
    @" \"keywords\":[\"doodle\",\"jump\",\"bounce\"],\n"
    @" \"reply\":\"おそらく Doodle Jump（2009年、Lima Sky）のことだと思います — 落ちないように上に跳ね続けるアーケードゲームです。\"}\n";

// v1.4 GROUNDING prompt — used for the second pass, where the model is shown the
// REAL apps we found in the catalog and must pick only from them. This is what
// stops invention: the model answers by NUMBER, choosing from a fixed real list.
static NSString *const kSelectPrompt =
    @"You help a user find a specific vintage iOS app (2008-2014) in an app catalog.\n"
    @"You receive the user's description and a NUMBERED LIST of apps that REALLY EXIST\n"
    @"in the catalog. Pick ONLY the apps from that list that genuinely match.\n"
    @"\n"
    @"ABSOLUTE RULES:\n"
    @"- You may ONLY choose apps from the numbered list. NEVER name or invent an app\n"
    @"  that is not in the list.\n"
    @"- Identify matches by their NUMBER.\n"
    @"- Quality over quantity: pick the few that truly fit (max 6), best first.\n"
    @"- If NONE of the listed apps match, return \"matches\":[] and \"found\":false.\n"
    @"  Do NOT force a wrong pick — finding nothing is a correct, expected outcome.\n"
    @"\n"
    @"Each list entry is: \"N. Title — version — devices — minimum iOS — size\".\n"
    @"You KNOW each app's device compatibility (iPhone/iPad), minimum iOS and size.\n"
    @"You MAY mention these in your reply, and you SHOULD prioritise by them when the\n"
    @"user cares — e.g. asks for an iPad app, a specific iOS version, or a small/light app.\n"
    @"\n"
    @"You are told the user's exact device (model, chip, RAM, iOS). PREFER apps that\n"
    @"actually run on it: an iPad-only app won't run on an iPhone/iPod, and an app whose\n"
    @"minimum iOS is higher than the device's iOS cannot be installed. If your best match\n"
    @"isn't fully compatible, you may still mention it but say so clearly.\n"
    @"If the user is ASKING about their device, or whether an app is compatible with /\n"
    @"runs well on it, ANSWER that directly in the reply using the device info (consider\n"
    @"the chip and RAM). Put the relevant app(s) in matches if any apply, otherwise [].\n"
    @"\n"
    @"Reply in the USER'S language.\n"
    @"Output ONE JSON object — NO markdown, NO code fences, NO extra text:\n"
    @"{\"matches\":[<app numbers, best first>], \"found\":true|false,\n"
    @" \"reply\":\"<1-3 sentences in the user's language>\"}\n"
    @"\n"
    @"If found=true: the reply briefly names the matching app(s) and what they are.\n"
    @"If found=false: politely say you did NOT find it in the catalog; do not point to\n"
    @"external stores or apps outside the list.\n"
    @"\n"
    @"Example (match):\n"
    @"User: \"jeu ou on coupe des cordes pour donner des bonbons\"\n"
    @"List:\n1. Talking Tom Cat — v2.0 — iPhone — iOS 4.0+ — 18.0 MB\n2. Cut the Rope — v1.0 — iPhone/iPad — iOS 4.0+ — 12.3 MB\n3. Fruit Ninja — v1.8 — iPhone — iOS 3.0+ — 20.1 MB\n"
    @"{\"matches\":[2],\"found\":true,\"reply\":\"Oui, c'est Cut the Rope (#2), le jeu ou tu coupes des cordes pour donner des bonbons a Om Nom. Compatible iPhone/iPad, iOS 4.0+, 12 Mo.\"}\n"
    @"\n"
    @"Example (no match):\n"
    @"User: \"une app de montage video 4K avec IA\"\n"
    @"List:\n1. Doodle Jump (v1.8, iOS 4.0)\n2. Angry Birds (v2.0, iOS 4.0)\n"
    @"{\"matches\":[],\"found\":false,\"reply\":\"Je n'ai pas trouve cette app dans le catalogue — il ne contient que des apps de 2008-2014.\"}\n";

// Pull the {...} JSON object out of a raw OpenAI-style response body. Handles the
// OpenAI envelope (choices[0].message.content), a bare "content" field, or raw text,
// then strips ``` fences and extracts the outermost JSON object. Returns nil if there
// is no usable JSON (caller treats nil as a transient failure worth retrying).
static NSDictionary *parseLLMResponse(NSData *resp) {
    if (!resp.length) return nil;
    NSDictionary *outer = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
    NSString *content = nil;
    if ([outer isKindOfClass:[NSDictionary class]]) {
        NSArray *choices = outer[@"choices"];
        if ([choices isKindOfClass:[NSArray class]] && choices.count) {
            content = [[choices firstObject] valueForKeyPath:@"message.content"];
        }
        if (!content.length) content = outer[@"content"];
    }
    if (!content.length) content = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    if (!content.length) return nil;
    NSString *clean = content;
    NSRange fenceStart = [clean rangeOfString:@"```"];
    if (fenceStart.location != NSNotFound) {
        NSRange afterFence = NSMakeRange(NSMaxRange(fenceStart), clean.length - NSMaxRange(fenceStart));
        NSRange newLine = [clean rangeOfString:@"\n" options:0 range:afterFence];
        if (newLine.location != NSNotFound) clean = [clean substringFromIndex:NSMaxRange(newLine)];
        NSRange fenceEnd = [clean rangeOfString:@"```" options:NSBackwardsSearch];
        if (fenceEnd.location != NSNotFound) clean = [clean substringToIndex:fenceEnd.location];
    }
    NSRange jsonStart = [clean rangeOfString:@"{"];
    NSRange jsonEnd = [clean rangeOfString:@"}" options:NSBackwardsSearch];
    if (jsonStart.location == NSNotFound || jsonEnd.location == NSNotFound
        || jsonEnd.location <= jsonStart.location) return nil;
    NSString *jsonStr = [clean substringWithRange:
        NSMakeRange(jsonStart.location, jsonEnd.location - jsonStart.location + 1)];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:
        [jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

static NSString *const kModelPrimary  = @"openai-fast";  // GPT-OSS 20B (OVH), fastest free anon route
static NSString *const kModelFallback = @"openai";       // alias — tried on the LAST attempt
static const NSInteger kLLMMaxAttempts = 3;

// One attempt of the round-trip, with retry-on-transient-failure. The free endpoint
// is genuinely flaky (cold starts, 5xx, rate limits, occasional non-JSON), which is
// why the chat "didn't work sometimes" — a single failed request killed the whole
// interaction. We now retry up to kLLMMaxAttempts with short backoff, and switch to
// the fallback model on the final try. Most failures are fast (5xx/empty), so retries
// are cheap; the long first timeout only matters for a genuine cold start.
static void llmAttempt(NSString *sysWithDevice, NSString *userMsg, float temperature,
                       NSInteger attempt, void (^cb)(NSDictionary *, NSError *)) {
    NSString *model = (attempt >= kLLMMaxAttempts) ? kModelFallback : kModelPrimary;
    NSDictionary *payload = @{
        @"model": model,
        @"messages": @[ @{@"role": @"system", @"content": sysWithDevice},
                        @{@"role": @"user",   @"content": userMsg} ],
        @"private": @YES,
        @"temperature": @(temperature),
        @"max_tokens": @1024,
    };
    NSError *je = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&je];
    if (je) { cb(nil, je); return; }
    // First attempt gets a long timeout for cold starts; retries are short (warm now).
    NSTimeInterval timeout = (attempt == 1) ? 50 : 30;
    CPLog([NSString stringWithFormat:@"[LLM] POST attempt %ld/%ld model=%@ body=%lu temp=%.2f to=%.0fs",
              (long)attempt, (long)kLLMMaxAttempts, model, (unsigned long)bodyData.length, temperature, timeout]);
    NSDate *t0 = [NSDate date];
    [HTTPSClient postURL:kEndpoint
                  headers:@{@"Content-Type": @"application/json", @"Accept": @"application/json"}
                     body:bodyData
                  timeout:timeout
               completion:^(NSData *resp, NSInteger code, NSError *err) {
        NSTimeInterval dt = -[t0 timeIntervalSinceNow];
        NSDictionary *parsed = (!err && code == 200) ? parseLLMResponse(resp) : nil;
        CPLog([NSString stringWithFormat:@"[LLM] attempt %ld done %.1fs code=%ld bytes=%lu parsed=%@ err=%@",
                  (long)attempt, dt, (long)code, (unsigned long)resp.length, parsed ? @"yes" : @"NO",
                  err ? err.localizedDescription : @"(nil)"]);
        BOOL transient = (err != nil) || (code == 0) || (code == 429) || (code >= 500)
                         || (!resp.length) || (parsed == nil);
        if (transient && attempt < kLLMMaxAttempts) {
            double delay = 1.0 * (double)attempt;   // 1s, then 2s
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                llmAttempt(sysWithDevice, userMsg, temperature, attempt + 1, cb);
            });
            return;
        }
        if (parsed) { cb(parsed, nil); return; }
        NSLog(@"[Pollinations] giving up after %ld attempts: code=%ld err=%@", (long)attempt, (long)code, err);
        cb(nil, err ?: [NSError errorWithDomain:@"Pollinations" code:code
                            userInfo:@{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:@"HTTP %ld / no JSON", (long)code]}]);
    }];
}

// Core round-trip: POST system+user, retrying transient failures, and return the
// extracted JSON dict PARSED. Callback hops to main. Reused by every LLM step.
static void callLLMRaw(NSString *systemPrompt, NSString *userMsg, float temperature,
                       void (^completion)(NSDictionary *parsed, NSError *err)) {
    void (^cb)(NSDictionary *, NSError *) = ^(NSDictionary *p, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(p, e); });
    };
    // v1.4: EVERY LLM call is device-aware — append the exact hardware to the system
    // prompt so the model can tailor suggestions and answer compatibility questions.
    NSString *sysWithDevice = [systemPrompt stringByAppendingFormat:
        @"\n\nCONTEXT — User's device: %@. When relevant, tailor your answer to this exact "
        @"hardware (model, chip, RAM, iOS); you may answer questions about the device or "
        @"whether an app is compatible with it.", [DeviceInfo aiSummary]];
    llmAttempt(sysWithDevice, userMsg, temperature, 1, cb);
}

// Thin wrapper for the expansion/alternatives steps: pulls titles + keywords +
// reply out of the raw dictionary.
static void callLLM(NSString *systemPrompt, NSString *userMsg, float temperature,
                    void (^completion)(NSArray *titles, NSArray *keywords,
                                        NSString *reply, NSError *err)) {
    callLLMRaw(systemPrompt, userMsg, temperature, ^(NSDictionary *parsed, NSError *err) {
        if (err) { completion(nil, nil, nil, err); return; }
        NSArray *titles   = [parsed[@"titles"]   isKindOfClass:[NSArray class]]  ? parsed[@"titles"]   : nil;
        NSArray *keywords = [parsed[@"keywords"] isKindOfClass:[NSArray class]]  ? parsed[@"keywords"] : nil;
        NSString *reply   = [parsed[@"reply"]    isKindOfClass:[NSString class]] ? parsed[@"reply"]    : nil;
        NSLog(@"[Pollinations] titles=%@ keywords=%@ reply='%@'",
              [titles componentsJoinedByString:@" | "],
              [keywords componentsJoinedByString:@","], reply);
        completion(titles, keywords, reply, nil);
    });
}

@implementation PollinationsLLM

+ (instancetype)shared {
    static PollinationsLLM *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)askForKeywordsAndReply:(NSString *)userText
                    completion:(void (^)(NSArray *, NSArray *, NSString *, NSError *))completion {
    if (!userText.length) {
        if (completion) completion(nil, nil, nil, nil);
        return;
    }
    // Temperature 0.7: we want creativity for vague descriptions, but not full
    // randomness. The system prompt with examples keeps it grounded.
    callLLM(kSystemPromptBase, userText, 0.7f, completion);
}

- (void)askForAlternativeTitles:(NSString *)userText
                     alreadyTried:(NSArray *)alreadyTried
                       completion:(void (^)(NSArray *, NSArray *, NSString *, NSError *))completion {
    if (!userText.length) {
        if (completion) completion(nil, nil, nil, nil);
        return;
    }
    // Build a follow-up prompt that explicitly excludes the previously-tried titles.
    NSString *triedJoined = alreadyTried.count
        ? [alreadyTried componentsJoinedByString:@", "]
        : @"(none)";
    NSString *altPrompt = [kSystemPromptBase stringByAppendingFormat:
        @"\nCATALOG MISS: the previous candidates [%@] were NOT found in the catalog. \n"
        @"Suggest DIFFERENT vintage iOS apps (also 2008-2014, also pre-iOS 7) that could \n"
        @"match the same description. Think of less famous but plausible alternatives, \n"
        @"clones, or similar genre titles. Do NOT repeat any title from the list above.",
        triedJoined];
    // Higher temperature on retry — first guess was wrong, push for variety.
    callLLM(altPrompt, userText, 0.9f, completion);
}

- (void)selectMatchingCandidates:(NSArray *)candidateLines
                         userText:(NSString *)userText
                       completion:(void (^)(NSArray *, NSString *, BOOL, NSError *))completion {
    if (!candidateLines.count) {
        if (completion) completion(@[], nil, NO, nil);
        return;
    }
    NSMutableString *list = [NSMutableString string];
    for (NSString *line in candidateLines) {
        if ([line isKindOfClass:[NSString class]]) [list appendFormat:@"%@\n", line];
    }
    NSString *userMsg = [NSString stringWithFormat:
        @"User description (any language): \"%@\"\n\n"
        @"Catalog apps you may choose from (choose ONLY from these, refer by number):\n%@",
        userText ?: @"", list];
    // Low temperature: this is a precision task (pick real matches), not a creative one.
    callLLMRaw(kSelectPrompt, userMsg, 0.3f, ^(NSDictionary *parsed, NSError *err) {
        if (err) { if (completion) completion(nil, nil, NO, err); return; }
        NSArray *rawMatches = [parsed[@"matches"] isKindOfClass:[NSArray class]] ? parsed[@"matches"] : @[];
        NSString *reply = [parsed[@"reply"] isKindOfClass:[NSString class]] ? parsed[@"reply"] : nil;
        // `found` may be a bool or be absent — infer from matches when missing.
        BOOL found;
        id f = parsed[@"found"];
        if ([f isKindOfClass:[NSNumber class]]) found = [f boolValue];
        else found = (rawMatches.count > 0);
        // Normalize match entries to NSNumber (the model may emit ints or strings).
        NSMutableArray *nums = [NSMutableArray array];
        for (id x in rawMatches) {
            if ([x respondsToSelector:@selector(integerValue)]) [nums addObject:@([x integerValue])];
        }
        NSLog(@"[Pollinations] grounded matches=%@ found=%d reply='%@'",
              [nums componentsJoinedByString:@","], found, reply);
        if (completion) completion(nums, reply, found, nil);
    });
}

@end
