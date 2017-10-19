//
//  SCSession.m
//  SCAudioVideoRecorder
//
//  Created by Simon CORSIN on 27/03/14.
//  Copyright (c) 2014 rFlex. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SCRecordSession_Internal.h"
#import "SCRecorder.h"
#import "RecordAssetManager.h"
#import "FileManager.h"
#import <CoreVideo/CoreVideo.h>

#pragma mark - Private definition

NSString * const SCRecordSessionSegmentFilenamesKey = @"RecordSegmentFilenames";
NSString * const SCRecordSessionSegmentsKey = @"Segments";
NSString * const SCRecordSessionSegmentFilenameKey = @"Filename";
NSString * const SCRecordSessionSegmentInfoKey = @"Info";

NSString * const SCRecordSessionDurationKey = @"Duration";
NSString * const SCRecordSessionIdentifierKey = @"Identifier";
NSString * const SCRecordSessionDateKey = @"Date";
NSString * const SCRecordSessionDirectoryKey = @"Directory";

NSString * const SCRecordSessionTemporaryDirectory = @"TemporaryDirectory";
NSString * const SCRecordSessionCacheDirectory = @"CacheDirectory";
NSString * const SCRecordSessionDocumentDirectory = @"DocumentDirectory";



@implementation SCRecordSession

- (id)initWithDictionaryRepresentation:(NSDictionary *)dictionaryRepresentation {
    self = [self init];
    
    if (self) {
        NSString *directory = dictionaryRepresentation[SCRecordSessionDirectoryKey];
        if (directory != nil) {
            _segmentsDirectory = directory;
        }
        
        NSArray *recordSegments = [dictionaryRepresentation objectForKey:SCRecordSessionSegmentFilenamesKey];
        
        BOOL shouldRecomputeDuration = NO;
        
        // OLD WAY
        for (NSObject *recordSegment in recordSegments) {
            NSString *filename = nil;
            NSDictionary *info = nil;
            if ([recordSegment isKindOfClass:[NSDictionary class]]) {
                filename = ((NSDictionary *)recordSegment)[SCRecordSessionSegmentFilenameKey];
                info = ((NSDictionary *)recordSegment)[SCRecordSessionSegmentInfoKey];
            } else if ([recordSegment isKindOfClass:[NSString class]]) {
                // EVEN OLDER WAY
                filename = (NSString *)recordSegment;
            }
            
            NSURL *url = [SCRecordSessionSegment segmentURLForFilename:filename andDirectory:_segmentsDirectory];
            
            if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                [_segments addObject:[SCRecordSessionSegment segmentWithURL:url info:info]];
            } else {
                NSLog(@"Skipping record segment %@: File does not exist", url);
                shouldRecomputeDuration = YES;
            }
        }
        
        // NEW WAY
        NSArray *segments = [dictionaryRepresentation objectForKey:SCRecordSessionSegmentsKey];
        for (NSDictionary *segmentDictRepresentation in segments) {
            SCRecordSessionSegment *segment = [[SCRecordSessionSegment alloc] initWithDictionaryRepresentation:segmentDictRepresentation directory:_segmentsDirectory];
            
            if (segment.fileUrlExists) {
                [_segments addObject:segment];
            } else {
                NSLog(@"Skipping record segment %@: File does not exist", segment.url);
                shouldRecomputeDuration = YES;
            }
        }
        
        
        _currentSegmentCount = (int)_segments.count;
        
        NSNumber *recordDuration = [dictionaryRepresentation objectForKey:SCRecordSessionDurationKey];
        if (recordDuration != nil) {
            _segmentsDuration = CMTimeMakeWithSeconds(recordDuration.doubleValue, 10000);
        } else {
            shouldRecomputeDuration = YES;
        }
        
        if (shouldRecomputeDuration) {
            _segmentsDuration = self.assetRepresentingSegments.duration;
            
            if (CMTIME_IS_INVALID(_segmentsDuration)) {
                NSLog(@"Unable to set the segments duration: one or most input assets are invalid");
                NSLog(@"The imported SCRecordSession is probably not useable.");
            }
        }
        
        _identifier = [dictionaryRepresentation objectForKey:SCRecordSessionIdentifierKey];
        _date = [dictionaryRepresentation objectForKey:SCRecordSessionDateKey];
    }
    
    return self;
}

