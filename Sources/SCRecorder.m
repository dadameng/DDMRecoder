//
//  SCNewCamera.m
//  SCAudioVideoRecorder
//
//  Created by Simon CORSIN on 27/03/14.
//  Copyright (c) 2014 rFlex. All rights reserved.
//

#import "SCRecorder.h"
#import "SCRecordSession_Internal.h"
#import <ImageIO/ImageIO.h>
#import "GPUImageFilter.h"
#import "EmergencyVideoRecorder.h"
#import "SampleBufferModel.h"


static int dateWatermarkWidth  = 300;
static int dateWatermarkHeight = 55;
void setColorConversion601( GLfloat conversionMatrix[9] )
{
    kNeuColorConversion601 = conversionMatrix;
}

void setColorConversion601FullRange( GLfloat conversionMatrix[9] )
{
    kNeuColorConversion601FullRange = conversionMatrix;
}

void setColorConversion709( GLfloat conversionMatrix[9] )
{
    kNeuColorConversion709 = conversionMatrix;
}

#define dispatch_handler(x) if (x != nil) dispatch_async(dispatch_get_main_queue(), x)
#define kSCRecorderRecordSessionQueueKey "SCRecorderRecordSessionQueue"
#define kMinTimeBetweenAppend 0.004
#import "SCWatermarkOverlayView.h"
@interface SCRecorder() {
    AVCaptureVideoPreviewLayer *_previewLayer;
    AVCaptureSession *_captureSession;
    UIView *_previewView;
    AVCaptureVideoDataOutput *_videoOutput;
    AVCaptureMovieFileOutput *_movieOutput;
    AVCaptureAudioDataOutput *_audioOutput;
    AVCaptureStillImageOutput *_photoOutput;
    
    SCSampleBufferHolder *_lastVideoBuffer;
    SCSampleBufferHolder *_lastAudioBuffer;
    CIContext *_context;
    BOOL _audioInputAdded;
    BOOL _audioOutputAdded;
    BOOL _videoInputAdded;
    BOOL _videoOutputAdded;
    BOOL _shouldAutoresumeRecording;
    BOOL _needsSwitchBackToContinuousFocus;
    BOOL _adjustingFocus;
    int _beginSessionConfigurationCount;
    double _lastAppendedVideoTime;
    NSTimer *_movieOutputProgressTimer;
    CMTime _lastMovieFileOutputTime;
    void(^_pauseCompletionHandler)();
    SCFilter *_transformFilter;
    size_t _transformFilterBufferWidth;
    size_t _transformFilterBufferHeight;
    dispatch_queue_t writerQueue;
    /**
     *  这一段是新加的为了加日期标签 start 2016/7/22 15:33 linmeng
     */
    GPUImageRotationMode outputRotation, internalRotation;
    BOOL captureAsYUV;
    int imageBufferWidth, imageBufferHeight;
    const GLfloat *_preferredConversion;
    
    BOOL isFullYUVRange;
    dispatch_semaphore_t frameRenderingSemaphore;
    
    GLuint luminanceTexture, chrominanceTexture;
    GLProgram *yuvConversionProgram;
    GLint yuvConversionPositionAttribute, yuvConversionTextureCoordinateAttribute;
    GLint yuvConversionLuminanceTextureUniform, yuvConversionChrominanceTextureUniform;
    GLint yuvConversionMatrixUniform;
    NSUInteger numberOfFramesCaptured;
    CGFloat totalFrameTimeDuringCapture;
    NSMutableArray * textureArray;
    BOOL isOutPuttingTexture;
    
}
/**
 *  只有在音频标签开启的情况下、才使用这个 Model
 */
@property (nonatomic ,strong) RecodrAsset *movieRecordAsset;
@end

@implementation SCRecorder

static char* SCRecorderFocusContext = "FocusContext";
static char* SCRecorderExposureContext = "ExposureContext";
static char* SCRecorderVideoEnabledContext = "VideoEnabledContext";
static char* SCRecorderAudioEnabledContext = "AudioEnabledContext";
static char* SCRecorderPhotoOptionsContext = "PhotoOptionsContext";

