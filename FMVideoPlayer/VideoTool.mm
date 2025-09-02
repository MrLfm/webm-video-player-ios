//
//  RenderTool.m
//  FMVideoPlayer
//
//  Created by FM on 2025/3/11.
//

#import "VideoTool.h"
#import "libyuv/libyuv.h"

@interface VideoTool ()
@property (nonatomic, assign) int64_t presentationTimestamp;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) NSInteger frameFPS;
@property (nonatomic, assign) NSInteger frameWidth;
@property (nonatomic, assign) NSInteger frameHeight;
@end

@implementation VideoTool

+ (instancetype)sharedInstance {
    static VideoTool *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [VideoTool.alloc init];
        instance.presentationTimestamp = 0;
    });
    return instance;
}

- (CMSampleBufferRef)getRenderDataWithFrame:(AVFrame *)avFrame {
    // 创建 CVPixelBuffer
    CVPixelBufferRef pixelBuffer = [self getPixelBufferFromFrame:avFrame];
    if (!pixelBuffer) {
//        NSLog(@"创建 CVPixelBuffer 失败！");
        return nil;
    }
    
    // 创建 CMSampleBuffer
    CMSampleBufferRef sampleBuffer = [self getSampleBufferFromPixelBuffer:pixelBuffer];
    if (!sampleBuffer) {
//        NSLog(@"创建 CMSampleBuffer 失败！");
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }
    
    CVPixelBufferRelease(pixelBuffer);// 释放 CVPixelBuffer
    return sampleBuffer;
}

- (CVPixelBufferRef)getPixelBufferFromFrame:(AVFrame *)avFrame {
    if (!avFrame || !avFrame->data[0] || !avFrame->data[1] || !avFrame->data[2]) return NULL;
    if (avFrame->width <= 0 || avFrame->height <= 0) return NULL;
    
    if (_pixelBufferPool == nil
        || avFrame->width != self.frameWidth
        || avFrame->height != self.frameHeight) {
        self.frameWidth = avFrame->width;
        self.frameHeight = avFrame->height;
        [self setupPixelBufferPoolWithWidth:avFrame->width height:avFrame->height];
        if (!_pixelBufferPool) return NULL;
    }
    
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pixelBufferPool, &pixelBuffer) != kCVReturnSuccess || !pixelBuffer) {
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *pixelData = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    int dstStride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    enum AVPixelFormat pix_fmt = (enum AVPixelFormat)avFrame->format;
    
//    NSLog(@"视频格式: %d, 宽高: %dx%d", pix_fmt, avFrame->width, avFrame->height);
    if (pix_fmt == AV_PIX_FMT_YUV420P || pix_fmt == AV_PIX_FMT_YUVJ420P) {
        int yStride = avFrame->linesize[0];
        int uStride = avFrame->linesize[1];
        int vStride = avFrame->linesize[2];
        if (yStride <= 0 || uStride <= 0 || vStride <= 0) {
            NSLog(@"❌ 视频数据异常，转码失败: y:%d u:%d v:%d", yStride, uStride, vStride);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            return NULL;
        }
        
        libyuv::I420ToARGB(avFrame->data[0], yStride,
                           avFrame->data[1], uStride,
                           avFrame->data[2], vStride,
                           pixelData, dstStride,
                           avFrame->width, avFrame->height);
    }
    else {
        struct SwsContext *swsCtx = sws_getContext(
            avFrame->width, avFrame->height, pix_fmt,
            avFrame->width, avFrame->height, AV_PIX_FMT_RGBA,
            SWS_BILINEAR, NULL, NULL, NULL);
        if (swsCtx) {
            uint8_t *dstData[4] = { pixelData, NULL, NULL, NULL };
            int dstLinesize[4] = { dstStride, 0, 0, 0 };
            sws_scale(swsCtx,
                      (const uint8_t * const*)avFrame->data, avFrame->linesize,
                      0, avFrame->height,
                      dstData, dstLinesize);
            sws_freeContext(swsCtx);
        }
        else {
            NSLog(@"❌ 视频数据异常，转码失败，视频格式：%d", pix_fmt);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (void)setupPixelBufferPoolWithWidth:(int)width height:(int)height {
//    NSLog(@"设置PixelBufferPool：宽%@ 高%@", @(width), @(height));
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pixelBufferPool);
}

- (CMSampleBufferRef)getSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return nil;

    CMSampleBufferRef sampleBuffer = NULL;
    CMFormatDescriptionRef formatDescription = NULL;

    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);

    if (formatDescription) {
        CMTime frameDuration = CMTimeMake(1000, (int32_t)(_frameFPS * 1000)); // 提高精度
        CMTime presentationTimeStamp = CMTimeMultiply(frameDuration, (int32_t)self.presentationTimestamp);
        CMSampleTimingInfo sampleTiming = {
            .presentationTimeStamp = presentationTimeStamp,
            .duration = frameDuration,
            .decodeTimeStamp = kCMTimeInvalid
        };
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                           pixelBuffer,
                                           true,
                                           NULL,
                                           NULL,
                                           formatDescription,
                                           &sampleTiming,
                                           &sampleBuffer);
        CFRelease(formatDescription);
        self.presentationTimestamp += 1;
    }

    return sampleBuffer;
}

- (void)clear {
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = nil;
    }
    self.presentationTimestamp = 0;
}

- (void)setFPS:(double)fps {
    _frameFPS = (NSInteger)fps;
}

@end