- (id)init {
    self = [super init];
    
    if (self) {
        _segments = [[NSMutableArray alloc] init];
        
        _assetWriter = nil;
        _videoInput = nil;
        _audioInput = nil;
        _audioInitializationFailed = NO;
        _videoInitializationFailed = NO;
        _videoInitialized          = NO;
        _currentSegmentCount = 0;
        _timeOffset = kCMTimeZero;
        _lastTimeAudio = kCMTimeZero;
        _currentSegmentDuration = kCMTimeZero;
        _segmentsDuration = kCMTimeZero;
        _date = [NSDate date];
        _segmentsDirectory = SCRecordSessionDocumentDirectory;
        _identifier = [NSString stringWithFormat:@"%@-", [SCRecordSession newIdentifier:12]];
        _audioQueue = dispatch_queue_create("me.corsin.SCRecorder.Audio", nil);
        
    }
    
    return self;
}


+ (NSString *)newIdentifier:(NSUInteger)length {
    //    static NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    static NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    
    NSMutableString *randomString = [NSMutableString stringWithCapacity:length];
    
    //    for (int i = 0; i < length; i++) {
    //        [randomString appendFormat: @"%C", [letters characterAtIndex: arc4random_uniform((u_int32_t)[letters length])]];
    //    }
    
    return randomString;
}
+ ( instancetype)shareRecordSession{
    static SCRecordSession *_sharedRecorderSeesion = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedRecorderSeesion = [SCRecordSession recordSession];
    });
    
    return _sharedRecorderSeesion;
}
+ (id)recordSession {
    return [[SCRecordSession alloc] init];
}

+ (id)recordSession:(NSDictionary *)dictionaryRepresentation {
    return [[SCRecordSession alloc] initWithDictionaryRepresentation:dictionaryRepresentation];
}

+ (NSError*)createError:(NSString*)errorDescription {
    return [NSError errorWithDomain:@"SCRecordSession" code:200 userInfo:@{NSLocalizedDescriptionKey : errorDescription}];
}

- (void)dispatchSyncOnSessionQueue:(void(^)())block {
    SCRecorder *recorder = self.recorder;
    
    if (recorder == nil || [SCRecorder isSessionQueue]) {
        block();
    } else {
        dispatch_sync(recorder.sessionQueue, block);
    }
}

- (void)removeFile:(NSURL *)fileUrl {
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:fileUrl.path error:&error];
}

- (void)removeSegment:(SCRecordSessionSegment *)segment {
    [self dispatchSyncOnSessionQueue:^{
        NSUInteger index = [_segments indexOfObject:segment];
        if (index != NSNotFound) {
            [self removeSegmentAtIndex:index deleteFile:NO];
        }
    }];
}

- (void)removeSegmentAtIndex:(NSInteger)segmentIndex deleteFile:(BOOL)deleteFile {
    [self dispatchSyncOnSessionQueue:^{
        SCRecordSessionSegment *segment = [_segments objectAtIndex:segmentIndex];
        [_segments removeObjectAtIndex:segmentIndex];
        
        CMTime segmentDuration = segment.duration;
        
        if (CMTIME_IS_VALID(segmentDuration)) {
            //            NSLog(@"Removed duration of %fs", CMTimeGetSeconds(segmentDuration));
            _segmentsDuration = CMTimeSubtract(_segmentsDuration, segmentDuration);
        } else {
            CMTime newDuration = kCMTimeZero;
            for (SCRecordSessionSegment *segment in _segments) {
                if (CMTIME_IS_VALID(segment.duration)) {
                    newDuration = CMTimeAdd(newDuration, segment.duration);
                }
            }
            _segmentsDuration = newDuration;
        }
        
        if (deleteFile) {
            [segment deleteFile];
        }
    }];
}

- (void)removeLastSegment {
    [self dispatchSyncOnSessionQueue:^{
        if (_segments.count > 0) {
            [self removeSegmentAtIndex:_segments.count - 1 deleteFile:YES];
        }
    }];
}

- (void)removeAllSegments {
    [self removeAllSegments:YES];
}

- (void)removeAllSegments:(BOOL)removeFiles {
    [self dispatchSyncOnSessionQueue:^{
        while (_segments.count > 0) {
            if (removeFiles) {
                SCRecordSessionSegment *segment = [_segments objectAtIndex:0];
                [segment deleteFile];
            }
            [_segments removeObjectAtIndex:0];
        }
        
        _segmentsDuration = kCMTimeZero;
    }];
}

- (NSString*)_suggestedFileType {
    NSString *fileType = self.fileType;
    
    if (fileType == nil) {
        SCRecorder *recorder = self.recorder;
        if (recorder.videoEnabledAndReady) {
            fileType = AVFileTypeMPEG4;
        } else if (recorder.audioEnabledAndReady) {
            fileType = AVFileTypeAppleM4A;
        }
    }
    
    return fileType;
}

