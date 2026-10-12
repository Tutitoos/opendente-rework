#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lazy adapter for Apple's private PowerUI client. Every exception remains on
/// this Objective-C side of the Swift boundary. These calls are serialized.
@interface ODNativeChargeLimitBridge : NSObject
- (nullable NSDictionary<NSString *, id> *)readState:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)applyLimit:(NSInteger)limit error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)disable:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (nullable NSDictionary<NSString *, id> *)readOptimizedCharging:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (nullable NSDictionary<NSString *, id> *)readOptimizedChargingEngagement:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)setOptimizedCharging:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)supportsTemporaryFullCharge:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)temporarilyOverrideOptimizedCharging:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
- (BOOL)temporarilyDisableChargeLimit:(NSInteger)expectedLimit error:(NSError * _Nullable * _Nullable)error __attribute__((swift_error(none)));
@end

NS_ASSUME_NONNULL_END
