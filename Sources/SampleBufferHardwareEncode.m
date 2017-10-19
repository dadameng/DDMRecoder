//
//  SampleBufferHardwareEncode.m
//  NeusoftIAPhoneCarcorder
//
//  Created by NEUSOFT on 16/9/20.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import "SampleBufferHardwareEncode.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <VideoToolbox/VideoToolbox.h>

#define DURATION 12
@interface SampleBufferHardwareEncode (){
    dispatch_queue_t _render_queue;
    dispatch_queue_t _appendpixelBuffer_queue;
    dispatch_semaphore_t _frameRenderingSemaphore;
    dispatch_semaphore_t _pixelAppendSemaphore;
    
    CGSize _viewSize;
    CGFloat _scale;
    
    CGColorSpaceRef _rgbColorSpace;
    CVPixelBufferPoolRef _outputBufferPool;
    
    NSString* _filename;
    
    
    NSString * yuvFile;
    VTCompressionSessionRef encodingSession;
    dispatch_queue_t aQueue;
    CMFormatDescriptionRef  format;
    CMSampleTimingInfo * timingInfo;
    int  frameCount;
    
    
    
    NSMutableData *elementaryStream;
    
    
    
}

@property (strong, nonatomic) NSDictionary *outputBufferPoolAuxAttributes;
@property (nonatomic) CFTimeInterval firstTimeStamp;
@property (nonatomic) BOOL isRecording;
@end
@implementation SampleBufferHardwareEncode

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static SampleBufferHardwareEncode *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _viewSize = [UIApplication sharedApplication].delegate.window.bounds.size;
        _scale = [UIScreen mainScreen].scale;
        // record half size resolution for retina iPads
        if ((UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) && _scale > 1) {
            _scale = 1.0;
        }
        _isRecording = NO;
        encodingSession = nil;
        _appendpixelBuffer_queue = dispatch_queue_create("ScreenRecorder.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("ScreenRecorder.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
        
        // For testing out the logic, lets read from a file and then send it to encoder to create h264 stream
        
        // Create the compression session
        
        
        OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, _viewSize.width, _viewSize.height, kCMVideoCodecType_H264, NULL, NULL, NULL, CompressedH264, (__bridge void * _Nullable)(self),  &encodingSession);
        
        if (status != 0)
        {
            NSLog(@"H264: Unable to cpo reate a H264 session");
            return nil;
            
        }
        NSArray *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        
        NSString* doc_path = [path objectAtIndex:0];
        
        _filename = [doc_path stringByAppendingPathComponent:@"demo.h264"];
        
        
        NSFileManager *fileManager =[NSFileManager defaultManager];
        
        [fileManager createFileAtPath:_filename contents:nil attributes:nil];
        
        
        
        elementaryStream = [NSMutableData data];
        //
        //        connection = [[NeuSocketConnection alloc] init];
        //        connection.delegate = self;
        //
        //        [connection connectWithHost:@"192.168.0.108" port:9900];
        
        
        
    }
    return self;
}

void CompressedH264(
                    void * CM_NULLABLE outputCallbackRefCon,
                    void * CM_NULLABLE sourceFrameRefCon,
                    OSStatus status,
                    VTEncodeInfoFlags infoFlags,
                    CM_NULLABLE CMSampleBufferRef sampleBuffer )
{
    
    SampleBufferHardwareEncode* encoder = (__bridge SampleBufferHardwareEncode*)outputCallbackRefCon;
    // Check if we have got a key frame first
    
    // Check if there were any errors encoding
    if (status != noErr) {
        NSLog(@"Error encoding video, err=%lld", (int64_t)status);
        return;
    }
    
    
    // Find out if the sample buffer contains an I-Frame.
    // If so we will write the SPS and PPS NAL units to the elementary stream.
    BOOL isIFrame = NO;
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
    if (CFArrayGetCount(attachmentsArray)) {
        CFBooleanRef notSync;
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachmentsArray, 0);
        BOOL keyExists = CFDictionaryGetValueIfPresent(dict,
                                                       kCMSampleAttachmentKey_NotSync,
                                                       (const void **)&notSync);
        // An I-Frame is a sync frame
        isIFrame = !keyExists || !CFBooleanGetValue(notSync);
    }
    
    // This is the start code that we will write to
    // the elementary stream before every NAL unit
    static const size_t startCodeLength = 4;
    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
    
    // Write the SPS and PPS NAL units to the elementary stream before every I-Frame
    if (isIFrame) {
        CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
        
        // Find out how many parameter sets there are
        size_t numberOfParameterSets;
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                           0, NULL, NULL,
                                                           &numberOfParameterSets,
                                                           NULL);
        
        // Write each parameter set to the elementary stream
        for (int i = 0; i < numberOfParameterSets; i++) {
            const uint8_t *parameterSetPointer;
            size_t parameterSetLength;
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description,
                                                               i,
                                                               &parameterSetPointer,
                                                               &parameterSetLength,
                                                               NULL, NULL);
            
            // Write the parameter set to the elementary stream