- (NSString *)_suggestedFileExtension {
    NSString *extension = self.fileExtension;
    
    if (extension != nil) {
        return extension;
    }
    
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType == nil) {
        return nil;
    }
    
    if ([fileType isEqualToString:AVFileTypeMPEG4]) {
        return @"mp4";
    } else if ([fileType isEqualToString:AVFileTypeAppleM4A]) {
        return @"m4a";
    } else if ([fileType isEqualToString:AVFileTypeAppleM4V]) {
        return @"m4v";
    } else if ([fileType isEqualToString:AVFileTypeQuickTimeMovie]) {
        return @"mov";
    } else if ([fileType isEqualToString:AVFileTypeWAVE]) {
        return @"wav";
    } else if ([fileType isEqualToString:AVFileTypeMPEGLayer3]) {
        return @"mp3";
    }
    
    return nil;
}

- (NSURL *)nextFileURL:(NSError **)error {
    NSString *extension = [self _suggestedFileExtension];
    
    if (extension != nil) {
        NSString *filename = [NSString stringWithFormat:@"Video_%@.%@", GetCurrentTimeString(), extension];
        
        NSURL *file = [SCRecordSessionSegment segmentURLForFilename:filename andDirectory:self.segmentsDirectory];
        
        [self removeFile:file];
        
        _currentSegmentCount++;
        
        return file;
        
    } else {
        if (error != nil) {
            *error = [SCRecordSession createError:[NSString stringWithFormat:@"Unable to find an extension"]];
        }
        
        return nil;
    }
}

- (AVAssetWriter *)createWriter:(NSError **)error {
    NSError *theError = nil;
    AVAssetWriter *writer = nil;
    
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType != nil) {
        NSURL *file = [self nextFileURL:&theError];
        
        if (file != nil) {
            writer = [[AVAssetWriter alloc] initWithURL:file fileType:fileType error:&theError];
            writer.metadata = [SCRecorderTools assetWriterMetadata];
            writer.movieFragmentInterval = CMTimeMake(60, 30);
            
            self.currentRecodrAssert = [[RecordAssetManager shareInstances] createRecordAsssetWithFileName:file.lastPathComponent];
            
            
        }
    } else {
        theError = [SCRecordSession createError:@"No fileType has been set in the SCRecordSession"];
    }
    
    if (theError == nil) {
        writer.shouldOptimizeForNetworkUse = YES;
        
        if (_videoInput != nil) {
            if ([writer canAddInput:_videoInput]) {
                [writer addInput:_videoInput];
            } else {
                theError = [SCRecordSession createError:@"Cannot add videoInput to the assetWriter with the currently applied settings"];
            }
        }
        
        if (_audioInput != nil) {
            if ([writer canAddInput:_audioInput]) {
                [writer addInput:_audioInput];
            } else {
                theError = [SCRecordSession createError:@"Cannot add audioInput to the assetWriter with the currently applied settings"];
            }
        }
        
        if ([writer startWriting]) {
            //                NSLog(@"Starting session at %fs", CMTimeGetSeconds(_lastTime));
            _timeOffset = kCMTimeZero;
            _sessionStartTime = kCMTimeInvalid;
            //                _sessionStartedTime = _lastTime;
            //                _currentRecordDurationWithoutCurrentSegment = _currentRecordDuration;
            _recordSegmentReady = YES;
        } else {
            theError = writer.error;
            writer = nil;
        }
    }
    
    if (error != nil) {
        *error = theError;
    }
    
    return writer;
}

- (void)deinitialize {
    [self dispatchSyncOnSessionQueue:^{
        [self endSegmentWithInfo:nil completionHandler:nil];
        
        _audioConfiguration = nil;
        _videoConfiguration = nil;
        _audioInitializationFailed = NO;
        _videoInitializationFailed = NO;
        _videoInitialized          = NO;
        _videoInput = nil;
        _audioInput = nil;
        _videoPixelBufferAdaptor = nil;
    }];
}