- (id)init {
    self = [super init];
    
    if (self) {
        _sessionQueue = dispatch_queue_create("me.corsin.SCRecorder.RecordSession", nil);
        
        
        dispatch_queue_set_specific(_sessionQueue, kSCRecorderRecordSessionQueueKey, "true", nil);
        dispatch_set_target_queue(_sessionQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
        _captureSessionPreset = AVCaptureSessionPresetHigh;
        
        _previewLayer = [[AVCaptureVideoPreviewLayer alloc] init];
        
        _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        textureArray = [[NSMutableArray alloc] init];//add

        writerQueue = dispatch_queue_create("wahaha_writerVideo_queue", NULL);
        
        isOutPuttingTexture = YES;//add
        _initializeSessionLazily = YES;
        
        _videoOrientation = AVCaptureVideoOrientationLandscapeRight;
        _videoStabilizationMode = AVCaptureVideoStabilizationModeStandard;
        
        [[NSNotificationCenter defaultCenter] addObserver:self  selector:@selector(_subjectAreaDidChange) name:AVCaptureDeviceSubjectAreaDidChangeNotification  object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaServicesWereReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaServicesWereLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self  selector:@selector(deviceOrientationChanged:) name:UIDeviceOrientationDidChangeNotification  object:nil];
        
        
        _lastVideoBuffer = [SCSampleBufferHolder new];
        _lastAudioBuffer = [SCSampleBufferHolder new];
        _maxRecordDuration = kCMTimeInvalid;
        _resetZoomOnChangeDevice = YES;
        _mirrorOnFrontCamera = NO;
        _automaticallyConfiguresApplicationAudioSession = YES;
        
        self.device = AVCaptureDevicePositionBack;
        _videoConfiguration = [SCVideoConfiguration new];
        
        _audioConfiguration = [SCAudioConfiguration new];
        //        _photoConfiguration = [SCPhotoConfiguration new];
        
        [_videoConfiguration addObserver:self forKeyPath:@"enabled" options:NSKeyValueObservingOptionNew context:SCRecorderVideoEnabledContext];
        [_audioConfiguration addObserver:self forKeyPath:@"enabled" options:NSKeyValueObservingOptionNew context:SCRecorderAudioEnabledContext];
        //        [_photoConfiguration addObserver:self forKeyPath:@"options" options:NSKeyValueObservingOptionNew context:SCRecorderPhotoOptionsContext];
        
        _context = [SCContext new].CIContext;
        
        /**
         *  这一段是新加的为了加日期标签 start 2016/7/22 15:33 linmeng
         */
        frameRenderingSemaphore = dispatch_semaphore_create(1);
        outputRotation = kGPUImageNoRotation;
        internalRotation = kGPUImageNoRotation;
        captureAsYUV = YES;
        _preferredConversion = kColorConversion709;
        //
        [[RACObserve([RecordConfiguration shareInstances], emergencyButtonTouched ) skip:1]subscribeNext:^(NSNumber* touched) {
            if([[RecordConfiguration shareInstances] emergencyButtonTouched]){
              //TODO
            }
        }];
//
    }
    
    return self;
}

- (void)dealloc {
    [_videoConfiguration removeObserver:self forKeyPath:@"enabled"];
    [_audioConfiguration removeObserver:self forKeyPath:@"enabled"];
    //    [_photoConfiguration removeObserver:self forKeyPath:@"options"];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self unprepare];
#if !OS_OBJECT_USE_OBJC
    if (frameRenderingSemaphore != NULL)
    {
        dispatch_release(frameRenderingSemaphore);
    }
#endif
    
}

+ (SCRecorder*)recorder {
    return [[SCRecorder alloc] init];
}

- (void)applicationDidEnterBackground:(id)sender {
    _shouldAutoresumeRecording = _isRecording;
    //#if !OS_OBJECT_USE_OBJC
    //    if (frameRenderingSemaphore != NULL)
    //    {
    //        dispatch_release(frameRenderingSemaphore);
    //    }
    //#endif
    [self pause];
}

- (void)applicationDidBecomeActive:(id)sender {
    //    frameRenderingSemaphore = dispatch_semaphore_create(1);//add
    [self reconfigureVideoInput:self.videoConfiguration.enabled audioInput:self.audioConfiguration.enabled];
    
    if (_shouldAutoresumeRecording) {
        _shouldAutoresumeRecording = NO;
        [self record];
    }
}

- (void)deviceOrientationChanged:(id)sender {
    if (_autoSetVideoOrientation) {
        dispatch_sync(_sessionQueue, ^{
            [self updateVideoOrientation];
        });
    }
}

- (void)sessionRuntimeError:(id)sender {
    [self startRunning];
}

- (void)updateVideoOrientation {
    
    NSLog(@"orientiation did changed");
    
    if (!_session.currentSegmentHasAudio && !_session.currentSegmentHasVideo) {
        [_session deinitialize];
    }
    
    AVCaptureVideoOrientation videoOrientation = [self actualVideoOrientation];
    AVCaptureConnection *videoConnection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    
    if ([videoConnection isVideoOrientationSupported]) {
        videoConnection.videoOrientation = videoOrientation;
    }
    if ([_previewLayer.connection isVideoOrientationSupported]) {
        _previewLayer.connection.videoOrientation = videoOrientation;
    }
    
    AVCaptureConnection *photoConnection = [_photoOutput connectionWithMediaType:AVMediaTypeVideo];
    if ([photoConnection isVideoOrientationSupported]) {
        photoConnection.videoOrientation = videoOrientation;
    }
    
    AVCaptureConnection *movieOutputConnection = [_movieOutput connectionWithMediaType:AVMediaTypeVideo];
    if (movieOutputConnection.isVideoOrientationSupported) {
        movieOutputConnection.videoOrientation = videoOrientation;
    }
    
}

- (void)beginConfiguration {
    if (_captureSession != nil) {
        _beginSessionConfigurationCount++;
        if (_beginSessionConfigurationCount == 1) {
            [_captureSession beginConfiguration];
        }
    }
}

- (void)commitConfiguration {
    if (_captureSession != nil) {
        _beginSessionConfigurationCount--;
        if (_beginSessionConfigurationCount == 0) {
            [_captureSession commitConfiguration];
        }
    }
}

- (BOOL)_reconfigureSession {
    NSError *newError = nil;
    
    AVCaptureSession *session = _captureSession;
    
    if (session != nil) {
        [self beginConfiguration];
        
        if (![session.sessionPreset isEqualToString:_captureSessionPreset]) {
            if ([session canSetSessionPreset:_captureSessionPreset]) {
                session.sessionPreset = _captureSessionPreset;
            } else {
                newError = [SCRecorder createError:@"Cannot set session preset"];
            }
        }
        
        if (self.fastRecordMethodEnabled) {
            if (_movieOutput == nil) {
                _movieOutput = [AVCaptureMovieFileOutput new];
            }
            
            if (_videoOutput != nil && [session.outputs containsObject:_videoOutput]) {
                [session removeOutput:_videoOutput];
            }
            
            if (_audioOutput != nil && [session.outputs containsObject:_audioOutput]) {
                [session removeOutput:_audioOutput];
            }
            
            if (![session.outputs containsObject:_movieOutput]) {
                if ([session canAddOutput:_movieOutput]) {
                    [session addOutput:_movieOutput];
                    
                } else {
                    if (newError == nil) {
                        newError = [SCRecorder createError:@"Cannot add movieOutput inside the session"];
                    }
                }
            }
            
        } else {
            if (_movieOutput != nil && [session.outputs containsObject:_movieOutput]) {
                [session removeOutput:_movieOutput];
            }
            
            _videoOutputAdded = NO;
            if (self.videoConfiguration.enabled) {
                if (_videoOutput == nil) {
                    _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
                    _videoOutput.alwaysDiscardsLateVideoFrames = NO;
                    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
                    {
                        BOOL supportsFullYUVRange = NO;
                        NSArray *supportedPixelFormats = _videoOutput.availableVideoCVPixelFormatTypes;
                        for (NSNumber *currentPixelFormat in supportedPixelFormats)
                        {
                            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                            {
                                supportsFullYUVRange = YES;
                            }
                        }
                        
                        if (supportsFullYUVRange)
                        {
                            [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
                            isFullYUVRange = YES;
                        }
                        else
                        {
                            [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
                            isFullYUVRange = NO;
                        }
                    }
                    else
                    {
                        [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
                    }
                    
                    //以下setting添加回来试试
                    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
                    NSNumber* value = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA];
                    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:value forKey:key];
                    [_videoOutput setVideoSettings:videoSettings];
                    //end
                    
                    [_videoOutput setSampleBufferDelegate:self queue:_sessionQueue];
                }
                
                if (![session.outputs containsObject:_videoOutput]) {
                    if ([session canAddOutput:_videoOutput]) {
                        [session addOutput:_videoOutput];
                        _videoOutputAdded = YES;
                    } else {
                        if (newError == nil) {
                            newError = [SCRecorder createError:@"Cannot add videoOutput inside the session"];
                        }
                    }
                } else {
                    _videoOutputAdded = YES;
                }
            }
            
            _audioOutputAdded = NO;
            if (self.audioConfiguration.enabled) {
                if (_audioOutput == nil) {
                    _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
                    [_audioOutput setSampleBufferDelegate:self queue:_sessionQueue];
                }
                
                if (![session.outputs containsObject:_audioOutput]) {
                    if ([session canAddOutput:_audioOutput]) {
                        [session addOutput:_audioOutput];
                        _audioOutputAdded = YES;
                    } else {
                        if (newError == nil) {
                            newError = [SCRecorder createError:@"Cannot add audioOutput inside the sesssion"];
                        }
                    }
                } else {
                    _audioOutputAdded = YES;
                }
            }
        }
        
        if (self.photoConfiguration.enabled) {
            if (_photoOutput == nil) {
                _photoOutput = [[AVCaptureStillImageOutput alloc] init];
                _photoOutput.outputSettings = [self.photoConfiguration createOutputSettings];
            }
            
            if (![session.outputs containsObject:_photoOutput]) {
                if ([session canAddOutput:_photoOutput]) {
                    [session addOutput:_photoOutput];
                } else {
                    if (newError == nil) {
                        newError = [SCRecorder createError:@"Cannot add photoOutput inside the session"];
                    }
                }
            }
        }
        
        [self commitConfiguration];
    }
    _error = newError;
    
    return newError == nil;
}
- (void)configureGPUImage{
    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
    {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = _videoOutput.availableVideoCVPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats)
        {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            {
                supportsFullYUVRange = YES;
            }
        }
        
        if (supportsFullYUVRange)
        {
            [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
            isFullYUVRange = YES;
        }
        else
        {
            [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
            isFullYUVRange = NO;
        }
    }
    else
    {
        [_videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    }
    
    void (^block)() = ^{
        if (captureAsYUV)
        {
            [GPUImageContext useImageProcessingContext];
            //            if ([GPUImageContext deviceSupportsRedTextures])
            //            {
            //                yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVVideoRangeConversionForRGFragmentShaderString];
            //            }
            //            else
            //            {
            if (isFullYUVRange)
            {
                yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVFullRangeConversionForLAFragmentShaderString];
            }
            else
            {
                yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUVVideoRangeConversionForLAFragmentShaderString];
            }
            
            //            }
            
            if (!yuvConversionProgram.initialized)
            {
                [yuvConversionProgram addAttribute:@"position"];
                [yuvConversionProgram addAttribute:@"inputTextureCoordinate"];
                
                if (![yuvConversionProgram link])
                {
                    NSString *progLog = [yuvConversionProgram programLog];
                    NSLog(@"Program link log: %@", progLog);
                    NSString *fragLog = [yuvConversionProgram fragmentShaderLog];
                    NSLog(@"Fragment shader compile log: %@", fragLog);
                    NSString *vertLog = [yuvConversionProgram vertexShaderLog];
                    NSLog(@"Vertex shader compile log: %@", vertLog);
                    yuvConversionProgram = nil;
                    NSAssert(NO, @"Filter shader link failed");
                }
            }
            
            yuvConversionPositionAttribute = [yuvConversionProgram attributeIndex:@"position"];
            yuvConversionTextureCoordinateAttribute = [yuvConversionProgram attributeIndex:@"inputTextureCoordinate"];
            yuvConversionLuminanceTextureUniform = [yuvConversionProgram uniformIndex:@"luminanceTexture"];
            yuvConversionChrominanceTextureUniform = [yuvConversionProgram uniformIndex:@"chrominanceTexture"];
            yuvConversionMatrixUniform = [yuvConversionProgram uniformIndex:@"colorConversionMatrix"];
            [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
            
            glEnableVertexAttribArray(yuvConversionPositionAttribute);
            glEnableVertexAttribArray(yuvConversionTextureCoordinateAttribute);
        }
        
    };
    runSynchronouslyOnVideoProcessingQueue(block);//add
    if ([SCRecorder isSessionQueue]) {
        block();
    } else {
        dispatch_sync(_sessionQueue, block);
    }
    
    
    
}
- (BOOL)prepare:(NSError **)error {
    if (_captureSession != nil) {
        [NSException raise:@"SCCameraException" format:@"The session is already opened"];
    }
    
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    session.automaticallyConfiguresApplicationAudioSession = self.automaticallyConfiguresApplicationAudioSession;
    _beginSessionConfigurationCount = 0;
    _captureSession = session;
    
    [self beginConfiguration];
    
    BOOL success = [self _reconfigureSession];
    
    if (!success && error != nil) {
        *error = _error;
    }
    
    _previewLayer.session = session;
    
    
    [self reconfigureVideoInput:YES audioInput:YES];
    AVCaptureConnection *videoConnection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    
    if ([videoConnection isVideoOrientationSupported]) {
        videoConnection.videoOrientation = _videoOrientation;
    }
    if ([_previewLayer.connection isVideoOrientationSupported]) {
        _previewLayer.connection.videoOrientation = _videoOrientation;
    }
    [self configureGPUImage];//因为没生成纹理，煮掉这个函数，一会去解决
    
    [self commitConfiguration];
    
    return success;
}

- (BOOL)startRunning {
    BOOL success = YES;
    if (!self.isPrepared) {
        success = [self prepare:nil];
    }
    
    if (!_captureSession.isRunning) {
        [_captureSession startRunning];
    }
    
    return success;
}
-(BOOL)isRunningCapture{
    return _captureSession.isRunning;
}

- (void)stopRunning {
    [_captureSession stopRunning];
}

- (void)_subjectAreaDidChange {
    id<SCRecorderDelegate> delegate = self.delegate;
    
    if (![delegate respondsToSelector:@selector(recorderShouldAutomaticallyRefocus:)] || [delegate recorderShouldAutomaticallyRefocus:self]) {
        [self focusCenter];
    }
}

- (UIImage *)_imageFromSampleBufferHolder:(SCSampleBufferHolder *)sampleBufferHolder {
    __block CMSampleBufferRef sampleBuffer = nil;
    dispatch_sync(_sessionQueue, ^{
        sampleBuffer = sampleBufferHolder.sampleBuffer;
        
        if (sampleBuffer != nil) {
            CFRetain(sampleBuffer);
        }
    });
    
    if (sampleBuffer == nil) {
        return nil;
    }
    
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:buffer];
    
    CGImageRef cgImage = [_context createCGImage:ciImage fromRect:CGRectMake(0, 0, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))];
    
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    
    CGImageRelease(cgImage);
    CFRelease(sampleBuffer);
    
    return image;
}

- (UIImage *)snapshotOfLastVideoBuffer {
    return [self _imageFromSampleBufferHolder:_lastVideoBuffer];
}

- (void)capturePhoto:(void(^)(NSError*, UIImage*))completionHandler {
    AVCaptureConnection *connection = [_photoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection != nil) {
        [_photoOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:
         ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
             
             if (imageDataSampleBuffer != nil && error == nil) {
                 NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                 if (jpegData) {
                     UIImage *image = [UIImage imageWithData:jpegData];
                     if (completionHandler != nil) {
                         completionHandler(nil, image);
                     }
                 } else {
                     if (completionHandler != nil) {
                         completionHandler([SCRecorder createError:@"Failed to create jpeg data"], nil);
                     }
                 }
             } else {
                 if (completionHandler != nil) {
                     completionHandler(error, nil);
                 }
             }
         }];
    } else {
        if (completionHandler != nil) {
            completionHandler([SCRecorder createError:@"Camera session not started or Photo disabled"], nil);
        }
    }
}

- (void)unprepare {
    if (_captureSession != nil) {
        for (AVCaptureDeviceInput *input in _captureSession.inputs) {
            [_captureSession removeInput:input];
            if ([input.device hasMediaType:AVMediaTypeVideo]) {
                [self removeVideoObservers:input.device];
            }
        }
        
        for (AVCaptureOutput *output in _captureSession.outputs) {
            [_captureSession removeOutput:output];
        }
        
        _previewLayer.session = nil;
        _captureSession = nil;
    }
    [self _reconfigureSession];
}

- (void)_progressTimerFired:(NSTimer *)progressTimer {
    CMTime recordedDuration = _movieOutput.recordedDuration;
    
    if (CMTIME_COMPARE_INLINE(recordedDuration, !=, _lastMovieFileOutputTime)) {
        SCRecordSession *recordSession = _session;
        id<SCRecorderDelegate> delegate = self.delegate;
        
        if (recordSession != nil) {
            if ([delegate respondsToSelector:@selector(recorder:didAppendVideoSampleBufferInSession:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate recorder:self didAppendVideoSampleBufferInSession:recordSession];
                });
            }
            if ([delegate respondsToSelector:@selector(recorder:didAppendAudioSampleBufferInSession:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate recorder:self didAppendAudioSampleBufferInSession:_session];
                });
            }
        }
    }
    
    _lastMovieFileOutputTime = recordedDuration;
}

- (void)record {
    void (^block)() = ^{
        _isRecording = YES;
        if (_movieOutput != nil && _session != nil) {
            _movieOutput.maxRecordedDuration = self.maxRecordDuration;
            [self beginRecordSegmentIfNeeded:_session];
        }
        if (_videoOutput != nil && _session != nil) {
            [self beginRecordSegmentIfNeeded:_session];
        }
    };
    
    if ([SCRecorder isSessionQueue]) {
        block();
    } else {
        dispatch_sync(_sessionQueue, block);
    }
}

- (void)pause {
    [self pause:nil];
}

