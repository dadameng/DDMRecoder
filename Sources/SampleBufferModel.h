//
//  SampleBufferModel.h
//  NeusoftIAPhoneCarcorder
//
//  Created by 王浩宇 on 16/9/18.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SampleBufferModel : NSObject

//@property (nonatomic)  CMSampleBufferRef sampleBuffer;
@property (nonatomic, assign) NSTimeInterval timeInterval;
@property (nonatomic, assign) int  type;// 0 for video  , 1 for audio

-(void)addSampleBuffer:(CMSampleBufferRef) sampleBuffer;

-(CMSampleBufferRef)sampleBuffer;

@end