- (void)initializeVideo:(NSDictionary *)videoSettings formatDescription:(CMFormatDescriptionRef)formatDescription error:(NSError *__autoreleasing *)error {
    NSError *theError = nil;
    @try {
        _videoConfiguration = self.recorder.videoConfiguration;
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings sourceFormatHint:formatDescription];
        _videoInput.expectsMediaDataInRealTime = YES;
        
        //        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        NSString *resolution =[RecordConfiguration shareInstances].resolution;
        CGSize videoSize = ConvertResolution(resolution);
        int32_t width ,height;
        //        width = dimensions.width;
        //        height = dimensions.height;
        width =videoSize.width;
        height = videoSize.height;
        
        NSDictionary *pixelBufferAttributes = @{
                                                (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInt:kCVPixelFormatType_32BGRA],
                                                (id)kCVPixelBufferWidthKey : [NSNumber numberWithInt:width],
                                                (id)kCVPixelBufferHeightKey : [NSNumber numberWithInt:height]
                                                };
        
        _videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput sourcePixelBufferAttributes:pixelBufferAttributes];
    } @catch (NSException *exception) {
        theError = [SCRecordSession createError:exception.reason];
    }
    
    _videoInitializationFailed = theError != nil;
    self.videoInitialized = _videoInput != nil;
    if (error != nil) {
        *error = theError;
    }
}

- (void)initializeAudio:(NSDictionary *)audioSettings formatDescription:(CMFormatDescriptionRef)formatDescription error:(NSError *__autoreleasing *)error {
    NSError *theError = nil;
    @try {
        _audioConfiguration = self.recorder.audioConfiguration;
        _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings sourceFormatHint:formatDescription];
        _audioInput.expectsMediaDataInRealTime = YES;
    } @catch (NSException *exception) {
        theError = [SCRecordSession createError:exception.reason];
    }
    
    _audioInitializationFailed = theError != nil;
    
    if (error != nil) {
        *error = theError;
    }
}

- (void)addSegment:(SCRecordSessionSegment *)segment {
    [self dispatchSyncOnSessionQueue:^{
        [_segments addObject:segment];
        _segmentsDuration = CMTimeAdd(_segmentsDuration, segment.duration);
    }];
}

- (void)insertSegment:(SCRecordSessionSegment *)segment atIndex:(NSInteger)segmentIndex {
    [self dispatchSyncOnSessionQueue:^{
        [_segments insertObject:segment atIndex:segmentIndex];
        _segmentsDuration = CMTimeAdd(_segmentsDuration, segment.duration);
    }];
}

//
// The following function is from http://www.gdcl.co.uk/2013/02/20/iPhone-Pause.html
//
- (CMSampleBufferRef)adjustBuffer:(CMSampleBufferRef)sample withTimeOffset:(CMTime)offset andDuration:(CMTime)duration {
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    
    for (CMItemCount i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
        pInfo[i].duration = duration;
    }
    
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    return sout;
}

- (void)beginSegment:(NSError**)error {
    [self dispatchSyncOnSessionQueue:^{
        if (_assetWriter == nil) {
            _assetWriter = [self createWriter:error];
            
            _currentSegmentDuration = kCMTimeZero;
            _currentSegmentHasAudio = NO;
            _currentSegmentHasVideo = NO;
        } else {
            if (error != nil) {
                *error = [SCRecordSession createError:@"A record segment has already began."];
            }
        }
    }];
}

- (void)_destroyAssetWriter {
    _currentSegmentHasAudio = NO;
    _currentSegmentHasVideo = NO;
    _assetWriter = nil;
    _lastTimeAudio = kCMTimeInvalid;
    _lastTimeVideo = kCMTimeInvalid;
    _currentSegmentDuration = kCMTimeZero;
    _sessionStartTime = kCMTimeInvalid;
    _segmentsDuration = kCMTimeZero;
    
    _movieFileOutput = nil;
}

- (void)appendRecordSegmentUrl:(NSURL *)url info:(NSDictionary *)info error:(NSError *)error completionHandler:(void (^)(SCRecordSessionSegment *, NSError *))completionHandler {
    [self dispatchSyncOnSessionQueue:^{
        SCRecordSessionSegment *segment = nil;
        
        if (error == nil) {
            segment = [SCRecordSessionSegment segmentWithURL:url info:info];
            [self addSegment:segment];
        }
        /**
         *  测试 直接用视频录入好用不用 此errorCode 是录制内容已经达到最大视频时长
         */
        if (error.code == -11810) {
            segment = [SCRecordSessionSegment segmentWithURL:url info:info];
            [self addSegment:segment];
        }
        
        [self _destroyAssetWriter];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler != nil) {
                completionHandler(segment, error);
            }
        });
    }];
}

