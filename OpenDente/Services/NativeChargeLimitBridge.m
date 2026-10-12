#import "NativeChargeLimitBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const ODErrorDomain = @"com.opendente.NativeChargeLimitBridge";

static void ODSetError(NSError **error, NSInteger code, NSString *description) {
    if (error) *error = [NSError errorWithDomain:ODErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL ODTestProcess(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if (environment[@"XCTestConfigurationFilePath"] || environment[@"XCTestSessionIdentifier"] ||
        environment[@"XCTestBundlePath"] || NSClassFromString(@"XCTestCase")) return YES;
    for (NSBundle *bundle in NSBundle.allBundles) {
        if ([bundle.bundleURL.pathExtension.lowercaseString isEqualToString:@"xctest"]) return YES;
    }
    return NO;
}

@interface ODNativeChargeLimitBridge ()
@property(nonatomic, strong) NSRecursiveLock *lock;
@property(nonatomic, strong, nullable) id client;
@property(nonatomic) BOOL nativeClientClassAbsent;
@end

@implementation ODNativeChargeLimitBridge

- (instancetype)init {
    self = [super init];
    if (self) _lock = [NSRecursiveLock new];
    return self;
}

/// Compare parsed signatures, rather than hard-coding stack offsets. Calls are
/// made only after every selector's return and argument ABI has been checked.
- (NSDictionary<NSString *, NSArray<NSString *> *> *)chargeLimitContracts {
    return @{
        @"isMCLSupported": @[@"B", @"@", @":"],
        @"getMCLLimitWithError:": @[@"C", @"@", @":", @"^@"],
        @"isMCLCurrentlyEnabled:": @[@"Q", @"@", @":", @"^@"],
        @"availableChargeLimitsWithError:": @[@"@", @"@", @":", @"^@"],
        @"setMCLLimit:error:": @[@"B", @"@", @":", @"C", @"^@"],
        @"disableMCL:": @[@"B", @"@", @":", @"^@"]
    };
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)optimizedChargingContracts {
    return @{
        @"isOBCSupported": @[@"B", @"@", @":"],
        @"isSmartChargingCurrentlyEnabled:": @[@"Q", @"@", @":", @"^@"],
        @"enableSmartCharging:": @[@"B", @"@", @":", @"^@"],
        @"disableSmartCharging:": @[@"B", @"@", @":", @"^@"]
    };
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)temporaryChargingContracts {
    return @{
        @"isMCLSupported": @[@"B", @"@", @":"],
        @"isOBCSupported": @[@"B", @"@", @":"],
        @"temporarilyDisableMCL:": @[@"B", @"@", @":", @"^@"],
        @"temporarilyEnableCharging:": @[@"B", @"@", @":", @"^@"]
    };
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)engagementContracts {
    // This modern reader returns OBC retention separately from the MCL target.
    // Its BOOL return reports success; the first BOOL* is the retention state.
    return @{
        @"isOBCSupported": @[@"B", @"@", @":"],
        @"isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:": @[@"B", @"@", @":", @"^B", @"^Q", @"^B", @"^@"]
    };
}

- (nullable NSDictionary<NSString *, id> *)engagementForClient:(id)client error:(NSError **)error {
    NSDictionary *support = @{@"isOBCSupported": [self engagementContracts][@"isOBCSupported"]};
    if (![self validateClient:client contracts:support error:error]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isOBCSupported"))) return @{@"supported": @NO};
    if (![self validateClient:client contracts:[self engagementContracts] error:error]) return nil;
    BOOL engaged = NO, overrideAllowed = NO;
    unsigned long long chargeLimit = 100;
    NSError *failure = nil;
    BOOL success = ((BOOL (*)(id, SEL, BOOL *, unsigned long long *, BOOL *, NSError **))objc_msgSend)(
        client, NSSelectorFromString(@"isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:"),
        &engaged, &chargeLimit, &overrideAllowed, &failure);
    if (!success || failure) {
        self.client = nil;
        if (failure) { if (error) *error = failure; }
        else ODSetError(error, 3, @"macOS did not return optimized charging retention.");
        return nil;
    }
    return @{@"supported": @YES, @"engaged": @(engaged), @"overrideAllowed": @(overrideAllowed)};
}

- (BOOL)validateClient:(id)client contracts:(NSDictionary<NSString *, NSArray<NSString *> *> *)contracts error:(NSError **)error {
    for (NSString *name in contracts) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [client methodSignatureForSelector:selector];
        NSArray<NSString *> *expected = contracts[name];
        if (![client respondsToSelector:selector] || !signature || signature.numberOfArguments != expected.count - 1 ||
            strcmp(signature.methodReturnType, expected[0].UTF8String) != 0) {
            ODSetError(error, 2, [NSString stringWithFormat:@"PowerUI's %@ method is unavailable or has changed.", name]);
            return NO;
        }
        for (NSUInteger i = 0; i < signature.numberOfArguments; i++) {
            if (strcmp([signature getArgumentTypeAtIndex:i], expected[i + 1].UTF8String) != 0) {
                ODSetError(error, 2, [NSString stringWithFormat:@"PowerUI's %@ argument types have changed.", name]);
                return NO;
            }
        }
    }
    return YES;
}

- (nullable id)clientWithError:(NSError **)error {
    if (self.client) {
        return self.client;
    }
    self.nativeClientClassAbsent = NO;
    // System frameworks can live exclusively in dyld's cache. File existence
    // is deliberately not a prerequisite, and the framework stays loaded.
    if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL)) {
        ODSetError(error, 1, @"The native macOS charge limit framework is unavailable.");
        return nil;
    }
    Class cls = NSClassFromString(@"PowerUISmartChargeClient");
    if (!cls) {
        // The framework loaded, but this macOS version has no client class.
        // Keep this known absence separate from framework/XPC/init failures.
        self.nativeClientClassAbsent = YES;
        ODSetError(error, 1, @"PowerUI's native charge limit client is unavailable.");
        return nil;
    }
    id allocated = [cls alloc];
    SEL initializer = NSSelectorFromString(@"initWithClientName:");
    NSMethodSignature *signature = [allocated methodSignatureForSelector:initializer];
    if (![allocated respondsToSelector:initializer] || !signature || signature.numberOfArguments != 3 ||
        strcmp(signature.methodReturnType, "@") || strcmp([signature getArgumentTypeAtIndex:0], "@") ||
        strcmp([signature getArgumentTypeAtIndex:1], ":") || strcmp([signature getArgumentTypeAtIndex:2], "@")) {
        ODSetError(error, 2, @"PowerUI's client initializer has changed."); return nil;
    }
    id client = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initializer, @"OpenDente");
    if (!client) {
        ODSetError(error, 1, @"PowerUI could not create a native charge limit client.");
        return nil;
    }
    self.client = client;
    return client;
}

