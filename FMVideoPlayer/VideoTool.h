//
//  VideoTool.h
//  FMVideoPlayer
//
//  Created by FM on 2025/3/11.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#include <ffmpeg/libavcodec/avcodec.h>
#include <ffmpeg/libavutil/frame.h>
#include <ffmpeg/libavutil/imgutils.h>
#include <ffmpeg/libavformat/avformat.h>
#include <ffmpeg/libswscale/swscale.h>

#ifdef __cplusplus
}
#endif

#define NSLog(fmt, ...) { \
NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init]; \
[dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"]; \
NSString *currentDateString = [dateFormatter stringFromDate:[NSDate date]]; \
NSLog((@"%s [%d行] 🎥 FMVideoPlayer - " fmt), [currentDateString UTF8String], __LINE__, ##__VA_ARGS__); \
}\

NS_ASSUME_NONNULL_BEGIN

/// 视频工具，传入AVFrame，返回CMSampleBufferRef
@interface VideoTool : NSObject

+ (instancetype)sharedInstance;

- (CMSampleBufferRef)getRenderDataWithFrame:(AVFrame *)avFrame;

- (void)clear;

- (void)setFPS:(double)fps;

@end

NS_ASSUME_NONNULL_END