- (BOOL)endSegmentWithInfo:(NSDictionary *)info completionHandler:(void(^)(SCRecordSessionSegment *segment, NSError* error))completionHandler {
    __block BOOL success = NO;
    
    [self dispatchSyncOnSessionQueue:^{
        dispatch_sync(_audioQueue, ^{
            if (_recordSegmentReady) {
                _recordSegmentReady = NO;
                success = YES;
                
                AVAssetWriter *writer = _assetWriter;
                
                if (writer != nil) {
                    BOOL currentSegmentEmpty = (!_currentSegmentHasVideo && !_currentSegmentHasAudio);
                    
                    if (currentSegmentEmpty) {
                        [writer cancelWriting];
                        [self _destroyAssetWriter];
                        
                        [self removeFile:writer.outputURL];
                        
                        if (completionHandler != nil) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                completionHandler(nil, nil);
                            });
                        }
                    } else {
                        NSLog(@"Ending session at %fs", CMTimeGetSeconds(_currentSegmentDuration));
                        /**
                         *  修正 程序直接崩溃 或者退出 时 writer finishWritingWithCompletion 执行不玩 导致的 影片打不开
                         http://stackoverflow.com/questions/14765875/avassetwriter-finishwritingwithcompletionhandler-error-with-unknown-error/14805654
                         */
                        [_videoInput markAsFinished];
                        [writer endSessionAtSourceTime:CMTimeAdd(_currentSegmentDuration, _sessionStartTime)];
                        
                        [writer finishWritingWithCompletionHandler: ^{
                            
                            [[RecordAssetManager shareInstances] finishRecordAssetWithFileName:self.currentRecodrAssert];
                            //限定存储空间大小，因为要存入的文件是AVAssetWriter压缩过的，无法预估，存入后超限再删除。
                            BOOL suc  = [FileManager deleteUnlockedOldestVideoFileAtFileContentSizeAt:VIDEO_FILE_LIMIT_SIZE];
                            // test
                            //                            BOOL suc  = [FileManager deleteUnlockedOldestVideoFileAtFileContentSizeAt:100];
                            if (!suc) {
                                UIAlertController * alert = [UIAlertController alertControllerWithTitle:@"停止录制视频" message:@"存储空间已达上限，请清理已锁定视频。" preferredStyle:UIAlertControllerStyleAlert];
                                UIAlertAction * act = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                                    
                                }];
                                [alert addAction:act];
                                //下面root上弹出警告方法暂未测试。
                                [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
                                //暂时添加这一个stop，不够再加别的。
                                [[SCRecorder sharedRecorder] pause];
                                return ;
                            }
                            //                            [MagicalRecord saveWithBlockAndWait:^(NSManagedObjectContext * _Nonnull localContext) {
                            //                                self.currentRecodrAssert.duration = [FileManager getAssetDurationOfItemAtPath:writer.outputURL.relativePath];
                            //
                            //                                self.currentRecodrAssert.finished = @(YES);
                            //
                            //                                NSNumber * fileSize = [FileManager sizeOfItemAtPath:writer.outputURL.relativePath];
                            //
                            //                                NSLog(@"fileSize is %@",fileSize);
                            //
                            //                                self.currentRecodrAssert.videoSize = fileSize;
                            //
                            //                            }];
                            
                            [self appendRecordSegmentUrl:writer.outputURL info:info error:writer.error completionHandler:completionHandler];
                            
                            [self beginSegment:nil];
                        }];
                        
                        
                        
                    }
                } else {
                    [_movieFileOutput stopRecording];
                }
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completionHandler != nil) {
                        completionHandler(nil, [SCRecordSession createError:@"The current record segment is not ready for this operation"]);
                    }
                });
            }
        });
    }];
    
    return success;
}

- (void)notifyMovieFileOutputIsReady {
    _recordSegmentReady = YES;
}

- (void)beginRecordSegmentUsingMovieFileOutput:(AVCaptureMovieFileOutput *)movieFileOutput error:(NSError *__autoreleasing *)error delegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    NSURL *url = [self nextFileURL:error];
    
    if (url != nil) {
        _movieFileOutput = movieFileOutput;
        _movieFileOutput.metadata = [SCRecorderTools assetWriterMetadata];
        
        if (movieFileOutput.isRecording) {
            [NSException raise:@"AlreadyRecordingException" format:@"The MovieFileOutput is already recording"];
        }
        
        _recordSegmentReady = NO;
        [movieFileOutput startRecordingToOutputFileURL:url recordingDelegate:delegate];
    }
}