- (void)pause:(void(^)())completionHandler {
    _isRecording = NO;
    
    void (^block)() = ^{
        SCRecordSession *recordSession = _session;
        
        if (recordSession != nil) {
            if (recordSession.recordSegmentReady) {
                NSDictionary *info = [self _createSegmentInfo];
                if (recordSession.isUsingMovieFileOutput) {
                    [_movieOutputProgressTimer invalidate];
                    _movieOutputProgressTimer = nil;
                    if ([recordSession endSegmentWithInfo:info completionHandler:nil]) {
                        _pauseCompletionHandler = completionHandler;
                    } else {
                        dispatch_handler(completionHandler);
                    }
                } else {
                    [recordSession endSegmentWithInfo:info completionHandler:^(SCRecordSessionSegment *segment, NSError *error) {
                        id<SCRecorderDelegate> delegate = self.delegate;
                        if ([delegate respondsToSelector:@selector(recorder:didCompleteSegment:inSession:error:)]) {
                            [delegate recorder:self didCompleteSegment:segment inSession:recordSession error:error];
                        }
                        if (completionHandler != nil) {
                            completionHandler();
                        }
                    }];
                }
            } else {
                dispatch_handler(completionHandler);
            }
        } else {
            dispatch_handler(completionHandler);
        }
    };
    
    if ([SCRecorder isSessionQueue]) {
        block();
    } else {
        dispatch_async(_sessionQueue, block);
    }
}

+ (NSError*)createError:(NSString*)errorDescription {
    return [NSError errorWithDomain:@"SCRecorder" code:200 userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
}

- (void)beginRecordSegmentIfNeeded:(SCRecordSession *)recordSession {
    if (!recordSession.recordSegmentBegan) {
        NSError *error = nil;
        BOOL beginSegment = YES;
        if (_movieOutput != nil && self.fastRecordMethodEnabled) {
            if (recordSession.recordSegmentReady || !recordSession.isUsingMovieFileOutput) {
                /**
                 *   修正录一会视频没有声音的情况 默认值是 10
                 */
                _movieOutput.movieFragmentInterval = kCMTimeInvalid;
                
                [recordSession beginRecordSegmentUsingMovieFileOutput:_movieOutput error:&error delegate:self];
            } else {
                beginSegment = NO;
            }
        } else {
            [recordSession beginSegment:&error];
        }
        
        id<SCRecorderDelegate> delegate = self.delegate;
        if (beginSegment && [delegate respondsToSelector:@selector(recorder:didBeginSegmentInSession:error:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [delegate recorder:self didBeginSegmentInSession:recordSession error:error];
            });
        }
    }
}

- (void)checkRecordSessionDuration:(SCRecordSession *)recordSession {
    CMTime currentRecordDuration = recordSession.duration;
    NSLog(@"seconds is %f",CMTimeGetSeconds(currentRecordDuration));
    
    CMTime suggestedMaxRecordDuration = _maxRecordDuration;
    
    if (CMTIME_IS_VALID(suggestedMaxRecordDuration)) {
        if (CMTIME_COMPARE_INLINE(currentRecordDuration, >=, suggestedMaxRecordDuration)) {
            //            _isRecording = NO;
            
            dispatch_async(_sessionQueue, ^{
                [recordSession endSegmentWithInfo:[self _createSegmentInfo] completionHandler:^(SCRecordSessionSegment *segment, NSError *error) {
                    
                    
                    id<SCRecorderDelegate> delegate = self.delegate;
                    if ([delegate respondsToSelector:@selector(recorder:didCompleteSegment:inSession:error:)]) {
                        [delegate recorder:self didCompleteSegment:segment inSession:recordSession error:error];
                    }
                    
                    if ([delegate respondsToSelector:@selector(recorder:didCompleteSession:)]) {
                        [delegate recorder:self didCompleteSession:recordSession];
                    }
                    
                }];
            });
        }
    }
}

- (CMTime)frameDurationFromConnection:(AVCaptureConnection *)connection {
    AVCaptureDevice *device = [self currentVideoDeviceInput].device;
    
    if ([device respondsToSelector:@selector(activeVideoMaxFrameDuration)]) {
        return device.activeVideoMinFrameDuration;
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return connection.videoMinFrameDuration;
#pragma clang diagnostic pop
}

- (SCFilter *)_transformFilterUsingBufferWidth:(size_t)bufferWidth bufferHeight:(size_t)bufferHeight mirrored:(BOOL)mirrored {
    if (_transformFilter == nil || _transformFilterBufferWidth != bufferWidth || _transformFilterBufferHeight != bufferHeight) {
        BOOL shouldMirrorBuffer = _keepMirroringOnWrite && mirrored;
        
        if (!shouldMirrorBuffer) {
            _transformFilter = nil;
        } else {
            CGAffineTransform tx = CGAffineTransformIdentity;
            
            _transformFilter = [SCFilter filterWithAffineTransform:CGAffineTransformTranslate(CGAffineTransformScale(tx, -1, 1), -(CGFloat)bufferWidth, 0)];
        }
        
        _transformFilterBufferWidth = bufferWidth;
        _transformFilterBufferHeight = bufferHeight;
    }
    
    return _transformFilter;
}

- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer toRecordSession:(SCRecordSession *)recordSession duration:(CMTime)duration connection:(AVCaptureConnection *)connection completion:(void(^)(BOOL success))completion {
    CVPixelBufferRef sampleBufferImage = CMSampleBufferGetImageBuffer(sampleBuffer);
    size_t bufferWidth = (CGFloat)CVPixelBufferGetWidth(sampleBufferImage);
    size_t bufferHeight = (CGFloat)CVPixelBufferGetHeight(sampleBufferImage);
    
    CMTime time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    SCFilter *filterGroup = _videoConfiguration.filter;
    SCFilter *transformFilter = [self _transformFilterUsingBufferWidth:bufferWidth bufferHeight:bufferHeight mirrored:
                                 _device == AVCaptureDevicePositionFront
                                 ];
    
    
    //    [self enqueuedSampleBufferToAdasWithSampleBuffer:sampleBuffer];
    
    if (filterGroup == nil && transformFilter == nil) {
        BOOL dateWatermarkEnable = [[STANDARD_USERDEFAULT objectForKey:@"rec_date_label"] boolValue];
        CVPixelBufferRef pixbuffer;
//        CVPixelBufferLockBaseAddress(pixbuffer, 0);

        if (dateWatermarkEnable) {
            pixbuffer = [self progressDateWatermarkPixelBuffer:sampleBufferImage];
            
        }else{
            pixbuffer = sampleBufferImage;
            
        }

        
        [recordSession appendVideoPixelBuffer:pixbuffer atTime:time duration:duration completion:^(BOOL success) {
            if (dateWatermarkEnable) {
                CVPixelBufferRelease(pixbuffer);
                
            }
            
            completion(success);
        }];
        return;
    }
    
    CVPixelBufferRef pixelBuffer = [recordSession createPixelBuffer];
    
    if (pixelBuffer == nil) {
        completion(NO);
        return;
    }
    
    CIImage *image = [CIImage imageWithCVPixelBuffer:sampleBufferImage];
    CFTimeInterval seconds = CMTimeGetSeconds(time);
    
    if (transformFilter != nil) {
        image = [transformFilter imageByProcessingImage:image atTime:seconds];
    }
    
    if (filterGroup != nil) {
        image = [filterGroup imageByProcessingImage:image atTime:seconds];
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    [_context render:image toCVPixelBuffer:pixelBuffer];
    
    [recordSession appendVideoPixelBuffer:pixelBuffer atTime:time duration:duration completion:^(BOOL success) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        
        CVPixelBufferRelease(pixelBuffer);
        
        completion(success);
    }];
}
//- (void)enqueuedSampleBufferToAdasWithSampleBuffer:(CMSampleBufferRef)imageSampeBuffer{
//    int ret;
//    ACamData data;
//    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(imageSampeBuffer);
//    /* unlock the buffer*/
//    if(CVPixelBufferLockBaseAddress(imageBuffer, 0) == kCVReturnSuccess)
//    {
//        UInt8 *bufferbasePtr = (UInt8 *)CVPixelBufferGetBaseAddress(imageBuffer);
//        UInt8 *bufferPtr = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,0);
//        UInt8 *bufferPtr1 = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,1);
//        size_t buffeSize = CVPixelBufferGetDataSize(imageBuffer);
//        size_t width = CVPixelBufferGetWidth(imageBuffer);
//        size_t height = CVPixelBufferGetHeight(imageBuffer);
//        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
//        size_t bytesrow0 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,0);
//        size_t bytesrow1  = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,1);
//        size_t bytesrow2 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,2);
//        UInt8 *yuv420_data = (UInt8 *)malloc(width * height *3/ 2);//buffer to store YUV with layout YYYYYYYYUUVV
//
//        /* convert NV21 data to YUV420*/
//
//        UInt8 *pY = bufferPtr ;
//        UInt8 *pUV = bufferPtr1;
//        UInt8 *pU = yuv420_data + width*height;
//        UInt8 *pV = pU + width*height/4;
//        for(int i =0;i<height;i++)
//        {
//            memcpy(yuv420_data+i*width,pY+i*bytesrow0,width);
//        }
//        for(int j = 0;j<height/2;j++)
//        {
//            for(int i =0;i<width/2;i++)
//            {
//                *(pU++) = pUV[i<<1];
//                *(pV++) = pUV[(i<<1) + 1];
//            }
//            pUV+=bytesrow1;
//        }
//        //add code to push yuv420_data to video encoder here
//        data.pData = (AInt8*)yuv420_data;
//        data.width = width;
//        data.height = height;
//        data.videoFormat = CAM_FORMAT_YUV420;
//
//        ret = aInputCameraData(CAMA_ID_TOP, &data);
//        free(yuv420_data);
//        /* unlock the buffer*/
//        CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
//    }
//
//
//}
#pragma mark Convert SampleBuffer to UIImage
// Works only if pixel format is kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
- (UIImage *)convertSampleBufferToUIImageSampleBuffer:(CMSampleBufferRef)sampleBuffer{
    
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the plane pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    
    // Get the number of bytes per row for the plane pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,0);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent gray color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGImageAlphaNone);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
    
}
- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections {
    NSLog(@"start moive record");
    dispatch_async(_sessionQueue, ^{
        [_session notifyMovieFileOutputIsReady];
        self.movieRecordAsset = [RecodrAsset MR_createEntityInContext:[NSManagedObjectContext MR_rootSavingContext]];
        self.movieRecordAsset.filePath   = fileURL.lastPathComponent;
        self.movieRecordAsset.createDate = [NSDate date];
        
        
        if (!_isRecording) {
            [self pause:_pauseCompletionHandler];
        }
    });
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error {
    //    _isRecording = NO;
    
    dispatch_async(_sessionQueue, ^{
        BOOL hasComplete = NO;
        NSError *actualError = error;
        if ([actualError.localizedDescription isEqualToString:@"Recording Stopped"]) {
            actualError = nil;
            hasComplete = YES;
        }
        [MagicalRecord saveWithBlock:^(NSManagedObjectContext * _Nonnull localContext) {
            
            self.movieRecordAsset.duration = [FileManager getAssetDurationOfItemAtPath:outputFileURL.relativePath];
            if ([FileManager getAssetDurationNumberOfItemAtPath:outputFileURL.relativePath] >= kRecordInterval) {
                self.movieRecordAsset.finished = @(YES);
            }
            NSNumber * fileSize = [FileManager sizeOfItemAtPath:outputFileURL.relativePath];
            
            NSLog(@"fileSize is %@",fileSize);
            
            self.movieRecordAsset.videoSize = fileSize;
        }];
        
        [_session appendRecordSegmentUrl:outputFileURL info:[self _createSegmentInfo] error:actualError completionHandler:^(SCRecordSessionSegment *segment, NSError *error) {
            
            if (error.code == -11810) {
                [self record];
            }
            
            //            void (^pauseCompletionHandler)() = _pauseCompletionHandler;
            //            _pauseCompletionHandler = nil;
            //
            //            SCRecordSession *recordSession = _session;
            //
            //            if (recordSession != nil) {
            //                id<SCRecorderDelegate> delegate = self.delegate;
            //                if ([delegate respondsToSelector:@selector(recorder:didCompleteSegment:inSession:error:)]) {
            //                    [delegate recorder:self didCompleteSegment:segment inSession:recordSession error:error];
            //                }
            //
            //                if (hasComplete || (CMTIME_IS_VALID(_maxRecordDuration) && CMTIME_COMPARE_INLINE(recordSession.duration, >=, _maxRecordDuration))) {
            //                    if ([delegate respondsToSelector:@selector(recorder:didCompleteSession:)]) {
            //                        [delegate recorder:self didCompleteSession:recordSession];
            //                    }
            //                }
            //            }
            //
            //            if (pauseCompletionHandler != nil) {
            //                pauseCompletionHandler();
            //            }
        }];
        
        
    });
}

- (void)_handleVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer withSession:(SCRecordSession *)recordSession connection:(AVCaptureConnection *)connection {
    if (!recordSession.videoInitializationFailed && !_videoConfiguration.shouldIgnore) {
        if (!recordSession.videoInitialized) {
            
            NSError *error = nil;
            NSDictionary *settings = [self.videoConfiguration createAssetWriterOptionsUsingSampleBuffer:sampleBuffer];
            
            CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
            [recordSession initializeVideo:settings formatDescription:formatDescription error:&error];
            NSLog(@"INITIALIZED VIDEO");
            
            id<SCRecorderDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(recorder:didInitializeVideoInSession:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate recorder:self didInitializeVideoInSession:recordSession error:error];
                });
            }
        }
        //        else{
        //            _glkView.showSam(sampleBuffer);
        //        }
        
        if (!self.audioEnabledAndReady || recordSession.audioInitialized || recordSession.audioInitializationFailed) {
            [self beginRecordSegmentIfNeeded:recordSession];
            
            ////            /**
            ////             *  这一段是新加的为了加日期标签 start 2016/7/22 15:33 linmeng
            ////             */
            //            if (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0)
            //            {
            //                return;
            //            }
            //
            //            CFRetain(sampleBuffer);
            //            runAsynchronouslyOnVideoProcessingQueue(^{
            //
            //                [self processVideoSampleBuffer:sampleBuffer];
            //
            //                CFRelease(sampleBuffer);
            //                dispatch_semaphore_signal(frameRenderingSemaphore);
            //            });
            ////            /**
            ////             *  这一段是新加的为了加日期标签 end
            ////             */
            
            if (_isRecording && recordSession.recordSegmentReady) {
                id<SCRecorderDelegate> delegate = self.delegate;
                CMTime duration = [self frameDurationFromConnection:connection];
                
                double timeToWait = kMinTimeBetweenAppend - (CACurrentMediaTime() - _lastAppendedVideoTime);
                
                if (timeToWait > 0) {
                    // Letting some time to for the AVAssetWriter to be ready
                    //                                    NSLog(@"Too fast! Waiting %fs", timeToWait);
                    [NSThread sleepForTimeInterval:timeToWait];
                }
                BOOL isFirstVideoBuffer = !recordSession.currentSegmentHasVideo;
                NSLog(@"isFirstVideoBuffer is %@",@(isFirstVideoBuffer));
                [self appendVideoSampleBuffer:sampleBuffer toRecordSession:recordSession duration:duration connection:connection completion:^(BOOL success) {
                    _lastAppendedVideoTime = CACurrentMediaTime();
                    if (success) {
                        if ([delegate respondsToSelector:@selector(recorder:didAppendVideoSampleBufferInSession:)]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [delegate recorder:self didAppendVideoSampleBufferInSession:recordSession];
                            });
                        }
                        
                        [self checkRecordSessionDuration:recordSession];
                    } else {
                        if ([delegate respondsToSelector:@selector(recorder:didSkipVideoSampleBufferInSession:)]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [delegate recorder:self didSkipVideoSampleBufferInSession:recordSession];
                            });
                        }
                    }
                }];
                
                if (isFirstVideoBuffer && !recordSession.currentSegmentHasAudio) {
                    CMSampleBufferRef audioBuffer = _lastAudioBuffer.sampleBuffer;
                    if (audioBuffer != nil) {
                        CMTime lastAudioEndTime = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(audioBuffer), CMSampleBufferGetDuration(audioBuffer));
                        CMTime videoStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                        // If the end time of the last audio buffer is after this video buffer, we need to re-use it,
                        // since it was skipped on the last cycle to wait until the video becomes ready.
                        if (CMTIME_COMPARE_INLINE(lastAudioEndTime, >, videoStartTime)) {
                            [self _handleAudioSampleBuffer:audioBuffer withSession:recordSession];
                        }
                    }
                }
            }
        } else {
            //            NSLog(@"SKIPPING");
        }
    }
}

