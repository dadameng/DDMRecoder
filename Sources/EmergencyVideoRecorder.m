//
//  EmergencyVideoRecorder.m
//  NeusoftIAPhoneCarcorder
//
//  Created by 王浩宇 on 16/9/18.
//  Copyright © 2016年 dadameng. All rights reserved.
//

#import "EmergencyVideoRecorder.h"
@interface EmergencyVideoRecorder()
@property (nonatomic, strong) AVAssetWriter* videoWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor * adaptor;
@property(nonatomic, strong)  AVAssetWriterInput *audioWriterInput;
@property (nonatomic, strong) AVCaptureSession * captureSession;


@end
@implementation EmergencyVideoRecorder
{
    dispatch_queue_t dealQueue;
    NSArray * arrData;
    NSTimer * writerFileTimer;
    CMTime lastSampleTime;
    int frame;
}

+(instancetype)sharedEmergencyVideoRecorder{
    static EmergencyVideoRecorder * recorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recorder = [[EmergencyVideoRecorder alloc] init];
    });
    return recorder;
}


-(instancetype)init

{
    self = [super init];
    if (self) {

    
    frame = 0;
    
    dealQueue = dispatch_queue_create("why_deal_queue_with_sampleBuffer", NULL);
        
    }
       return self;
    
}
-(void)setupVideoWriter{
    
    CGSize size = CGSizeMake(1280, 720);
    
    NSString *betaCompressionDirectory = [NSHomeDirectory()stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/%@_Movie.mp4",[NSDate date]]];
    
    
    
    NSError *error = nil;
    
    
    
    unlink([betaCompressionDirectory UTF8String]);
    
    
    
    //----initialize compression engine
    self.videoWriter = nil;
    self.videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:betaCompressionDirectory]
                        
                                                 fileType:AVFileTypeQuickTimeMovie
                        
                                                    error:&error];
    
    NSParameterAssert(_videoWriter);
    
    if(error)
        
        NSLog(@"error = %@", [error localizedDescription]);
    
    NSDictionary *videoCompressionProps = [NSDictionary dictionaryWithObjectsAndKeys:
                                           
                                           [NSNumber numberWithDouble:128.0*1024.0],AVVideoAverageBitRateKey,
                                           
                                           nil ];
    
    
    
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:AVVideoCodecH264, AVVideoCodecKey,
                                   
                                   [NSNumber numberWithInt:size.width], AVVideoWidthKey,
                                   
                                   [NSNumber numberWithInt:size.height],AVVideoHeightKey,videoCompressionProps, AVVideoCompressionPropertiesKey, nil];
    
    self.videoWriterInput = nil;
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    
    
    
    NSParameterAssert(_videoWriterInput);
    
    
    
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    
    
    
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                           
                                                           [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], kCVPixelBufferPixelFormatTypeKey, nil];
    
    
    
    self.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                    
                                                                                    sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    NSParameterAssert(_videoWriterInput);
    
    NSParameterAssert([_videoWriter canAddInput:_videoWriterInput]);
    
    
    
    if ([_videoWriter canAddInput:_videoWriterInput])
        
        NSLog(@"I can add this input");
    
    else
        
        NSLog(@"i can't add this input");
    
    
    
    // Add the audio input
    
    AudioChannelLayout acl;
    
    bzero( &acl, sizeof(acl));
    
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    
    
    
    NSDictionary* audioOutputSettings = nil;
    
    //    audioOutputSettings = [ NSDictionary dictionaryWithObjectsAndKeys:
    
    //                           [ NSNumber numberWithInt: kAudioFormatAppleLossless ], AVFormatIDKey,
    
    //                           [ NSNumber numberWithInt: 16 ], AVEncoderBitDepthHintKey,
    
    //                           [ NSNumber numberWithFloat: 44100.0 ], AVSampleRateKey,
    
    //                           [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
    
    //                           [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
    
    //                           nil ];
    
    audioOutputSettings = [ NSDictionary dictionaryWithObjectsAndKeys:
                           
                           [ NSNumber numberWithInt: kAudioFormatMPEG4AAC ], AVFormatIDKey,
                           
                           [ NSNumber numberWithInt:64000], AVEncoderBitRateKey,
                           
                           [ NSNumber numberWithFloat: 44100.0 ], AVSampleRateKey,
                           
                           [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                           
                           [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                           
                           nil ];
    
    
    _audioWriterInput = nil;
    _audioWriterInput =[AVAssetWriterInput
                        
                        assetWriterInputWithMediaType: AVMediaTypeAudio
                        
                        outputSettings: audioOutputSettings ] ;
    
    
    
    _audioWriterInput.expectsMediaDataInRealTime = YES;
    
    // add input
    
    [_videoWriter addInput:_audioWriterInput];
    
    [_videoWriter addInput:_videoWriterInput];


}
-(void)dealWithSampleBuffers:(SampleBufferModel*)samplebufferModel {
    

   
//    CFRetain(samplebufferModel.sampleBuffer);
    dispatch_async(dealQueue, ^{

    
    
    
    //CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
    

     lastSampleTime = CMTimeMake(0, 0);
    

       // CMSampleBufferRef sampleBuffer = (__bridge CMSampleBufferRef)(samplebufferModelArr[i]);
        
    lastSampleTime = CMSampleBufferGetPresentationTimeStamp(samplebufferModel.sampleBuffer);
    
        if( frame == 0 && _videoWriter.status != AVAssetWriterStatusWriting  ){
        
    {
        [self setupVideoWriter];
       
        writerFileTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(closeWrittingSession) userInfo:nil repeats:NO];
        
        [_videoWriter startWriting];
        
        [_videoWriter startSessionAtSourceTime:kCMTimeZero];
        
    }
    
    if (samplebufferModel.type == 0)
        
    {
        
        
        
                 if( _videoWriter.status > AVAssetWriterStatusWriting )
            
        {
            
            NSLog(@"Warning: writer status is %ld", (long)_videoWriter.status);
            
            if( _videoWriter.status == AVAssetWriterStatusFailed )
            {
                NSLog(@"Error: %@", _videoWriter.error);
            }
            return;
            
        }
        
        if ([_videoWriterInput isReadyForMoreMediaData]){
            
            if( ![_videoWriterInput appendSampleBuffer:samplebufferModel.sampleBuffer] )
            {
                NSLog(@"Unable to write to video input");
            }
            else
            {
                NSLog(@"already write vidio");
            }
    
    
    }
}
else if (samplebufferModel.type == 1)

{
    
    if( _videoWriter.status > AVAssetWriterStatusWriting )
        
    {
        
        NSLog(@"Warning: writer status is %ld", (long)_videoWriter.status);
        
        if( _videoWriter.status == AVAssetWriterStatusFailed )
        {
            NSLog(@"Error: %@", _videoWriter.error);
        }
        return;
        
    }
    
    if ([_audioWriterInput isReadyForMoreMediaData]){
        
        if( ![_audioWriterInput appendSampleBuffer:samplebufferModel.sampleBuffer] )
        {
            NSLog(@"Unable to write to audio input");
        }
        else
        {
            NSLog(@"already write audio");
        }
    }
}
   
    
   // [self closeVideoWriter];
    


frame ++;

}

   
});
    
}

-(void)closeWrittingSession{
    writerFileTimer = nil;
    [writerFileTimer invalidate];
    [_videoWriter endSessionAtSourceTime:lastSampleTime];
    [_videoWriter finishWritingWithCompletionHandler:^{
        NSLog(@"finish writing");
        frame = 0;
    }];
}

-(void)emrgencyOccured{

    
}
@end