- (AVAssetExportSession *)mergeSegmentsUsingPreset:(NSString *)exportSessionPreset completionHandler:(void(^)(NSURL *outputUrl, NSError *error))completionHandler {
    __block AVAsset *asset = nil;
    __block NSError *error = nil;
    __block NSString *fileType = nil;
    __block NSURL *outputUrl = nil;
    
    [self dispatchSyncOnSessionQueue:^{
        fileType = [self _suggestedFileType];
        
        if (fileType == nil) {
            error = [SCRecordSession createError:@"No output fileType was set"];
            return;
        }
        
        NSString *fileExtension = [self _suggestedFileExtension];
        if (fileExtension == nil) {
            error = [SCRecordSession createError:@"Unable to figure out a file extension"];
            return;
        }
        
        NSString *filename = [NSString stringWithFormat:@"%@SCVideo-Merged.%@", _identifier, fileExtension];
        outputUrl = [SCRecordSessionSegment segmentURLForFilename:filename andDirectory:_segmentsDirectory];
        [self removeFile:outputUrl];
        
        if (_segments.count == 0) {
            error = [SCRecordSession createError:@"The session does not contains any record segment"];
        } else {
            asset = [self assetRepresentingSegments];
        }
    }];
    
    if (error != nil) {
        if (completionHandler != nil) {
            completionHandler(nil, error);
        }
        
        return nil;
    } else {
        AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:asset presetName:exportSessionPreset];
        exportSession.outputURL = outputUrl;
        exportSession.outputFileType = fileType;
        exportSession.shouldOptimizeForNetworkUse = YES;
        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            NSError *error = exportSession.error;
            
            if (completionHandler != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(outputUrl, error);
                });
            }
        }];
        
        return exportSession;
        
    }
}

- (void)finishEndSession:(NSError*)mergeError completionHandler:(void (^)(NSError *))completionHandler {
    if (mergeError == nil) {
        [self removeAllSegments];
        if (completionHandler != nil) {
            completionHandler(nil);
        }
    } else {
        if (completionHandler != nil) {
            completionHandler(mergeError);
        }
    }
}

- (void)cancelSession:(void (^)())completionHandler {
    [self dispatchSyncOnSessionQueue:^{
        if (_assetWriter == nil) {
            [self removeAllSegments];
            if (completionHandler != nil) {
                completionHandler();
            }
        } else {
            [self endSegmentWithInfo:nil completionHandler:^(SCRecordSessionSegment *segment, NSError *error) {
                [self removeAllSegments];
                if (completionHandler != nil) {
                    completionHandler();
                }
            }];
        }
    }];
}

- (CVPixelBufferRef)createPixelBuffer {
    CVPixelBufferRef outputPixelBuffer = nil;
    CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(NULL, [_videoPixelBufferAdaptor pixelBufferPool], &outputPixelBuffer);
    
    if (ret != kCVReturnSuccess) {
        NSLog(@"UNABLE TO CREATE PIXEL BUFFER (CVReturnError: %d)", ret);
    }
    
    return outputPixelBuffer;
}

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)audioSampleBuffer completion:(void (^)(BOOL))completion {
    //    [self _startSessionIfNeededAtTime:CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer)];
    
    CMTime duration = CMSampleBufferGetDuration(audioSampleBuffer);
    CMSampleBufferRef adjustedBuffer = [self adjustBuffer:audioSampleBuffer withTimeOffset:_timeOffset andDuration:duration];
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer);
    CMTime lastTimeAudio = CMTimeAdd(presentationTime, duration);
    
    dispatch_async(_audioQueue, ^{
        if ([_audioInput isReadyForMoreMediaData] && [_audioInput appendSampleBuffer:adjustedBuffer]) {
            _lastTimeAudio = lastTimeAudio;
            
            if (!_currentSegmentHasVideo) {
                _currentSegmentDuration = CMTimeSubtract(lastTimeAudio, _sessionStartTime);
            }
            
            //            NSLog(@"Appending audio at %fs (buffer: %fs)", CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)), CMTimeGetSeconds(actualBufferTime));
            _currentSegmentHasAudio = YES;
            
            completion(YES);
        } else {
            completion(NO);
        }
        
        CFRelease(adjustedBuffer);
    });
}

