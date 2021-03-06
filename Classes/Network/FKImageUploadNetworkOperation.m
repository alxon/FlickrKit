//
//  FKImageUploadNetworkOperation.m
//  FlickrKit
//
//  Created by David Casserly on 06/06/2013.
//  Copyright (c) 2013 DevedUp Ltd. All rights reserved. http://www.devedup.com
//

#import "FKImageUploadNetworkOperation.h"
#import "FlickrKit.h"
#import "FKURLBuilder.h"
#import "FKUtilities.h"
#import "FKUploadRespone.h"
#import "FKDUStreamUtil.h"
#import <MobileCoreServices/MobileCoreServices.h>

@interface FKImageUploadNetworkOperation ()

@property (nonatomic, strong) DUImage *image;
@property (nonatomic, retain) NSString *tempFile;
@property (nonatomic, copy) FKAPIImageUploadCompletion completion;
@property (nonatomic, retain) NSDictionary *args;
@property (nonatomic, assign) CGFloat uploadProgress;
@property (nonatomic, assign) NSUInteger fileSize;
#if TARGET_OS_IOS
@property (nonatomic, assign) NSURL* assetURL;
#endif
@property (nonatomic, strong) NSURL *fileURL;
@end

@implementation FKImageUploadNetworkOperation

- (id) initWithImage:(DUImage *)image arguments:(NSDictionary *)args completion:(FKAPIImageUploadCompletion)completion; {
    self = [super init];
    if (self) {
		self.image = image;
		self.args = args;
		self.completion = completion;
    }
    return self;
}

#if TARGET_OS_IOS
- (id) initWithAssetURL:(NSURL *)assetURL arguments:(NSDictionary *)args completion:(FKAPIImageUploadCompletion)completion; {
    self = [super init];
    if (self) {
		self.image = nil;
        self.assetURL = assetURL;
		self.args = args;
		self.completion = completion;
    }
    return self;
}
#endif

- (id) initWithFileURL:(NSURL *)fileURL arguments:(NSDictionary *)args completion:(FKAPIImageUploadCompletion)completion {
    self = [super init];
    if (self) {
        self.image = nil;
        self.fileURL = fileURL;
        self.args = args;
        self.completion = completion;
    }
    return self;
}


#pragma mark - DUOperation methods

- (void) cancel {
	self.completion = nil;
	[self cleanupTempFile:self.tempFile];
	[super cancel];
}

- (void) finish {
	self.completion = nil;
	[self cleanupTempFile:self.tempFile];
	[super finish];
}

#pragma mark - Create the request

- (void) cleanupTempFile:(NSString *)uploadTempFilename {
    if (uploadTempFilename) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:uploadTempFilename]) {
			BOOL __unused removeResult = NO;
			NSError *error = nil;
			removeResult = [fileManager removeItemAtPath:uploadTempFilename error:&error];
			NSAssert(removeResult, @"Should be able to remove temp file");
        }        
        uploadTempFilename = nil;
    }
}