- (nullable NSNumber *)mclSupportForClient:(id)client error:(NSError **)error {
    if (![client respondsToSelector:NSSelectorFromString(@"isMCLSupported")]) return @NO;
    NSDictionary *supportContract = @{@"isMCLSupported": [self chargeLimitContracts][@"isMCLSupported"]};
    if (![self validateClient:client contracts:supportContract error:error]) return nil;
    return @(((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported")));
}

- (nullable NSDictionary<NSString *, id> *)readState:(NSError **)error {
    if (error) *error = nil;
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client) {
            if (self.nativeClientClassAbsent) { if (error) *error = nil; return @{@"supported": @NO}; }
            return nil;
        }
        NSNumber *supported = [self mclSupportForClient:client error:error];
        if (!supported) return nil;
        if (!supported.boolValue) return @{@"supported": @NO};
        if (![self validateClient:client contracts:[self chargeLimitContracts] error:error]) return nil;
        NSError *failure = nil;
        id limits = ((id (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"availableChargeLimitsWithError:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return nil; }
        if (![limits isKindOfClass:NSArray.class]) { ODSetError(error, 4, @"PowerUI returned malformed available charge limits."); return nil; }
        unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"getMCLLimitWithError:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return nil; }
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"isMCLCurrentlyEnabled:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return nil; }
        return @{@"supported": @YES, @"availableLimits": [limits copy], @"limit": @(limit), @"enabled": @(enabled)};
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return nil;
    } @finally { [self.lock unlock]; }
}

- (BOOL)applyLimit:(NSInteger)limit error:(NSError **)error {
    if (error) *error = nil;
    // Test bundles must never mutate the host Mac, even when a test accidentally
    // constructs the production transport instead of injecting a fake.
    if (ODTestProcess()) { ODSetError(error, 6, @"Native charging writes are disabled in test processes."); return NO; }
    if (limit < 80 || limit >= 100) { ODSetError(error, 7, @"Use a supported native limit below 100%; disabling is a separate operation."); return NO; }
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self chargeLimitContracts] error:error]) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported"))) {
            ODSetError(error, 1, @"The native macOS charge limit is unsupported on this Mac."); return NO;
        }
        NSError *failure = nil;
        BOOL success = ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(client, NSSelectorFromString(@"setMCLLimit:error:"), (unsigned char)limit, &failure);
        if (!success || failure) {
            self.client = nil;
            if (failure) { if (error) *error = failure; }
            else ODSetError(error, 3, @"macOS rejected the native charge limit change.");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

- (BOOL)disable:(NSError **)error {
    if (error) *error = nil;
    if (ODTestProcess()) { ODSetError(error, 6, @"Native charging writes are disabled in test processes."); return NO; }
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self chargeLimitContracts] error:error]) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported"))) {
            ODSetError(error, 1, @"The native macOS charge limit is unsupported on this Mac."); return NO;
        }
        NSError *failure = nil;
        BOOL success = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"disableMCL:"), &failure);
        if (!success || failure) {
            self.client = nil;
            if (failure) { if (error) *error = failure; }
            else ODSetError(error, 3, @"macOS rejected disabling the native charge limit.");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

- (nullable NSDictionary<NSString *, id> *)readOptimizedCharging:(NSError **)error {
    if (error) *error = nil;
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self optimizedChargingContracts] error:error]) return nil;
        BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isOBCSupported"));
        if (!supported) return @{@"supported": @NO};
        NSError *failure = nil;
        unsigned long long enabled = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"isSmartChargingCurrentlyEnabled:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return nil; }
        return @{@"supported": @YES, @"enabled": @(enabled)};
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return nil;
    } @finally { [self.lock unlock]; }
}