- (void)_startSessionIfNeededAtTime:(CMTime)time
{
    if (CMTIME_IS_INVALID(_sessionStartTime)) {
        _sessionStartTime = time;
        [_assetWriter startSessionAtSourceTime:time];
    }
}
- (void)appendVideoPixelBuffer:(CVPixelBufferRef)videoPixelBuffer atTime:(CMTime)actualBufferTime duration:(CMTime)duration completion:(void (^)(BOOL))completion {
    [self _startSessionIfNeededAtTime:actualBufferTime];
    
    CMTime bufferTimestamp = CMTimeSubtract(actualBufferTime, _timeOffset);
    
    CGFloat videoTimeScale = _videoConfiguration.timeScale;
    if (videoTimeScale != 1.0) {
        CMTime computedFrameDuration = CMTimeMultiplyByFloat64(duration, videoTimeScale);
        if (_currentSegmentDuration.value > 0) {
            _timeOffset = CMTimeAdd(_timeOffset, CMTimeSubtract(duration, computedFrameDuration));
        }
        duration = computedFrameDuration;
    }
    
    
    //    CMTime timeVideo = _lastTimeVideo;
    //    CMTime actualBufferDuration = duration;
    //
    //    if (CMTIME_IS_VALID(timeVideo)) {
    //        while (CMTIME_COMPARE_INLINE(CMTimeSubtract(actualBufferTime, timeVideo), >=, CMTimeMultiply(actualBufferDuration, 2))) {
    //            NSLog(@"Missing buffer");
    //            timeVideo = CMTimeAdd(timeVideo, actualBufferDuration);
    //        }
    //    }
    if ([_videoInput isReadyForMoreMediaData]) {
        if ([_videoPixelBufferAdaptor appendPixelBuffer:videoPixelBuffer withPresentationTime:bufferTimestamp]) {
            _currentSegmentDuration = CMTimeSubtract(CMTimeAdd(bufferTimestamp, duration), _sessionStartTime);
            _lastTimeVideo = actualBufferTime;
            
            _currentSegmentHasVideo = YES;
            completion(YES);
            
        } else {
            NSLog(@"Failed to append buffer");
            completion(NO);
        }
    } else {
        completion(NO);
    }
}

- (CMTime)_appendTrack:(AVAssetTrack *)track toCompositionTrack:(AVMutableCompositionTrack *)compositionTrack atTime:(CMTime)time withBounds:(CMTime)bounds {
    CMTimeRange timeRange = track.timeRange;
    time = CMTimeAdd(time, timeRange.start);
    
    if (CMTIME_IS_VALID(bounds)) {
        CMTime currentBounds = CMTimeAdd(time, timeRange.duration);
        
        if (CMTIME_COMPARE_INLINE(currentBounds, >, bounds)) {
            timeRange = CMTimeRangeMake(timeRange.start, CMTimeSubtract(timeRange.duration, CMTimeSubtract(currentBounds, bounds)));
        }
    }
    
    if (CMTIME_COMPARE_INLINE(timeRange.duration, >, kCMTimeZero)) {
        NSError *error = nil;
        [compositionTrack insertTimeRange:timeRange ofTrack:track atTime:time error:&error];
        
        if (error != nil) {
            NSLog(@"Failed to insert append %@ track: %@", compositionTrack.mediaType, error);
        } else {
            //        NSLog(@"Inserted %@ at %fs (%fs -> %fs)", track.mediaType, CMTimeGetSeconds(time), CMTimeGetSeconds(timeRange.start), CMTimeGetSeconds(timeRange.duration));
        }
        
        return CMTimeAdd(time, timeRange.duration);
    }
    
    return time;
}

- (void)appendSegmentsToComposition:(AVMutableComposition * __nonnull)composition {
    [self appendSegmentsToComposition:composition audioMix:nil];
}

- (void)appendSegmentsToComposition:(AVMutableComposition *)composition audioMix:(AVMutableAudioMix *)audioMix {
    [self dispatchSyncOnSessionQueue:^{
        AVMutableCompositionTrack *audioTrack = nil;
        AVMutableCompositionTrack *videoTrack = nil;
        
        int currentSegment = 0;
        CMTime currentTime = composition.duration;
        for (SCRecordSessionSegment *recordSegment in _segments) {
            AVAsset *asset = recordSegment.asset;
            
            NSArray *audioAssetTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            NSArray *videoAssetTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            
            CMTime maxBounds = kCMTimeInvalid;
            
            CMTime videoTime = currentTime;
            for (AVAssetTrack *videoAssetTrack in videoAssetTracks) {
                if (videoTrack == nil) {
                    NSArray *videoTracks = [composition tracksWithMediaType:AVMediaTypeVideo];
                    
                    if (videoTracks.count > 0) {
                        videoTrack = [videoTracks firstObject];
                    } else {
                        videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
                        videoTrack.preferredTransform = videoAssetTrack.preferredTransform;
                    }
                }
                
                videoTime = [self _appendTrack:videoAssetTrack toCompositionTrack:videoTrack atTime:videoTime withBounds:maxBounds];
                maxBounds = videoTime;
            }
            
            CMTime audioTime = currentTime;
            for (AVAssetTrack *audioAssetTrack in audioAssetTracks) {
                if (audioTrack == nil) {
                    NSArray *audioTracks = [composition tracksWithMediaType:AVMediaTypeAudio];
                    
                    if (audioTracks.count > 0) {
                        audioTrack = [audioTracks firstObject];
                    } else {
                        audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                    }
                }
                
                audioTime = [self _appendTrack:audioAssetTrack toCompositionTrack:audioTrack atTime:audioTime withBounds:maxBounds];
            }
            
            currentTime = composition.duration;
            
            currentSegment++;
        }
    }];
}