- (void)_handleAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer withSession:(SCRecordSession *)recordSession {
    if (!recordSession.audioInitializationFailed && !_audioConfiguration.shouldIgnore) {
        if (!recordSession.audioInitialized) {
            NSError *error = nil;
            NSDictionary *settings = [self.audioConfiguration createAssetWriterOptionsUsingSampleBuffer:sampleBuffer];
            CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
            [recordSession initializeAudio:settings formatDescription:formatDescription error:&error];
            //            NSLog(@"INITIALIZED AUDIO");
            
            id<SCRecorderDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(recorder:didInitializeAudioInSession:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate recorder:self didInitializeAudioInSession:recordSession error:error];
                });
            }
        }
        
        if (!self.videoEnabledAndReady || recordSession.videoInitialized || recordSession.videoInitializationFailed) {
            
            if (_isRecording && recordSession.recordSegmentReady && (!self.videoEnabledAndReady || recordSession.currentSegmentHasVideo)) {
                id<SCRecorderDelegate> delegate = self.delegate;
                //                NSLog(@"APPENDING");
                
                [recordSession appendAudioSampleBuffer:sampleBuffer completion:^(BOOL success) {
                    if (success) {
                        if ([delegate respondsToSelector:@selector(recorder:didAppendAudioSampleBufferInSession:)]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [delegate recorder:self didAppendAudioSampleBufferInSession:recordSession];
                            });
                        }
                        
                        [self checkRecordSessionDuration:recordSession];
                    } else {
                        if ([delegate respondsToSelector:@selector(recorder:didSkipAudioSampleBufferInSession:)]) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [delegate recorder:self didSkipAudioSampleBufferInSession:recordSession];
                            });
                        }
                    }
                }];
            } else {
                //                NSLog(@"SKIPPING");
            }
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    
//    SampleBufferModel * model1 = [[SampleBufferModel alloc] init];
//    model1.timeInterval = [[NSDate date] timeIntervalSince1970];
//    model1.type = (captureOutput == _videoOutput?0:1);
//    [model1 addSampleBuffer:sampleBuffer];
//    
//    [[EmergencyVideoRecorder sharedEmergencyVideoRecorder] dealWithSampleBuffers:model1];
    
    if (captureOutput == _videoOutput) {
//        _lastVideoBuffer.sampleBuffer = sampleBuffer;
        
        //        NSLog(@"VIDEO BUFFER: %fs (%fs)", CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)), CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer)));
        //            /**
        //             *  这一段是新加的为了加日期标签 start 2016/7/22 15:33 linmeng
        //             */
        if (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0)
        {
            return;
        }
        
        
        
        CFRetain(sampleBuffer);
        runAsynchronouslyOnVideoProcessingQueue(^{
            
            if (self.simplebufferDelegate )
            {
                [self.simplebufferDelegate willOutputSampleBuffer:sampleBuffer];
            }
            
            [self processVideoSampleBuffer:sampleBuffer];
            
            CFRelease(sampleBuffer);
            dispatch_semaphore_signal(frameRenderingSemaphore);
        });
        
        //            /**
        //             *  这一段是新加的为了加日期标签 end
        //             */
        
        
        if (_videoConfiguration.shouldIgnore) {
            return;
        }
        
        SCImageView *imageView = _SCImageView;
        if (imageView != nil) {
            CFRetain(sampleBuffer);
            dispatch_async(dispatch_get_main_queue(), ^{
                [imageView setImageBySampleBuffer:sampleBuffer];
                CFRelease(sampleBuffer);
            });
        }
    } else if (captureOutput == _audioOutput) {
//        _lastAudioBuffer.sampleBuffer = sampleBuffer;
        //        NSLog(@"AUDIO BUFFER: %fs (%fs)", CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)), CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer)));
        
        if (_audioConfiguration.shouldIgnore) {
            return;
        }
    }
    
    if (!_initializeSessionLazily || _isRecording) {
        SCRecordSession *recordSession = _session;
        if (recordSession != nil) {
            if (captureOutput == _videoOutput) {
                [self _handleVideoSampleBuffer:sampleBuffer withSession:recordSession connection:connection];
            } else if (captureOutput == _audioOutput) {
                [self _handleAudioSampleBuffer:sampleBuffer withSession:recordSession];
            }
        }
    }
}

- (NSDictionary *)_createSegmentInfo {
    id<SCRecorderDelegate> delegate = self.delegate;
    NSDictionary *segmentInfo = nil;
    
    if ([delegate respondsToSelector:@selector(createSegmentInfoForRecorder:)]) {
        segmentInfo = [delegate createSegmentInfoForRecorder:self];
    }
    
    return segmentInfo;
}

- (void)_focusDidComplete {
    id<SCRecorderDelegate> delegate = self.delegate;
    
    [self setAdjustingFocus:NO];
    
    if ([delegate respondsToSelector:@selector(recorderDidEndFocus:)]) {
        [delegate recorderDidEndFocus:self];
    }
    
    if (_needsSwitchBackToContinuousFocus) {
        _needsSwitchBackToContinuousFocus = NO;
        [self continuousFocusAtPoint:self.focusPointOfInterest];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    id<SCRecorderDelegate> delegate = self.delegate;
    
    if (context == SCRecorderFocusContext) {
        BOOL isFocusing = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isFocusing) {
            [self setAdjustingFocus:YES];
            
            if ([delegate respondsToSelector:@selector(recorderDidStartFocus:)]) {
                [delegate recorderDidStartFocus:self];
            }
        } else {
            [self _focusDidComplete];
        }
    } else if (context == SCRecorderExposureContext) {
        BOOL isAdjustingExposure = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        
        [self setAdjustingExposure:isAdjustingExposure];
        
        if (isAdjustingExposure) {
            if ([delegate respondsToSelector:@selector(recorderDidStartAdjustingExposure:)]) {
                [delegate recorderDidStartAdjustingExposure:self];
            }
        } else {
            if ([delegate respondsToSelector:@selector(recorderDidEndAdjustingExposure:)]) {
                [delegate recorderDidEndAdjustingExposure:self];
            }
        }
    } else if (context == SCRecorderAudioEnabledContext) {
        if ([NSThread isMainThread]) {
            [self reconfigureVideoInput:NO audioInput:YES];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self reconfigureVideoInput:NO audioInput:YES];
            });
        }
    } else if (context == SCRecorderVideoEnabledContext) {
        if ([NSThread isMainThread]) {
            [self reconfigureVideoInput:YES audioInput:NO];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self reconfigureVideoInput:YES audioInput:NO];
            });
        }
    } else if (context == SCRecorderPhotoOptionsContext) {
        _photoOutput.outputSettings = [_photoConfiguration createOutputSettings];
    }
}