//            [encoder appendBytes:startCode length:startCodeLength];
//            [encoder appendBytes:parameterSetPointer length:parameterSetLength];
            uint8_t * tempZone = (uint8_t*)malloc(startCodeLength+parameterSetLength);
            memcpy(tempZone, startCode, startCodeLength);
            memcpy(tempZone + startCodeLength, parameterSetPointer, parameterSetLength);
            [encoder appendBytes:tempZone length:sizeof(startCodeLength+parameterSetLength)];
            free(tempZone);
        }
    }
    
    // Get a pointer to the raw AVCC NAL unit data in the sample buffer
    size_t blockBufferLength;
    uint8_t *bufferDataPointer = NULL;
    CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sampleBuffer),
                                0,
                                NULL,
                                &blockBufferLength,
                                (char **)&bufferDataPointer);
    
    // Loop through all the NAL units in the block buffer
    // and write them to the elementary stream with
    // start codes instead of AVCC length headers
    size_t bufferOffset = 0;
    static const int AVCCHeaderLength = 4;
    while (bufferOffset < blockBufferLength - AVCCHeaderLength) {
        // Read the NAL unit length
        uint32_t NALUnitLength = 0;
        memcpy(&NALUnitLength, bufferDataPointer + bufferOffset, AVCCHeaderLength);
        // Convert the length value from Big-endian to Little-endian
        NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
        // Write start code to the elementary stream
        [encoder appendBytes:startCode length:startCodeLength];
        // Write the NAL unit without the AVCC length header to the elementary stream
        [encoder appendBytes:bufferDataPointer + bufferOffset + AVCCHeaderLength
                      length:NALUnitLength];
        // Move to the next NAL unit in the block buffer
        bufferOffset += AVCCHeaderLength + NALUnitLength;
    }
    
    
    
    
}

//- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
//{
//    CVPixelBufferPoolCreatePixelBuffer(NULL, _outputBufferPool, pixelBuffer);
//    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
//    
//    CGContextRef bitmapContext = NULL;
//    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
//                                          CVPixelBufferGetWidth(*pixelBuffer),
//                                          CVPixelBufferGetHeight(*pixelBuffer),
//                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), _rgbColorSpace,
//                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
//                                          );
//    CGContextScaleCTM(bitmapContext, _scale, _scale);
//    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, _viewSize.height);
//    CGContextConcatCTM(bitmapContext, flipVertical);
//    
//    return bitmapContext;
//}

- (void)appendBytes:(const void *)bytes length:(NSUInteger)length{
    if (self.encodeDelegate && [self.encodeDelegate conformsToProtocol:@protocol(HardwareEncodeDelegate)]) {
        [self.encodeDelegate getHasCompressedBytes:bytes length:length];
    }
    
    //    [elementaryStream appendBytes:bytes length:length];
    //    [connection writeData:[NSData dataWithBytes:bytes length:length] timeout:-1 tag:20];
}


- (void)feedSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    
    if (dispatch_semaphore_wait(_frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    //dispatch_async(_render_queue, ^{
        
        
        CVPixelBufferRef pixelBuffer = NULL;
        
        pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);//add
//        CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
        
        
        // draw each window into the context (other windows include UIKeyboard, UIAlert)
        // FIX: UIKeyboard is currently only rendered correctly in portrait orientation
//        dispatch_sync(dispatch_get_main_queue(), ^{
//            UIGraphicsPushContext(bitmapContext); {
//                for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
//                    [window drawViewHierarchyInRect:CGRectMake(0, 0, _viewSize.width, _viewSize.height) afterScreenUpdates:NO];
//                }
//            } UIGraphicsPopContext();
//        });
        
        //        CGImageRef temporayImage = CGBitmapContextCreateImage(bitmapContext);
        //
        //        CIImage *image = [[CIImage alloc] initWithCGImage:temporayImage];
        //
        //
        //        [temporaryContext render:image toCVPixelBuffer:pixelBuffer];
        
        // append pixelBuffer on a async dispatch_queue, the next frame is rendered whilst this one appends
        // must not overwhelm the queue with pixelBuffers, therefore:
        // check if _append_pixelBuffer_queue is ready
        // if it’s not ready, release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(_pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0) {
            dispatch_async(_appendpixelBuffer_queue, ^{
                
                
                
                
                // Set the properties
                VTSessionSetProperty(encodingSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
                VTSessionSetProperty(encodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
                
                
                // Tell the encoder to start encoding
                
                frameCount++;
                // Get the CV Image buffer
                
                // Create properties
                CMTime presentationTimeStamp = CMTimeMake(frameCount, 1000);
                //CMTime duration = CMTimeMake(1, DURATION);
                VTEncodeInfoFlags flags;
                
                // Pass it to the encoder
                
                OSStatus statusCode = VTCompressionSessionEncodeFrame(encodingSession,
                                                                      pixelBuffer,
                                                                      presentationTimeStamp,
                                                                      kCMTimeInvalid,
                                                                      NULL, (__bridge void *)(self), &flags);
                //                VTCompressionSessionEndPass(EncodingSession, false, NULL);
                
                // Check for error
                if (statusCode != noErr) {
                    //                    NSLog(@"H264: VTCompressionSessionEncodeFrame failed with %d", (int)statusCode);
                    
                    // End the session
                    VTCompressionSessionInvalidate(encodingSession);
                    CFRelease(encodingSession);
                    encodingSession = NULL;
                    return;
                }
                
                
          
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                
                dispatch_semaphore_signal(_pixelAppendSemaphore);
            });
        } else {
          
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
        }
        
        dispatch_semaphore_signal(_frameRenderingSemaphore);
  //  });

    
}

@end