- (AVPlayerItem *)playerItemRepresentingSegments {
    __block AVPlayerItem *playerItem = nil;
    [self dispatchSyncOnSessionQueue:^{
        if (_segments.count == 1) {
            SCRecordSessionSegment *segment = _segments.firstObject;
            playerItem = [AVPlayerItem playerItemWithAsset:segment.asset];
        } else {
            AVMutableComposition *composition = [AVMutableComposition composition];
            [self appendSegmentsToComposition:composition];
            
            playerItem = [AVPlayerItem playerItemWithAsset:composition];
        }
    }];
    
    return playerItem;
}

- (AVAsset *)assetRepresentingSegments {
    __block AVAsset *asset = nil;
    [self dispatchSyncOnSessionQueue:^{
        if (_segments.count == 1) {
            SCRecordSessionSegment *segment = _segments.firstObject;
            asset = segment.asset;
        } else {
            AVMutableComposition *composition = [AVMutableComposition composition];
            [self appendSegmentsToComposition:composition];
            
            asset = composition;
        }
    }];
    
    return asset;
}

//- (BOOL)videoInitialized {
//    return _videoInput != nil;
//}

- (BOOL)audioInitialized {
    return _audioInput != nil;
}

- (BOOL)recordSegmentBegan {
    return _assetWriter != nil || _movieFileOutput != nil;
}

- (BOOL)recordSegmentReady {
    return _recordSegmentReady;
}

- (BOOL)currentSegmentHasVideo {
    return _currentSegmentHasVideo;
}

- (BOOL)currentSegmentHasAudio {
    return _currentSegmentHasAudio;
}

- (CMTime)currentSegmentDuration {
    return _movieFileOutput.isRecording ? _movieFileOutput.recordedDuration : _currentSegmentDuration;
}

- (CMTime)duration {
    return CMTimeAdd(_segmentsDuration, [self currentSegmentDuration]);
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *recordSegments = [NSMutableArray array];
    
    for (SCRecordSessionSegment *recordSegment in self.segments) {
        [recordSegments addObject:recordSegment.dictionaryRepresentation];
    }
    
    return @{
             SCRecordSessionSegmentsKey: recordSegments,
             SCRecordSessionDurationKey : [NSNumber numberWithDouble:CMTimeGetSeconds(_segmentsDuration)],
             SCRecordSessionIdentifierKey : _identifier,
             SCRecordSessionDateKey : _date,
             SCRecordSessionDirectoryKey : _segmentsDirectory
             };
}

- (NSURL *)outputUrl {
    NSString *fileType = [self _suggestedFileType];
    
    if (fileType == nil) {
        return nil;
    }
    
    NSString *fileExtension = [self _suggestedFileExtension];
    if (fileExtension == nil) {
        return nil;
    }
    
    NSString *filename = [NSString stringWithFormat:@"Video_%@.%@", GetCurrentTimeString(), fileExtension];
    
    return [SCRecordSessionSegment segmentURLForFilename:filename andDirectory:self.segmentsDirectory];
}

- (void)setSegmentsDirectory:(NSString *)segmentsDirectory {
    _segmentsDirectory = [segmentsDirectory copy];
    
    [self dispatchSyncOnSessionQueue:^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (SCRecordSessionSegment *recordSegment in self.segments) {
            NSURL *newUrl = [SCRecordSessionSegment segmentURLForFilename:recordSegment.url.lastPathComponent andDirectory:_segmentsDirectory];
            
            if (![newUrl isEqual:recordSegment.url]) {
                NSError *error = nil;
                if ([fileManager moveItemAtURL:recordSegment.url toURL:newUrl error:&error]) {
                    recordSegment.url = newUrl;
                } else {
                    NSLog(@"Unable to change segmentsDirectory for segment %@: %@", recordSegment.url, error.localizedDescription);
                }
            }
        }
    }];
}

- (BOOL)isUsingMovieFileOutput {
    return _movieFileOutput != nil;
}
- (void)adasAccientHappened{
    
    if (self.currentRecodrAssert) {
        UInt32 currentSegmentDuration = CMTimeGetSeconds(_currentSegmentDuration);
        [[RecordAssetManager shareInstances] lockCurrentRecordAssetWithCurrentSegmentDuration:currentSegmentDuration];
        
    }
    
    
}

@end
