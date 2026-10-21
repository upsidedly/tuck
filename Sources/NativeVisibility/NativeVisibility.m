#import "NativeVisibility.h"
#import <ApplicationServices/ApplicationServices.h>

BOOL TKRequestAccessibility(void) {
    // Apple's C API declares this immutable option key as a mutable global.
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
}
#import <dlfcn.h>

// These signatures were checked against the runtime on macOS 27.2.
// Resolve the private API dynamically; do not link or redistribute Apple code.
@interface NSObject (TKMenuBarRuntime)
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
- (void)activateWithConfiguration:(id)configuration
               completionHandler:(void (^)(NSError * _Nullable))completion;
- (void)invalidate;
@end

@interface TKVisibilitySession ()
@property(nonatomic) id assertion;
@property(nonatomic) id pendingAssertion;
@property(nonatomic) Class configurationClass;
@property(nonatomic) Class assertionClass;
@property(nonatomic) NSUInteger generation;
@end

@implementation TKVisibilitySession

- (instancetype)init {
    if ((self = [super init])) {
        if (@available(macOS 27.0, *)) {
            void *framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
            if (framework) {
                _configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
                _assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
            }
        }
    }
    return self;
}

- (BOOL)isSupported {
    return [_configurationClass instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)] &&
        [_assertionClass instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)] &&
        [_assertionClass instancesRespondToSelector:@selector(invalidate)];
}

- (void)showAll {
    NSAssert(NSThread.isMainThread, @"Visibility changes belong to the main thread.");
    [self cancelPendingChange];
    [self.assertion invalidate];
    self.assertion = nil;
}

- (void)cancelPendingChange {
    NSAssert(NSThread.isMainThread, @"Visibility changes belong to the main thread.");
    self.generation += 1;
    [self.pendingAssertion invalidate];
    self.pendingAssertion = nil;
}

- (void)showOnlyBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers allowedSystemItems:(NSArray<NSNumber *> *)systemItems completion:(void (^)(NSError *))completion {
    [self cancelPendingChange];
    if (!self.supported) {
        completion([NSError errorWithDomain:@"dev.matthew.tuck" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This macOS version does not support Tuck's menu bar controls."}]);
        return;
    }
    // Clock (2) and Control Center (8) remain available regardless of saved data.
    NSMutableOrderedSet<NSNumber *> *allowed = [NSMutableOrderedSet orderedSetWithArray:systemItems];
    [allowed addObject:@2];
    [allowed addObject:@8];
    id configuration = [[self.configurationClass alloc] initWithAllowedSystemItems:allowed.array
                                                        allowedBundleIdentifiers:bundleIdentifiers];
    id assertion = [self.assertionClass new];
    self.pendingAssertion = assertion;
    NSUInteger generation = self.generation;
    __weak TKVisibilitySession *weakSelf = self;
    [assertion activateWithConfiguration:configuration completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TKVisibilitySession *owner = weakSelf;
            if (!owner || owner.generation != generation) {
                [assertion invalidate];
                return;
            }
            if (error) {
                [assertion invalidate];
                owner.pendingAssertion = nil;
            } else {
                // Swap only after activation so Never Show items remain hidden.
                id previous = owner.assertion;
                owner.assertion = assertion;
                owner.pendingAssertion = nil;
                [previous invalidate];
            }
            completion(error);
        });
    }];
}

- (void)dealloc {
    [_pendingAssertion invalidate];
    [_assertion invalidate];
}
@end