- (void)addVideoObservers:(AVCaptureDevice*)videoDevice {
    [videoDevice addObserver:self forKeyPath:@"adjustingFocus" options:NSKeyValueObservingOptionNew context:SCRecorderFocusContext];
    [videoDevice addObserver:self forKeyPath:@"adjustingExposure" options:NSKeyValueObservingOptionNew context:SCRecorderExposureContext];
}

- (void)removeVideoObservers:(AVCaptureDevice*)videoDevice {
    [videoDevice removeObserver:self forKeyPath:@"adjustingFocus"];
    [videoDevice removeObserver:self forKeyPath:@"adjustingExposure"];
}

- (void)_configureVideoStabilization {
    AVCaptureConnection *videoConnection = [self videoConnection];
    if ([videoConnection isVideoStabilizationSupported]) {
        if ([videoConnection respondsToSelector:@selector(setPreferredVideoStabilizationMode:)]) {
            videoConnection.preferredVideoStabilizationMode = _videoStabilizationMode;
        }
    }
}

- (void)_configureFrontCameraMirroring:(BOOL)videoMirrored {
    AVCaptureConnection *videoConnection = [self videoConnection];
    if ([videoConnection isVideoMirroringSupported]) {
        if ([videoConnection respondsToSelector:@selector(setVideoMirrored:)]) {
            videoConnection.videoMirrored = videoMirrored;
        }
    }
}

- (void)configureDevice:(AVCaptureDevice*)newDevice mediaType:(NSString*)mediaType error:(NSError**)error {
    AVCaptureDeviceInput *currentInput = [self currentDeviceInputForMediaType:mediaType];
    AVCaptureDevice *currentUsedDevice = currentInput.device;
    
    if (currentUsedDevice != newDevice) {
        if ([mediaType isEqualToString:AVMediaTypeVideo]) {
            NSError *error;
            if ([newDevice lockForConfiguration:&error]) {
                if (newDevice.isSmoothAutoFocusSupported) {
                    newDevice.smoothAutoFocusEnabled = YES;
                }
                newDevice.subjectAreaChangeMonitoringEnabled = true;
                
                if (newDevice.isLowLightBoostSupported) {
                    newDevice.automaticallyEnablesLowLightBoostWhenAvailable = YES;
                }
                [newDevice unlockForConfiguration];
            } else {
                NSLog(@"Failed to configure device: %@", error);
            }
            _videoInputAdded = NO;
        } else {
            _audioInputAdded = NO;
        }
        
        AVCaptureDeviceInput *newInput = nil;
        
        if (newDevice != nil) {
            newInput = [[AVCaptureDeviceInput alloc] initWithDevice:newDevice error:error];
        }
        
        if (*error == nil) {
            if (currentInput != nil) {
                [_captureSession removeInput:currentInput];
                if ([currentInput.device hasMediaType:AVMediaTypeVideo]) {
                    [self removeVideoObservers:currentInput.device];
                }
            }
            
            if (newInput != nil) {
                if ([_captureSession canAddInput:newInput]) {
                    [_captureSession addInput:newInput];
                    if ([newInput.device hasMediaType:AVMediaTypeVideo]) {
                        _videoInputAdded = YES;
                        
                        [self addVideoObservers:newInput.device];
                        [self _configureVideoStabilization];
                        [self _configureFrontCameraMirroring:_mirrorOnFrontCamera && newInput.device.position == AVCaptureDevicePositionFront];
                        
                    } else {
                        _audioInputAdded = YES;
                    }
                } else {
                    *error = [SCRecorder createError:@"Failed to add input to capture session"];
                }
            }
        }
    }
}

- (void)reconfigureVideoInput:(BOOL)shouldConfigureVideo audioInput:(BOOL)shouldConfigureAudio {
    if (_captureSession != nil) {
        [self beginConfiguration];
        
        NSError *videoError = nil;
        if (shouldConfigureVideo) {
            [self configureDevice:[self videoDevice] mediaType:AVMediaTypeVideo error:&videoError];
            _transformFilter = nil;
            //            dispatch_sync(_sessionQueue, ^{
            //                [self updateVideoOrientation];
            //            });
        }
        
        NSError *audioError = nil;
        
        if (shouldConfigureAudio) {
            [self configureDevice:[self audioDevice] mediaType:AVMediaTypeAudio error:&audioError];
        }
        
        [self commitConfiguration];
        
        id<SCRecorderDelegate> delegate = self.delegate;
        if (shouldConfigureAudio) {
            if ([delegate respondsToSelector:@selector(recorder:didReconfigureAudioInput:)]) {
                [delegate recorder:self didReconfigureAudioInput:audioError];
            }
        }
        if (shouldConfigureVideo) {
            if ([delegate respondsToSelector:@selector(recorder:didReconfigureVideoInput:)]) {
                [delegate recorder:self didReconfigureVideoInput:videoError];
            }
        }
    }
}

- (void)switchCaptureDevices {
    if (self.device == AVCaptureDevicePositionBack) {
        self.device = AVCaptureDevicePositionFront;
    } else {
        self.device = AVCaptureDevicePositionBack;
    }
}

- (void)previewViewFrameChanged {
    _previewLayer.affineTransform = CGAffineTransformIdentity;
    _previewLayer.frame = _previewView.bounds;
}

#pragma mark - FOCUS

- (CGPoint)convertToPointOfInterestFromViewCoordinates:(CGPoint)viewCoordinates {
    return [self.previewLayer captureDevicePointOfInterestForPoint:viewCoordinates];
}

- (CGPoint)convertPointOfInterestToViewCoordinates:(CGPoint)pointOfInterest {
    return [self.previewLayer pointForCaptureDevicePointOfInterest:pointOfInterest];
}

- (void)mediaServicesWereReset:(NSNotification *)notification {
    NSLog(@"MEDIA SERVICES WERE RESET");
}

- (void)mediaServicesWereLost:(NSNotification *)notification {
    NSLog(@"MEDIA SERVICES WERE LOST");
}

- (void)sessionInterrupted:(NSNotification *)notification {
    NSNumber *interruption = [notification.userInfo objectForKey:AVAudioSessionInterruptionOptionKey];
    
    if (interruption != nil) {
        AVAudioSessionInterruptionOptions options = interruption.unsignedIntValue;
        if (options == AVAudioSessionInterruptionOptionShouldResume) {
            [self reconfigureVideoInput:NO audioInput:self.audioConfiguration.enabled];
        }
    }
}

- (void)lockFocus {
    AVCaptureDevice *device = [self.currentVideoDeviceInput device];
    if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:AVCaptureFocusModeLocked];
            [device unlockForConfiguration];
        }
    }
}

- (void)_applyPointOfInterest:(CGPoint)point continuousMode:(BOOL)continuousMode {
    AVCaptureDevice *device = [self.currentVideoDeviceInput device];
    AVCaptureFocusMode focusMode = continuousMode ? AVCaptureFocusModeContinuousAutoFocus : AVCaptureFocusModeAutoFocus;
    AVCaptureExposureMode exposureMode = continuousMode ? AVCaptureExposureModeContinuousAutoExposure : AVCaptureExposureModeAutoExpose;
    AVCaptureWhiteBalanceMode whiteBalanceMode = continuousMode ? AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance : AVCaptureWhiteBalanceModeAutoWhiteBalance;
    
    NSError *error;
    if ([device lockForConfiguration:&error]) {
        BOOL focusing = NO;
        BOOL adjustingExposure = NO;
        
        if (device.isFocusPointOfInterestSupported) {
            device.focusPointOfInterest = point;
        }
        if ([device isFocusModeSupported:focusMode]) {
            device.focusMode = focusMode;
            focusing = YES;
        }
        
        if (device.isExposurePointOfInterestSupported) {
            device.exposurePointOfInterest = point;
        }
        
        if ([device isExposureModeSupported:exposureMode]) {
            device.exposureMode = exposureMode;
            adjustingExposure = YES;
        }
        
        if ([device isWhiteBalanceModeSupported:whiteBalanceMode]) {
            device.whiteBalanceMode = whiteBalanceMode;
        }
        
        [device unlockForConfiguration];
        
        id<SCRecorderDelegate> delegate = self.delegate;
        if (focusMode != AVCaptureFocusModeContinuousAutoFocus && focusing) {
            if ([delegate respondsToSelector:@selector(recorderWillStartFocus:)]) {
                [delegate recorderWillStartFocus:self];
            }
            
            [self setAdjustingFocus:YES];
        }
        
        if (exposureMode != AVCaptureExposureModeContinuousAutoExposure && adjustingExposure) {
            [self setAdjustingExposure:YES];
            
            if ([delegate respondsToSelector:@selector(recorderWillStartAdjustingExposure:)]) {
                [delegate recorderWillStartAdjustingExposure:self];
            }
        }
    }
}

// Perform an auto focus at the specified point. The focus mode will automatically change to locked once the auto focus is complete.
- (void)autoFocusAtPoint:(CGPoint)point {
    [self _applyPointOfInterest:point continuousMode:NO];
}

// Switch to continuous auto focus mode at the specified point
- (void)continuousFocusAtPoint:(CGPoint)point {
    [self _applyPointOfInterest:point continuousMode:YES];
}

- (void)focusCenter {
    _needsSwitchBackToContinuousFocus = YES;
    [self autoFocusAtPoint:CGPointMake(0.5, 0.5)];
}

- (void)refocus {
    _needsSwitchBackToContinuousFocus = YES;
    [self autoFocusAtPoint:self.focusPointOfInterest];
}

- (CGPoint)exposurePointOfInterest {
    return [self.currentVideoDeviceInput device].exposurePointOfInterest;
}

- (BOOL)exposureSupported {
    return [self.currentVideoDeviceInput device].isExposurePointOfInterestSupported;
}

- (CGPoint)focusPointOfInterest {
    return [self.currentVideoDeviceInput device].focusPointOfInterest;
}

- (BOOL)focusSupported {
    return [self currentVideoDeviceInput].device.isFocusPointOfInterestSupported;
}

- (AVCaptureDeviceInput*)currentAudioDeviceInput {
    return [self currentDeviceInputForMediaType:AVMediaTypeAudio];
}

- (AVCaptureDeviceInput*)currentVideoDeviceInput {
    return [self currentDeviceInputForMediaType:AVMediaTypeVideo];
}

