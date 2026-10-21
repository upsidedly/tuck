#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Request the standard macOS prompt; this never grants access itself.
FOUNDATION_EXPORT BOOL TKRequestAccessibility(void);

/// Owns one process-scoped native menu-bar visibility assertion.
/// No preferences, app state, or system security settings are changed.
@interface TKVisibilitySession : NSObject
@property(nonatomic, readonly, getter=isSupported) BOOL supported;
- (void)showAll;
- (void)cancelPendingChange;
- (void)showOnlyBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
              allowedSystemItems:(NSArray<NSNumber *> *)systemItems
                     completion:(void (^)(NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
