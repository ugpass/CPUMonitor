#import "LSCPUMonitor.h"
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import "LXDBacktraceLogger.h"

//当前线程组中cpu消耗最大的3个
#define kMAX_CPU_USAGE_COUNT 3

//检测CPU间隔
#define kINTERVAL 1.0


@interface LSThreadInfo: NSObject

@property (nonatomic, copy) NSString *threadName;
@property (nonatomic, assign) float cpu_usage;
@property (nonatomic, assign)thread_t thread;

@end
@implementation LSThreadInfo

@end

@interface LSCPUMonitor()

@property (nonatomic, strong)dispatch_source_t timer;
@property (nonatomic, copy)LSCPUInfoBlock cpuInfoBlock;

@end

static LSCPUMonitor *shareInstance = nil;
@implementation LSCPUMonitor

+ (instancetype)shareInstance {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		shareInstance = [[LSCPUMonitor alloc] init];
	});
	return shareInstance;
}

- (void)startMonitorCPU:(LSCPUInfoBlock)cpuInfoBlock {
	self.cpuInfoBlock = [cpuInfoBlock copy];
	self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(0, 0));
	
	dispatch_source_set_timer(self.timer, dispatch_walltime(NULL, 0), kINTERVAL * NSEC_PER_SEC, 0);
	
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(self.timer, ^{
		typeof(weakSelf) strongSelf = weakSelf;
		[strongSelf extendCPUUsageForApp];
	});
	dispatch_resume(self.timer);
	
}

- (void)stopMonitorCPU {
	if (self.timer) {
		dispatch_source_cancel(self.timer);
		self.timer = nil;
	}
}

- (NSArray<LSThreadInfo *> *)findMaxCpuUsageArray:(NSArray<LSThreadInfo *> *)array {
	
	if (!array) return @[];
	if (array.count == 0 || array.count == 1) return array;
	
	NSComparator cmptr = ^(LSThreadInfo * obj1, LSThreadInfo * obj2){
		if (obj1.cpu_usage < obj2.cpu_usage) {
			return (NSComparisonResult)NSOrderedAscending;
		}
		
		if (obj1.cpu_usage > obj2.cpu_usage) {
			return (NSComparisonResult)NSOrderedDescending;
		}
		return (NSComparisonResult)NSOrderedSame;
	};
	NSArray *newArray = [array sortedArrayUsingComparator:cmptr];
	
	return  newArray;
}

- (CGFloat)extendCPUUsageForApp {
	kern_return_t kr;
	thread_array_t         thread_list;
	mach_msg_type_number_t thread_count;
	thread_info_data_t     thinfo;
	mach_msg_type_number_t thread_info_count;
	thread_extended_info_t extend_info_th;
	
	// get threads in the task
	//  获取当前进程中 线程列表
	kr = task_threads(mach_task_self(), &thread_list, &thread_count);
	if (kr != KERN_SUCCESS)
		return -1;
	
	float tot_cpu = 0;
	NSMutableArray *temp = [NSMutableArray array];
	for (int j = 0; j < thread_count; j++) {
		thread_info_count = THREAD_INFO_MAX;
		//获取每一个线程信息
		kr = thread_info(thread_list[j], THREAD_EXTENDED_INFO,
						 (thread_info_t)thinfo, &thread_info_count);
		if (kr != KERN_SUCCESS)
			return -1;
		
		extend_info_th = (thread_extended_info_t)thinfo;
		if (!(extend_info_th->pth_flags & TH_FLAGS_IDLE)) {
			// cpu_usage : Scaled cpu usage percentage. The scale factor is TH_USAGE_SCALE.
			//宏定义TH_USAGE_SCALE返回CPU处理总频率：
			float subThreadCPUUsage = extend_info_th->pth_cpu_usage / (float)TH_USAGE_SCALE;
			tot_cpu += subThreadCPUUsage;
			if (subThreadCPUUsage - 0.0 != 0) {
				LSThreadInfo *info = [[LSThreadInfo alloc] init];
				info.threadName = [[NSString alloc] initWithUTF8String:extend_info_th->pth_name];
				info.cpu_usage = subThreadCPUUsage;
				info.thread = thread_list[j];
				[temp addObject:info];
			}
		}
		
	}
	
	kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
	assert(kr == KERN_SUCCESS);
	
	if (tot_cpu < 0) {
		tot_cpu = 0.;
	}
	
	//找到排名前三大的线程
	NSArray *subArray = [self findMaxCpuUsageArray:[temp copy]];
	int k = 0;
	long count = subArray.count;
	for (long i = count; i--;) {
		k++;
		if (k > kMAX_CPU_USAGE_COUNT) {
			break;
		}
		LSThreadInfo *info = subArray[i];
		NSString *backtrace = _lxd_backtraceOfThread(info.thread);
		if (self.cpuInfoBlock) {
			self.cpuInfoBlock(tot_cpu, info.threadName, info.cpu_usage, backtrace);
		}
	}
	return tot_cpu;
}

- (CGFloat)cpuUsageForApp {
	kern_return_t kr;
	thread_array_t         thread_list;
	mach_msg_type_number_t thread_count;
	thread_info_data_t     thinfo;
	mach_msg_type_number_t thread_info_count;
	thread_basic_info_t basic_info_th;
	
	kr = task_threads(mach_task_self(), &thread_list, &thread_count);
	if (kr != KERN_SUCCESS)
		return -1;
	
	float tot_cpu = 0;
	
	for (int j = 0; j < thread_count; j++) {
		thread_info_count = THREAD_INFO_MAX;
		//获取每一个线程信息
		kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
						 (thread_info_t)thinfo, &thread_info_count);
		if (kr != KERN_SUCCESS)
			return -1;
		
		basic_info_th = (thread_basic_info_t)thinfo;
		if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
			float subThreadCPUUsage = basic_info_th->cpu_usage / (float)TH_USAGE_SCALE;
			tot_cpu += subThreadCPUUsage;
		}
		
	}
	
	kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
	assert(kr == KERN_SUCCESS);
	
	if (tot_cpu < 0) {
		tot_cpu = 0.;
	}
	return tot_cpu;
}

@end
