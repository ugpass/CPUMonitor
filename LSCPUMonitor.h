#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^LSCPUInfoBlock)(float total_usage, NSString * _Nullable thread_name, float thread_usage, NSString *thread_backtrace);

@interface LSCPUMonitor : NSObject

+ (instancetype)shareInstance;

- (void)startMonitorCPU:(LSCPUInfoBlock)cpuInfoBlock;

- (void)stopMonitorCPU;

@end

NS_ASSUME_NONNULL_END
