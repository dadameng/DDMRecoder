//
//  SampleBufferModel.m
//  NeusoftIAPhoneCarcorder
//
//  Created by 王浩宇 on 16/9/18.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import "SampleBufferModel.h"
#import <objc/runtime.h>
static NSString * const modelBuffer = @"modelBuffer";
@implementation SampleBufferModel

-(void)addSampleBuffer:(CMSampleBufferRef) sampleBuffer{

    CFRetain(sampleBuffer);
    objc_setAssociatedObject(self, [modelBuffer UTF8String], (__bridge id)(sampleBuffer), OBJC_ASSOCIATION_ASSIGN);
    
}

-(CMSampleBufferRef)sampleBuffer{
    CMSampleBufferRef returnValue = (__bridge CMSampleBufferRef)objc_getAssociatedObject(self,[modelBuffer UTF8String]);
    return returnValue;
}

@end
