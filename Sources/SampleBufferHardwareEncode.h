//
//  SampleBufferHardwareEncode.h
//  NeusoftIAPhoneCarcorder
//
//  Created by NEUSOFT on 16/9/20.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol HardwareEncodeDelegate <NSObject>

- (void)getHasCompressedBytes:(const void *)bytes length:(NSUInteger)length;

@end


@interface SampleBufferHardwareEncode : NSObject
typedef void (^VideoCompletionBlock)(void);

@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, weak)     id<HardwareEncodeDelegate> encodeDelegate;
+ (instancetype)sharedInstance;
- (void)startRecording;
- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
- (void)feedSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end