- (AVCaptureDeviceInput*)currentDeviceInputForMediaType:(NSString*)mediaType {
    for (AVCaptureDeviceInput* deviceInput in _captureSession.inputs) {
        if ([deviceInput.device hasMediaType:mediaType]) {
            return deviceInput;
        }
    }
    
    return nil;
}

- (AVCaptureDevice*)audioDevice {
    if (!self.audioConfiguration.enabled) {
        return nil;
    }
    
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
}

- (AVCaptureDevice*)videoDevice {
    if (!self.videoConfiguration.enabled) {
        return nil;
    }
    
    return [SCRecorderTools videoDeviceForPosition:_device];
}

- (AVCaptureVideoOrientation)actualVideoOrientation {
    AVCaptureVideoOrientation videoOrientation = _videoOrientation;
    
    if (_autoSetVideoOrientation) {
        UIDeviceOrientation deviceOrientation = [[UIDevice currentDevice] orientation];
        
        switch (deviceOrientation) {
            case UIDeviceOrientationLandscapeLeft:
                videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                break;
            case UIDeviceOrientationLandscapeRight:
                videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
            case UIDeviceOrientationPortrait:
                videoOrientation = AVCaptureVideoOrientationPortrait;
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;
            default:
                break;
        }
    }
    
    return videoOrientation;
}

- (AVCaptureSession*)captureSession {
    return _captureSession;
}

- (void)setPreviewView:(UIView *)previewView {
    [_previewLayer removeFromSuperlayer];
    
    _previewView = previewView;
    
    if (_previewView != nil) {
        [_previewView.layer insertSublayer:_previewLayer atIndex:0];
        
        [self previewViewFrameChanged];
    }
}

- (UIView*)previewView {
    return _previewView;
}

- (NSDictionary*)photoOutputSettings {
    return _photoOutput.outputSettings;
}

- (void)setPhotoOutputSettings:(NSDictionary *)photoOutputSettings {
    _photoOutput.outputSettings = photoOutputSettings;
}

- (void)setDevice:(AVCaptureDevicePosition)device {
    [self willChangeValueForKey:@"device"];
    
    _device = device;
    if (_resetZoomOnChangeDevice) {
        self.videoZoomFactor = 1;
    }
    if (_captureSession != nil) {
        [self reconfigureVideoInput:self.videoConfiguration.enabled audioInput:NO];
    }
    
    [self didChangeValueForKey:@"device"];
}

- (void)setFlashMode:(SCFlashMode)flashMode {
    AVCaptureDevice *currentDevice = [self videoDevice];
    NSError *error = nil;
    
    if (currentDevice.hasFlash) {
        if ([currentDevice lockForConfiguration:&error]) {
            if (flashMode == SCFlashModeLight) {
                if ([currentDevice isTorchModeSupported:AVCaptureTorchModeOn]) {
                    [currentDevice setTorchMode:AVCaptureTorchModeOn];
                }
                if ([currentDevice isFlashModeSupported:AVCaptureFlashModeOff]) {
                    [currentDevice setFlashMode:AVCaptureFlashModeOff];
                }
            } else {
                if ([currentDevice isTorchModeSupported:AVCaptureTorchModeOff]) {
                    [currentDevice setTorchMode:AVCaptureTorchModeOff];
                }
                if ([currentDevice isFlashModeSupported:(AVCaptureFlashMode)flashMode]) {
                    [currentDevice setFlashMode:(AVCaptureFlashMode)flashMode];
                }
            }
            
            [currentDevice unlockForConfiguration];
        }
    } else {
        error = [SCRecorder createError:@"Current device does not support flash"];
    }
    
    id<SCRecorderDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(recorder:didChangeFlashMode:error:)]) {
        [delegate recorder:self didChangeFlashMode:flashMode error:error];
    }
    
    if (error == nil) {
        _flashMode = flashMode;
    }
}

- (BOOL)deviceHasFlash {
    AVCaptureDevice *currentDevice = [self videoDevice];
    return currentDevice.hasFlash;
}

- (AVCaptureVideoPreviewLayer*)previewLayer {
    return _previewLayer;
}

- (BOOL)isPrepared {
    return _captureSession != nil;
}

- (void)setCaptureSessionPreset:(NSString *)sessionPreset {
    _captureSessionPreset = sessionPreset;
    
    if (_captureSession != nil) {
        [self _reconfigureSession];
        _captureSessionPreset = _captureSession.sessionPreset;
    }
}

- (void)setVideoOrientation:(AVCaptureVideoOrientation)videoOrientation {
    _videoOrientation = videoOrientation;
    [self updateVideoOrientation];
}

- (void)setSession:(SCRecordSession *)recordSession {
    if (_session != recordSession) {
        dispatch_sync(_sessionQueue, ^{
            _session.recorder = nil;
            
            _session = recordSession;
            
            recordSession.recorder = self;
        });
    }
}

- (AVCaptureFocusMode)focusMode {
    return [self currentVideoDeviceInput].device.focusMode;
}

- (BOOL)isAdjustingFocus {
    return _adjustingFocus;
}

- (void)setAdjustingExposure:(BOOL)adjustingExposure {
    if (_isAdjustingExposure != adjustingExposure) {
        [self willChangeValueForKey:@"isAdjustingExposure"];
        
        _isAdjustingExposure = adjustingExposure;
        
        [self didChangeValueForKey:@"isAdjustingExposure"];
    }
}

- (void)setAdjustingFocus:(BOOL)adjustingFocus {
    if (_adjustingFocus != adjustingFocus) {
        [self willChangeValueForKey:@"isAdjustingFocus"];
        
        _adjustingFocus = adjustingFocus;
        
        [self didChangeValueForKey:@"isAdjustingFocus"];
    }
}

- (AVCaptureConnection*)videoConnection {
    for (AVCaptureConnection * connection in _videoOutput.connections) {
        for (AVCaptureInputPort * port in connection.inputPorts) {
            if ([port.mediaType isEqual:AVMediaTypeVideo]) {
                return connection;
            }
        }
    }
    
    return nil;
}

- (CMTimeScale)frameRate {
    AVCaptureDeviceInput * deviceInput = [self currentVideoDeviceInput];
    
    CMTimeScale framerate = 0;
    
    if (deviceInput != nil) {
        if ([deviceInput.device respondsToSelector:@selector(activeVideoMaxFrameDuration)]) {
            framerate = deviceInput.device.activeVideoMaxFrameDuration.timescale;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            AVCaptureConnection *videoConnection = [self videoConnection];
            framerate = videoConnection.videoMaxFrameDuration.timescale;
#pragma clang diagnostic pop
        }
    }
    
    return framerate;
}

- (void)setFrameRate:(CMTimeScale)framePerSeconds {
    CMTime fps = CMTimeMake(1, framePerSeconds);
    
    AVCaptureDevice * device = [self videoDevice];
    
    if (device != nil) {
        NSError * error = nil;
        BOOL formatSupported = [SCRecorderTools formatInRange:device.activeFormat frameRate:framePerSeconds];
        
        if (formatSupported) {
            if ([device respondsToSelector:@selector(activeVideoMinFrameDuration)]) {
                if ([device lockForConfiguration:&error]) {
                    device.activeVideoMaxFrameDuration = fps;
                    device.activeVideoMinFrameDuration = fps;
                    [device unlockForConfiguration];
                } else {
                    NSLog(@"Failed to set FramePerSeconds into camera device: %@", error.description);
                }
            } else {
                AVCaptureConnection *connection = [self videoConnection];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if (connection.isVideoMaxFrameDurationSupported) {
                    connection.videoMaxFrameDuration = fps;
                } else {
                    NSLog(@"Failed to set FrameRate into camera device");
                }
                if (connection.isVideoMinFrameDurationSupported) {
                    connection.videoMinFrameDuration = fps;
                } else {
                    NSLog(@"Failed to set FrameRate into camera device");
                }
#pragma clang diagnostic pop
            }
        } else {
            NSLog(@"Unsupported frame rate %ld on current device format.", (long)framePerSeconds);
        }
    }
}

- (BOOL)setActiveFormatWithFrameRate:(CMTimeScale)frameRate error:(NSError *__autoreleasing *)error {
    return [self setActiveFormatWithFrameRate:frameRate width:self.videoConfiguration.size.width andHeight:self.videoConfiguration.size.height error:error];
}

- (BOOL)setActiveFormatWithFrameRate:(CMTimeScale)frameRate width:(int)width andHeight:(int)height error:(NSError *__autoreleasing *)error {
    AVCaptureDevice *device = [self videoDevice];
    CMVideoDimensions dimensions;
    dimensions.width = width;
    dimensions.height = height;
    
    BOOL foundSupported = NO;
    
    if (device != nil) {
        AVCaptureDeviceFormat *bestFormat = nil;
        
        for (AVCaptureDeviceFormat *format in device.formats) {
            if ([SCRecorderTools formatInRange:format frameRate:frameRate dimensions:dimensions]) {
                if (bestFormat == nil) {
                    bestFormat = format;
                } else {
                    CMVideoDimensions bestDimensions = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
                    CMVideoDimensions currentDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                    
                    if (currentDimensions.width < bestDimensions.width && currentDimensions.height < bestDimensions.height) {
                        bestFormat = format;
                    } else if (currentDimensions.width == bestDimensions.width && currentDimensions.height == bestDimensions.height) {
                        if ([SCRecorderTools maxFrameRateForFormat:bestFormat minFrameRate:frameRate] > [SCRecorderTools maxFrameRateForFormat:format minFrameRate:frameRate]) {
                            bestFormat = format;
                        }
                    }
                }
            }
        }
        
        if (bestFormat != nil) {
            if ([device lockForConfiguration:error]) {
                CMTime frameDuration = CMTimeMake(1, frameRate);
                
                device.activeFormat = bestFormat;
                foundSupported = true;
                
                device.activeVideoMinFrameDuration = frameDuration;
                device.activeVideoMaxFrameDuration = frameDuration;
                
                [device unlockForConfiguration];
            }
        } else {
            if (error != nil) {
                *error = [SCRecorder createError:[NSString stringWithFormat:@"No format that supports framerate %d and dimensions %d/%d was found", (int)frameRate, dimensions.width, dimensions.height]];
            }
        }
    } else {
        if (error != nil) {
            *error = [SCRecorder createError:@"The camera must be initialized before setting active format"];
        }
    }
    
    if (foundSupported && error != nil) {
        *error = nil;
    }
    
    return foundSupported;
}

- (CGFloat)ratioRecorded {
    CGFloat ratio = 0;
    
    if (CMTIME_IS_VALID(_maxRecordDuration)) {
        Float64 maxRecordDuration = CMTimeGetSeconds(_maxRecordDuration);
        Float64 recordedTime = CMTimeGetSeconds(_session.duration);
        
        ratio = (CGFloat)(recordedTime / maxRecordDuration);
    }
    
    return ratio;
}

- (AVCaptureVideoDataOutput *)videoOutput {
    return _videoOutput;
}

- (AVCaptureAudioDataOutput *)audioOutput {
    return _audioOutput;
}

- (AVCaptureStillImageOutput *)photoOutput {
    return _photoOutput;
}

- (BOOL)audioEnabledAndReady {
    return _audioOutputAdded && _audioInputAdded && !_audioConfiguration.shouldIgnore;
}