- (BOOL)setOptimizedCharging:(BOOL)enabled error:(NSError **)error {
    if (error) *error = nil;
    if (ODTestProcess()) { ODSetError(error, 6, @"Native charging writes are disabled in test processes."); return NO; }
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self optimizedChargingContracts] error:error]) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isOBCSupported"))) {
            ODSetError(error, 1, @"Native optimized battery charging is unsupported on this Mac."); return NO;
        }
        NSError *failure = nil;
        SEL selector = NSSelectorFromString(enabled ? @"enableSmartCharging:" : @"disableSmartCharging:");
        BOOL success = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, selector, &failure);
        if (!success || failure) {
            self.client = nil;
            if (failure) { if (error) *error = failure; }
            else ODSetError(error, 3, @"macOS rejected the optimized battery charging change.");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

- (nullable NSDictionary<NSString *, id> *)readOptimizedChargingEngagement:(NSError **)error {
    if (error) *error = nil;
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        return client ? [self engagementForClient:client error:error] : nil;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return nil;
    } @finally { [self.lock unlock]; }
}

- (BOOL)supportsTemporaryFullCharge:(NSError **)error {
    if (error) *error = nil;
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client) {
            if (self.nativeClientClassAbsent && error) *error = nil;
            return NO;
        }
        NSNumber *supported = [self mclSupportForClient:client error:error];
        if (!supported || !supported.boolValue) return NO;
        if (![self validateClient:client contracts:[self temporaryChargingContracts] error:error]) return NO;
        if (((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isOBCSupported"))) {
            return [self validateClient:client contracts:[self engagementContracts] error:error];
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

- (BOOL)temporarilyOverrideOptimizedCharging:(NSError **)error {
    if (error) *error = nil;
    if (ODTestProcess()) { ODSetError(error, 6, @"Native charging writes are disabled in test processes."); return NO; }
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self temporaryChargingContracts] error:error] ||
            ![self validateClient:client contracts:[self optimizedChargingContracts] error:error]) return NO;
        NSDictionary *engagement = [self engagementForClient:client error:error];
        if (!engagement) return NO;
        if (![engagement[@"supported"] boolValue] || ![engagement[@"overrideAllowed"] boolValue]) {
            ODSetError(error, 3, @"macOS rejected temporary full charging."); return NO;
        }
        NSError *failure = nil;
        unsigned long long state = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"isSmartChargingCurrentlyEnabled:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return NO; }
        if (state != 1) { ODSetError(error, 3, @"macOS rejected temporary full charging."); return NO; }
        BOOL success = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"temporarilyEnableCharging:"), &failure);
        if (!success || failure) {
            self.client = nil;
            if (failure) { if (error) *error = failure; }
            else ODSetError(error, 3, @"macOS rejected temporary full charging.");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

- (BOOL)temporarilyDisableChargeLimit:(NSInteger)expectedLimit error:(NSError **)error {
    if (error) *error = nil;
    if (ODTestProcess()) { ODSetError(error, 6, @"Native charging writes are disabled in test processes."); return NO; }
    [self.lock lock];
    @try {
        id client = [self clientWithError:error];
        if (!client || ![self validateClient:client contracts:[self temporaryChargingContracts] error:error] ||
            ![self validateClient:client contracts:[self chargeLimitContracts] error:error]) return NO;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported"))) {
            ODSetError(error, 1, @"Native temporary full charging is unsupported on this Mac."); return NO;
        }
        NSError *failure = nil;
        unsigned long long state = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"isMCLCurrentlyEnabled:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return NO; }
        unsigned char limit = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"getMCLLimitWithError:"), &failure);
        if (failure) { self.client = nil; if (error) *error = failure; return NO; }
        if (state != 1 || expectedLimit < 80 || expectedLimit >= 100 || limit != expectedLimit) {
            ODSetError(error, 3, @"macOS rejected temporary full charging."); return NO;
        }
        BOOL success = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client, NSSelectorFromString(@"temporarilyDisableMCL:"), &failure);
        if (!success || failure) {
            self.client = nil;
            if (failure) { if (error) *error = failure; }
            else ODSetError(error, 3, @"macOS rejected temporary full charging.");
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        self.client = nil;
        ODSetError(error, 5, [NSString stringWithFormat:@"PowerUI raised %@: %@", exception.name, exception.reason ?: @"unknown exception"]);
        return NO;
    } @finally { [self.lock unlock]; }
}

@end
