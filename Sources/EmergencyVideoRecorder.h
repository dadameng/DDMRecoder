//
//  EmergencyVideoRecorder.h
//  NeusoftIAPhoneCarcorder
//
//  Created by 王浩宇 on 16/9/18.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import <Foundation/Foundation.h>
#include <time.h>
#import "SampleBufferModel.h"
@interface EmergencyVideoRecorder : NSObject

+(instancetype)sharedEmergencyVideoRecorder;

-(void)dealWithSampleBuffers:(SampleBufferModel*)samplebufferModel;

-(void)emrgencyOccured;

@end