- (BOOL)videoEnabledAndReady {
    return _videoOutputAdded && _videoInputAdded && !_videoConfiguration.shouldIgnore;
}

- (void)setKeepMirroringOnWrite:(BOOL)keepMirroringOnWrite {
    dispatch_sync(_sessionQueue, ^{
        _keepMirroringOnWrite = keepMirroringOnWrite;
        _transformFilter = nil;
    });
}

- (CGFloat)videoZoomFactor {
    AVCaptureDevice *device = [self videoDevice];
    
    if ([device respondsToSelector:@selector(videoZoomFactor)]) {
        return device.videoZoomFactor;
    }
    
    return 1;
}

- (CGFloat)maxVideoZoomFactor {
    return [self maxVideoZoomFactorForDevice:_device];
}

- (CGFloat)maxVideoZoomFactorForDevice:(AVCaptureDevicePosition)devicePosition
{
    return [SCRecorderTools videoDeviceForPosition:devicePosition].activeFormat.videoMaxZoomFactor;
}

- (void)setVideoZoomFactor:(CGFloat)videoZoomFactor {
    AVCaptureDevice *device = [self videoDevice];
    
    if ([device respondsToSelector:@selector(videoZoomFactor)]) {
        NSError *error;
        if ([device lockForConfiguration:&error]) {
            if (videoZoomFactor <= device.activeFormat.videoMaxZoomFactor) {
                device.videoZoomFactor = videoZoomFactor;
            } else {
                NSLog(@"Unable to set videoZoom: (max %f, asked %f)", device.activeFormat.videoMaxZoomFactor, videoZoomFactor);
            }
            
            [device unlockForConfiguration];
        } else {
            NSLog(@"Unable to set videoZoom: %@", error.localizedDescription);
        }
    }
}

- (void)setFastRecordMethodEnabled:(BOOL)fastRecordMethodEnabled {
    if (_fastRecordMethodEnabled != fastRecordMethodEnabled) {
        _fastRecordMethodEnabled = fastRecordMethodEnabled;
        
        [self _reconfigureSession];
    }
}
- (void)setExposureTargetOffset:(float)bias{
    AVCaptureDevice *device = [self videoDevice];
    NSError *error;
    if ([device lockForConfiguration:&error]) {
        if (bias>device.maxExposureTargetBias) {
            bias = device.maxExposureTargetBias;
        }
        if (bias<device.minExposureTargetBias) {
            bias = device.minExposureTargetBias;
        }//add by why
        [device setExposureTargetBias:bias completionHandler:nil];
        
        [device unlockForConfiguration];
    } else {
        NSLog(@"Unable to set ExposureTargetBias: %@", error.localizedDescription);
    }
    
    
}

- (void)setVideoStabilizationMode:(AVCaptureVideoStabilizationMode)videoStabilizationMode {
    _videoStabilizationMode = videoStabilizationMode;
    [self beginConfiguration];
    [self _configureVideoStabilization];
    [self commitConfiguration];
}

+ (SCRecorder *)sharedRecorder {
    static SCRecorder *_sharedRecorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedRecorder = [SCRecorder new];
    });
    
    return _sharedRecorder;
}

+ (BOOL)isSessionQueue {
    return dispatch_get_specific(kSCRecorderRecordSessionQueueKey) != nil;
}



#pragma mark ----------GPUImage------------
#define INITIALFRAMESTOIGNOREFORBENCHMARK 5
/**
 *  这一段是新加的为了加日期标签 start 2016/7/22 15:33 linmeng
 */

- (void)updateTargetsForVideoCameraUsingCacheTextureAtWidth:(int)bufferWidth height:(int)bufferHeight time:(CMTime)currentTime;
{
    // First, update all the framebuffers in the targets
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:textureIndexOfTarget];
                
                if ([currentTarget wantsMonochromeInput] && captureAsYUV)
                {
                    [currentTarget setCurrentlyReceivingMonochromeInput:YES];
                    // TODO: Replace optimization for monochrome output
                    [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
                }
                else
                {
                    [currentTarget setCurrentlyReceivingMonochromeInput:NO];
                    [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
                }
            }
            else
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
            }
        }
    }
    
    // Then release our hold on the local framebuffer to send it back to the cache as soon as it's no longer needed
    [outputFramebuffer unlock];
    outputFramebuffer = nil;
    
    // Finally, trigger rendering as needed
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget newFrameReadyAtTime:currentTime atIndex:textureIndexOfTarget];
            }
        }
    }
}

- (CVImageBufferRef)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    
    
    //    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    CVImageBufferRef cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
    int bufferWidth = (int) CVPixelBufferGetWidth(cameraFrame);
    int bufferHeight = (int) CVPixelBufferGetHeight(cameraFrame);
    CFTypeRef colorAttachments = CVBufferGetAttachment(cameraFrame, kCVImageBufferYCbCrMatrixKey, NULL);
    if (colorAttachments != NULL)
    {
        if(CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
        {
            if (isFullYUVRange)
            {
                _preferredConversion = kColorConversion601FullRange;
            }
            else
            {
                _preferredConversion = kColorConversion601;
            }
        }
        else
        {
            _preferredConversion = kColorConversion709;
        }
    }
    else
    {
        if (isFullYUVRange)
        {
            _preferredConversion = kColorConversion601FullRange;
        }
        else
        {
            _preferredConversion = kColorConversion601;
        }
    }
    
    CMTime currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    [GPUImageContext useImageProcessingContext];
    
    if ([GPUImageContext supportsFastTextureUpload] && captureAsYUV)
    {
        CVOpenGLESTextureRef luminanceTextureRef  = NULL;
        CVOpenGLESTextureRef chrominanceTextureRef = NULL;
        
        //        if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures])
        if (CVPixelBufferGetPlaneCount(cameraFrame) > 0) // Check for YUV planar inputs to do RGB conversion
        {
            CVPixelBufferLockBaseAddress(cameraFrame, 0);
            
            if ( (imageBufferWidth != bufferWidth) && (imageBufferHeight != bufferHeight) )
            {
                imageBufferWidth = bufferWidth;
                imageBufferHeight = bufferHeight;
            }
            
            CVReturn err;
            // Y-plane
            glActiveTexture(GL_TEXTURE4);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
                //                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, cameraFrame, NULL, GL_TEXTURE_2D, GL_RED_EXT, bufferWidth, bufferHeight, GL_RED_EXT, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE, bufferWidth, bufferHeight, GL_LUMINANCE, GL_UNSIGNED_BYTE, 0, &luminanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            luminanceTexture = CVOpenGLESTextureGetName(luminanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, luminanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            // UV-plane
            glActiveTexture(GL_TEXTURE5);
            if ([GPUImageContext deviceSupportsRedTextures])
            {
                //                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, coreVideoTextureCache, cameraFrame, NULL, GL_TEXTURE_2D, GL_RG_EXT, bufferWidth/2, bufferHeight/2, GL_RG_EXT, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            else
            {
                err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_LUMINANCE_ALPHA, bufferWidth/2, bufferHeight/2, GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, 1, &chrominanceTextureRef);
            }
            if (err)
            {
                NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
            }
            
            chrominanceTexture = CVOpenGLESTextureGetName(chrominanceTextureRef);
            glBindTexture(GL_TEXTURE_2D, chrominanceTexture);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            
            //            if (!allTargetsWantMonochromeData)
            //            {
            [self convertYUVToRGBOutput];
            //            }
            
            int rotatedImageBufferWidth = bufferWidth, rotatedImageBufferHeight = bufferHeight;
            
            if (GPUImageRotationSwapsWidthAndHeight(internalRotation))
            {
                rotatedImageBufferWidth = bufferHeight;
                rotatedImageBufferHeight = bufferWidth;
            }
            
            [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:rotatedImageBufferWidth height:rotatedImageBufferHeight time:currentTime];
            
            CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
            //            [self releaseTexturesWithLimit:3 andNewTexture:luminanceTextureRef];
            //            [self releaseTexturesWithLimit:3 andNewTexture:chrominanceTextureRef];
            CFRelease(luminanceTextureRef);
            CFRelease(chrominanceTextureRef);
            
        }
        else
        {
            // TODO: Mesh this with the output framebuffer structure
            
            //            CVPixelBufferLockBaseAddress(cameraFrame, 0);
            //
            //            CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, [[GPUImageContext sharedImageProcessingContext] coreVideoTextureCache], cameraFrame, NULL, GL_TEXTURE_2D, GL_RGBA, bufferWidth, bufferHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
            //
            //            if (!texture || err) {
            //                NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
            //                NSAssert(NO, @"Camera failure");
            //                return;
            //            }
            //
            //            outputTexture = CVOpenGLESTextureGetName(texture);
            //            //        glBindTexture(CVOpenGLESTextureGetTarget(texture), outputTexture);
            //            glBindTexture(GL_TEXTURE_2D, outputTexture);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            //            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            //
            //            [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:bufferWidth height:bufferHeight time:currentTime];
            //
            //            CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
            //            CFRelease(texture);
            //
            //            outputTexture = 0;
        }
        
        
        //        if (_runBenchmark)
        //        {
        //            numberOfFramesCaptured++;
        //            if (numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK)
        //            {
        //                CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        //                totalFrameTimeDuringCapture += currentFrameTime;
        //                NSLog(@"Average frame time : %f ms", [self averageFrameDurationDuringCapture]);
        //                NSLog(@"Current frame time : %f ms", 1000.0 * currentFrameTime);
        //            }
        //        }
        return cameraFrame;
        
    }
    else
    {
        CVPixelBufferLockBaseAddress(cameraFrame, 0);
        
        int bytesPerRow = (int) CVPixelBufferGetBytesPerRow(cameraFrame);
        outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(bytesPerRow / 4, bufferHeight) onlyTexture:YES];
        [outputFramebuffer activateFramebuffer];
        
        glBindTexture(GL_TEXTURE_2D, [outputFramebuffer texture]);
        
        //        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bufferWidth, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        // Using BGRA extension to pull in video frame data directly
        // The use of bytesPerRow / 4 accounts for a display glitch present in preview video frames when using the photo preset on the camera
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bytesPerRow / 4, bufferHeight, 0, GL_BGRA, GL_UNSIGNED_BYTE, CVPixelBufferGetBaseAddress(cameraFrame));
        
        [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:bytesPerRow / 4 height:bufferHeight time:currentTime];
        
        CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
        return cameraFrame;
        
        
        //        if (_runBenchmark)
        //        {
        //            numberOfFramesCaptured++;
        //            if (numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK)
        //            {
        //                CFAbsoluteTime currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime);
        //                totalFrameTimeDuringCapture += currentFrameTime;
        //            }
        //        }
//        return cameraFrame;
        
    }
}
- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
{
    [self.audioEncodingTarget processAudioBuffer:sampleBuffer];
}

