// AppDropJSON.m — NSJSONSerialization backfill for iOS 3.x / 4.x (the class
// first appeared in iOS 5). cJSON-backed. Installed as a class pair at load so
// existing call sites ([NSJSONSerialization JSONObjectWithData:options:error:]
// and dataWithJSONObject:options:error:) work unchanged. No-op on iOS 5+.
//
// Build this file WITHOUT ARC (runtime plumbing).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "cJSON.h"

#pragma mark - cJSON -> Foundation

static id AppDropJSONToFoundation(cJSON *node) {
    if (!node) return [NSNull null];
    if (cJSON_IsNull(node))  return [NSNull null];
    if (cJSON_IsTrue(node))  return [NSNumber numberWithBool:YES];
    if (cJSON_IsFalse(node)) return [NSNumber numberWithBool:NO];
    if (cJSON_IsNumber(node)) {
        double d = node->valuedouble;
        if (d == (double)node->valueint && d == (double)(long long)d)
            return [NSNumber numberWithLongLong:(long long)d];
        return [NSNumber numberWithDouble:d];
    }
    if (cJSON_IsString(node)) {
        const char *s = node->valuestring ? node->valuestring : "";
        return [NSString stringWithUTF8String:s] ?: @"";
    }
    if (cJSON_IsArray(node)) {
        NSMutableArray *arr = [NSMutableArray array];
        for (cJSON *c = node->child; c; c = c->next)
            [arr addObject:AppDropJSONToFoundation(c)];
        return arr;
    }
    if (cJSON_IsObject(node)) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (cJSON *c = node->child; c; c = c->next) {
            NSString *key = c->string ? [NSString stringWithUTF8String:c->string] : nil;
            if (key) [dict setObject:AppDropJSONToFoundation(c) forKey:key];
        }
        return dict;
    }
    return [NSNull null];
}

#pragma mark - Foundation -> cJSON

static cJSON *AppDropFoundationToJSON(id obj) {
    if (!obj || obj == [NSNull null]) return cJSON_CreateNull();
    if ([obj isKindOfClass:[NSString class]]) return cJSON_CreateString([obj UTF8String]);
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *n = obj;
        const char *t = [n objCType];
        if (t && (t[0] == 'c' || t[0] == 'B')) {
            // bool vs char heuristic: CFBoolean reports 'c'
            if (n == (id)kCFBooleanTrue || n == (id)kCFBooleanFalse)
                return cJSON_CreateBool([n boolValue]);
        }
        return cJSON_CreateNumber([n doubleValue]);
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        cJSON *arr = cJSON_CreateArray();
        for (id e in obj) cJSON_AddItemToArray(arr, AppDropFoundationToJSON(e));
        return arr;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        cJSON *o = cJSON_CreateObject();
        for (id k in obj) cJSON_AddItemToObjectCS(o, [[k description] UTF8String], AppDropFoundationToJSON([obj objectForKey:k]));
        return o;
    }
    return cJSON_CreateNull();
}

#pragma mark - Class-method IMPs

static id AppDropJSONObjectWithData(id cls, SEL _cmd, NSData *data, NSUInteger opt, NSError **err) {
    if (err) *err = nil;
    if (![data length]) return nil;
    cJSON *root = cJSON_ParseWithLength((const char *)[data bytes], [data length]);
    if (!root) {
        if (err) *err = [NSError errorWithDomain:@"AppDropJSON" code:3840 userInfo:nil];
        return nil;
    }
    id result = AppDropJSONToFoundation(root);
    cJSON_Delete(root);
    return result;
}

static NSData *AppDropDataWithJSONObject(id cls, SEL _cmd, id object, NSUInteger opt, NSError **err) {
    if (err) *err = nil;
    cJSON *root = AppDropFoundationToJSON(object);
    char *txt = (opt & 1 /*NSJSONWritingPrettyPrinted*/) ? cJSON_Print(root) : cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!txt) return nil;
    NSData *d = [NSData dataWithBytes:txt length:strlen(txt)];
    free(txt);
    return d;
}

static BOOL AppDropIsValidJSONObject(id cls, SEL _cmd, id obj) {
    return [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]];
}

__attribute__((constructor))
static void AppDropInstallNSJSONSerialization(void) {
    if (objc_getClass("NSJSONSerialization")) return;
    Class c = objc_allocateClassPair([NSObject class], "NSJSONSerialization", 0);
    Class meta = object_getClass(c);
    class_addMethod(meta, @selector(JSONObjectWithData:options:error:), (IMP)AppDropJSONObjectWithData, "@@:@L^@");
    class_addMethod(meta, @selector(dataWithJSONObject:options:error:), (IMP)AppDropDataWithJSONObject, "@@:@L^@");
    class_addMethod(meta, @selector(isValidJSONObject:), (IMP)AppDropIsValidJSONObject, "c@:@");
    objc_registerClassPair(c);
}