- (NSMutableURLRequest *) createRequest:(NSError **)error {
	// Setup args
	NSMutableDictionary *newArgs = self.args ? [NSMutableDictionary dictionaryWithDictionary:self.args] : [NSMutableDictionary dictionary];
	newArgs[@"format"] = @"json";

//#ifdef DEBUG
//    [newArgs setObject:@"0" forKey:@"is_public"];
//    [newArgs setObject:@"0" forKey:@"is_friend"];
//    [newArgs setObject:@"0" forKey:@"is_family"];
//    [newArgs setObject:@"2" forKey:@"hidden"];
//#endif
    
    // Build a URL to the upload service
	FKURLBuilder *urlBuilder = [[FKURLBuilder alloc] init];
	NSDictionary *args = [urlBuilder signedArgsFromParameters:newArgs method:FKHttpMethodPOST url:[NSURL URLWithString:@"https://api.flickr.com/services/upload/"]];
	
	// Form multipart needs a boundary 
	NSString *multipartBoundary = FKGenerateUUID();
	
    NSString *inFilename = nil;
   
    NSInputStream *inInputStream = nil;
   	// Input stream is the image
    if (self.image) {
        NSData *jpegData = [FKImageUploadNetworkOperation jpegSerialzation:self.image];
        inInputStream = [[NSInputStream alloc] initWithData:jpegData];
        inFilename = [self.args valueForKey:@"title"];
    // Input stream is the asset
    } else if( self.assetURL ) {
        inFilename = [self.args valueForKey:@"title"];
    // Input stream is the file
    } else if (self.fileURL) {
        inInputStream = [[NSInputStream alloc] initWithURL:self.fileURL];
        inFilename = [self.fileURL lastPathComponent];
    }
    
    // Attempt to determine the MIME type from the path extension
    NSString *pathExtension = [inFilename pathExtension];
    NSString *mimeType = nil;
    if (pathExtension) {
        CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef) pathExtension, NULL);
        mimeType = (__bridge NSString *) UTTypeCopyPreferredTagWithClass (UTI, kUTTagClassMIMEType);
        CFRelease(UTI);
    }
    if (nil == mimeType)
        mimeType = @"image/jpeg";
    
	// File name
	if (!inFilename) {
        inFilename = @" "; // Leave space so that the below still uploads a file
    } else {
        inFilename = [inFilename stringByReplacingOccurrencesOfString:@" " withString:@""];
    }
    
    // The multipart opening string
	NSMutableString *multipartOpeningString = [NSMutableString string];
	for (NSString *key in args.allKeys) {
		[multipartOpeningString appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", multipartBoundary, key, [args valueForKey:key]];
	}
    [multipartOpeningString appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"%@\"\r\n", multipartBoundary, inFilename];
    [multipartOpeningString appendFormat:@"Content-Type: %@\r\n\r\n", mimeType];
	
	// The multipart closing string
	NSMutableString *multipartClosingString = [NSMutableString string];
	[multipartClosingString appendFormat:@"\r\n--%@--", multipartBoundary];
    
	// The temp file to write this multipart to
	NSString *tempFileName = [NSTemporaryDirectory() stringByAppendingFormat:@"%@.%@", @"FKFlickrTempFile", FKGenerateUUID()];
	self.tempFile = tempFileName;	
	
	// Output stream is the file... 
    NSOutputStream *outputStream = [NSOutputStream outputStreamToFileAtPath:tempFileName append:NO];
    [outputStream open];
    
    if( self.image || self.fileURL) {
        // Write the contents to the streams... don't cross the streams !
        [FKDUStreamUtil writeMultipartStartString:multipartOpeningString imageStream:inInputStream toOutputStream:outputStream closingString:multipartClosingString];
    }
#if TARGET_OS_IOS
    else if( self.assetURL ){
        [FKDUStreamUtil writeMultipartWithAssetURL:self.assetURL
                                       startString:multipartOpeningString
                                         imageFile:tempFileName
                                    toOutputStream:outputStream
                                     closingString:multipartClosingString];
    }
#endif
    else{
        return nil;
    }

	// Get the file size
    NSDictionary *fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:tempFileName error:error];
    NSNumber *fileSize = nil;
    if (fileInfo) {
        fileSize = [fileInfo objectForKey:NSFileSize];
        self.fileSize = [fileSize integerValue];
    } else {
        //we have the error populated
        return nil;
    }	

    // Now the input stream for the request is the file just created
	NSInputStream *inputStream = [NSInputStream inputStreamWithFileAtPath:tempFileName];	
	
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:@"https://api.flickr.com/services/upload/"]];
	[request setHTTPMethod:@"POST"];
	[request setHTTPBodyStream:inputStream];
	NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", multipartBoundary];
	[request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    [request setValue:[fileSize stringValue] forHTTPHeaderField:@"Content-Length"];
    
    return request;
}

#pragma mark - NSURLConnection Delegate methods

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	if (self.completion) {
		self.completion(nil, error);
	}
    [self finish];
}

- (void) connectionDidFinishLoading:(NSURLConnection *)connection {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		
		FKUploadRespone *response = [[FKUploadRespone alloc] initWithData:self.receivedData];
		BOOL success = [response parse];
		
		if (!success) {
			NSString *errorString = @"Cannot parse response data from image upload";
			NSString *dataString = [[NSString alloc] initWithData:self.receivedData encoding:NSUTF8StringEncoding];
			NSDictionary *userInfo = @{NSLocalizedDescriptionKey: errorString, @"Response": dataString};
			NSError *error = [NSError errorWithDomain:FKFlickrKitErrorDomain code:FKErrorResponseParsing userInfo:userInfo];
			if (self.completion) {
				self.completion(nil, error);
			}
		} else {
			if (self.completion) {
				self.completion(response.photoID, response.error);
			}
		}
		[self finish];
		
	});
}

- (void) connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
	
    // Calculate the progress
    self.uploadProgress = (CGFloat) totalBytesWritten / (CGFloat) self.fileSize;
    
#ifdef DEBUG
    NSLog(@"file size is %lu", (unsigned long)self.fileSize);
	NSLog(@"Sent %li, total Sent %li, expected total %li", (long)bytesWritten, (long)totalBytesWritten, (long)totalBytesExpectedToWrite);
    NSLog(@"Upload progress is %f", self.uploadProgress);
#endif
}

#pragma mark - ImageSerialization

#if TARGET_OS_IPHONE
+(NSData*)jpegSerialzation:(DUImage *)image{
    return UIImageJPEGRepresentation(image, 1.0);
}
#else
+(NSData*)jpegSerialzation:(DUImage *)image{
    NSData *imageData = [image TIFFRepresentation];
    NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:imageData];
    NSNumber *compressionFactor = [NSNumber numberWithFloat:1.0];
    NSDictionary *imageProps = [NSDictionary dictionaryWithObject:compressionFactor
                                                           forKey:NSImageCompressionFactor];
    return [imageRep representationUsingType:NSJPEGFileType properties:imageProps];
}
#endif
@end