- (void)convertYUVToRGBOutput;
{
    [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
    
    int rotatedImageBufferWidth = imageBufferWidth, rotatedImageBufferHeight = imageBufferHeight;
    
    if (GPUImageRotationSwapsWidthAndHeight(internalRotation))
    {
        rotatedImageBufferWidth = imageBufferHeight;
        rotatedImageBufferHeight = imageBufferWidth;
    }
    
    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:CGSizeMake(rotatedImageBufferWidth, rotatedImageBufferHeight) textureOptions:self.outputTextureOptions onlyTexture:NO];
    [outputFramebuffer activateFramebuffer];
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, luminanceTexture);
    glUniform1i(yuvConversionLuminanceTextureUniform, 4);
    
    glActiveTexture(GL_TEXTURE5);
    glBindTexture(GL_TEXTURE_2D, chrominanceTexture);
    glUniform1i(yuvConversionChrominanceTextureUniform, 5);
    
    glUniformMatrix3fv(yuvConversionMatrixUniform, 1, GL_FALSE, _preferredConversion);
    
    glVertexAttribPointer(yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, [GPUImageFilter textureCoordinatesForRotation:internalRotation]);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

#pragma mark -
#pragma mark Benchmarking

- (CGFloat)averageFrameDurationDuringCapture;
{
    return (totalFrameTimeDuringCapture / (CGFloat)(numberOfFramesCaptured - INITIALFRAMESTOIGNOREFORBENCHMARK)) * 1000.0;
}

- (void)resetBenchmarkAverage;
{
    numberOfFramesCaptured = 0;
    totalFrameTimeDuringCapture = 0.0;
}
#pragma mark -
#pragma mark Managing targets

- (void)addTarget:(id<GPUImageInput>)newTarget atTextureLocation:(NSInteger)textureLocation;
{
    [super addTarget:newTarget atTextureLocation:textureLocation];
    
    [newTarget setInputRotation:outputRotation atIndex:textureLocation];
}
-(void)releaseTexturesWithLimit:(int)limit andNewTexture:(CVOpenGLESTextureRef)texture{
    
    [textureArray addObject:(__bridge id _Nonnull)(texture)];
    while ([textureArray count]>limit) {
        CVOpenGLESTextureRef releaseTexture = (__bridge CVOpenGLESTextureRef)(textureArray[0]);
        [textureArray removeObjectAtIndex:0];
        CFRelease(releaseTexture);
    }
}

#pragma mark -----------------------dateWatermark--------------------
- (UIImage *)imageFromString:(NSString *)string attributes:(NSDictionary *)attributes{
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(dateWatermarkWidth, dateWatermarkHeight), NO, 0);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    CGContextSetFillColorWithColor(context, [kColorWhite CGColor]);
    CGContextFillRect(context, CGRectMake(0, 0, dateWatermarkWidth, dateWatermarkHeight));
    [string drawInRect:CGRectMake(0, 0, dateWatermarkWidth, dateWatermarkHeight) withAttributes:attributes];
    
    //    CGContextSetTextDrawingMode(context, kCGTextFillStrokeClip);
    
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
    
    
    
}
- (uint8_t *)convertARGBToNV12:(UIImage *)image{
    int yIndex = 0;
    int uvIndex = dateWatermarkWidth * dateWatermarkHeight;
    //int vIndex = frameSize + frameSize/4;
    int R, G, B, Y, U, V;
    
    int tt = 0;
    UInt8 *yuv420f = (UInt8 *)malloc(dateWatermarkWidth * dateWatermarkHeight *3/ 2);
    
    GLubyte *imageData ;
    
    imageData = [self convertUIImageToBuffer:image];
    
    
    for (int j = 0; j < dateWatermarkHeight; j++) {
        for (int i = 0; i < dateWatermarkWidth; i++) {
            R = imageData[tt++];
            G = imageData[tt++];
            B = imageData[tt++];
            
            tt++;
            
            if (R < 0) {
                R = R + 256;
            }
            
            if (G < 0) {
                G = G + 256;
            }
            if (B < 0) {
                B = B + 256;
            }
            Y = ((66 * R + 129 * G + 25 * B + 128) >> 8) + 16;
            //            Y = 115;
            // NV21 has a plane of Y and interleaved planes of VU each
            // sampled by a factor of 2
            // meaning for every 4 Y pixels there are 1 V and 1 U. Note the
            // sampling is every other
            // pixel AND every other scanline.
            
            yuv420f[yIndex++] =  ((Y < 0) ? 0: ((Y > 255) ? 255 : Y));
            if (((j % 2) == 0) && ((i % 2) == 0)) {
                U = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
                V = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
                
                yuv420f[uvIndex++] = ((V < 0) ? 0: ((V > 255) ? 255 : V));
                yuv420f[uvIndex++] = ((U < 0) ? 0: ((U > 255) ? 255 : U));
                
            }
        }
    }
    return yuv420f;
}

- (CVPixelBufferRef)progressDateWatermarkPixelBuffer:(CVPixelBufferRef)oriPixelBuffer{
    
    CVPixelBufferLockBaseAddress(oriPixelBuffer, 0);
    
    UInt8 *bufferbasePtr     = (UInt8 *)CVPixelBufferGetBaseAddress(oriPixelBuffer);
    UInt8 *bufferPtr         = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(oriPixelBuffer,0);
    UInt8 *bufferPtr1        = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(oriPixelBuffer,1);
    size_t buffeSize         = CVPixelBufferGetDataSize(oriPixelBuffer);
    size_t width             = CVPixelBufferGetWidth(oriPixelBuffer);
    size_t height            = CVPixelBufferGetHeight(oriPixelBuffer);
    size_t bytesPerRow       = CVPixelBufferGetBytesPerRow(oriPixelBuffer);
    size_t bytesrow0         = CVPixelBufferGetBytesPerRowOfPlane(oriPixelBuffer,0);
    size_t bytesrow1         = CVPixelBufferGetBytesPerRowOfPlane(oriPixelBuffer,1);
    
    
    //        size_t bytesrow2 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,2);
    UInt8 *yuv420_data       = (UInt8 *)malloc(width * height *3/ 2);//buffer to store YUV with layout YYYYYYYYUUVV
    
    
    
    UInt8 *pY                = bufferPtr ;
    UInt8 *pUV               = bufferPtr1;
    
    NSString *dateString = GetCurrentTimeString();
    UIFontDescriptor *attributeFontDescriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:
                                                 @{UIFontDescriptorFamilyAttribute: @"Marion",
                                                   UIFontDescriptorNameAttribute:@"Marion-Regular",
                                                   UIFontDescriptorSizeAttribute: @18.0,
                                                   }];
    NSDictionary *attributes = @{
                                 NSFontAttributeName :[UIFont fontWithDescriptor:attributeFontDescriptor size:18],
                                 NSForegroundColorAttributeName: [UIColor yellowColor],
                                 NSBackgroundColorAttributeName: [UIColor whiteColor],
                                 
                                 
                                 };
    UIImage *image = [self imageFromString:dateString attributes:attributes];
    
    for (int i=0; i<height; i++) {
        memcpy(yuv420_data+i*width,pY+i*bytesrow0,width);
    }
    for (int i = 0; i <height/2; i++) {
        memcpy(yuv420_data+width*height+i*width, pUV + i*bytesrow1, width);
    }
    
    UInt8 *date   = [self convertARGBToNV12:image];
    
    
    int posX = width/4 *3;
    int posY = height/5 *4;
    
    int blendMaxHeight = (dateWatermarkHeight + posY > height) ? (height - posY) : dateWatermarkHeight;
    int blendMaxWidth = (dateWatermarkWidth + posX > width) ? (width - posX) : dateWatermarkWidth;
    
    
    
    
    int uvTargetAddr = width * height;
    int uvSrcAddr = blendMaxWidth * blendMaxHeight;
    
    
    for (int i = 0; i < blendMaxHeight; i++) {
        for(int j = 0; j < blendMaxWidth; j++){
            if(date[i * blendMaxWidth + j] != 235){
                yuv420_data[(posY + i) * width + posX + j] = date[i * blendMaxWidth + j];
                
            }else{
                //                NSLog(@"Y is %@",@(date[i * blendMaxWidth + j]));
                
            }
        }
    }
    
    for (int i = 0; i < blendMaxHeight/2; i++) {
        for(int j = 0; j < blendMaxWidth; j++){
            if(date[uvSrcAddr + i * blendMaxWidth + j] != 128){
                yuv420_data[uvTargetAddr + (posY/2 + i) * width + posX + j] = date[uvSrcAddr + i * blendMaxWidth + j];
            }else{
                
            }
        }
    }
    
    
    
    
    //    for(int i                = 0;i<height;i++)
    //    {
    //        for (int j=0; j<width; j++) {
    //            memcpy(yuv420_data+i*width +j,pY+i*bytesrow0+j,1);
    //            if (i *width + j < dateWatermarkWidth *dateWatermarkHeight) {
    //                memcpy(yuv420_data +i*width+j, date+i*width+j, 1);
    //            }
    //            memcpy(yuv420_data +i*width+j, pY+i*width+j, 1);
    //        }
    //
    //    }
    //    for (int i               = 0; i <height/2; i++) {
    //        for (int j = 0; j<width; j++) {
    //            if (i*width +j < dateWatermarkWidth *dateWatermarkHeight /2) {
    //                memcpy(yuv420_data+width*height+i*width+j, date+dateWatermarkWidth * dateWatermarkHeight +i*width+j, 1);
    //            }
    //            memcpy(yuv420_data+width*height+i*width+j, pUV+width * height +i*width+j, 1);
    //
    //        }
    //
    //    }
    //
    //    if (!self.testData1) {
    //        self.testData1 = [NSMutableData data];
    //        [self.testData1 appendBytes:date length:blendMaxHeight * blendMaxWidth *3/ 2];
    //        [self.testData1 writeToFile:[[FileManager pathForDocumentsDirectory] stringByAppendingPathComponent:@"testDate7after"] atomically:YES];
    //
    //    }
    
    CVPixelBufferRef pxbuffer = [self copyDataFrameBuffer:yuv420_data toYUVPixelBufferWithWidth:width height:height];
    
    
    
    
    free(yuv420_data);
    free(date);
    /* unlock the buffer*/
    CVPixelBufferUnlockBaseAddress(oriPixelBuffer, 0);
    
    return pxbuffer;
    
    
}
- (CVPixelBufferRef) copyDataFrameBuffer:(const unsigned char *)buffer toYUVPixelBufferWithWidth:(size_t)width height:(size_t)height{
    
    NSDictionary *pixelBufferAttributes = [NSDictionary dictionaryWithObjectsAndKeys: nil];
    CVPixelBufferRef pixelBuffer;
    CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, (__bridge CFDictionaryRef _Nullable)(pixelBufferAttributes), &pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    size_t d = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const unsigned char *src = buffer;
    
    unsigned char * dst = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    
    for (unsigned int rIdx = 0; rIdx <height; ++rIdx,dst += d,src +=width) {
        memcpy(dst, src, width);
    }
    d = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    
    dst = (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    height = height >> 1;
    
    for (unsigned int rIdx = 0; rIdx < height; ++rIdx, dst += d, src +=width) {
        memcpy(dst, src, width);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
    
    
    
    
    
}
- (GLubyte *)convertUIImageToBuffer:(UIImage *)image{
    
    GLubyte *imageData =NULL;
    CFDataRef dataFromImageDataProvider = CGDataProviderCopyData(CGImageGetDataProvider(image.CGImage));
    
    imageData = (GLubyte *)CFDataGetBytePtr(dataFromImageDataProvider);
    CFRelease(dataFromImageDataProvider);
    
    return imageData;
    
    
    
}


@end
