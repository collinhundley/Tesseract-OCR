//
//  G8Tesseract.mm
//  Tesseract OCR iOS
//
//  Created by Loïs Di Qual on 24/09/12.
//  Copyright (c) 2012 Loïs Di Qual.
//  Under MIT License. See 'LICENCE' for more informations.
//

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
#import <UIKit/UIKit.h>
#elif TARGET_OS_MAC
#import <AppKit/AppKit.h>
#endif

#import "G8Tesseract.h"

#import "G8TesseractParameters.h"
#import "G8Constants.h"
#import "G8RecognizedBlock.h"
#import "G8HierarchicalRecognizedBlock.h"

#import "baseapi.h"
#import "environ.h"
#import "pix.h"
#import "ocrclass.h"

#if TARGET_OS_MAC
// FIXME
//
// This is a disgraceful hack - seems to only be required for macOS
// because of some legacy Carbon something or other. Must preceed
// import of allheaders.h
#undef fract1
#endif

#import "allheaders.h"

#import "genericvector.h"
#import "strngs.h"
#import "renderer.h"

// Hack for diffent naming of elsewise simialar classes
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
#define XXImage UIImage
#else
#define XXImage NSImage
#endif

#define ERROR_DEF NSError * __autoreleasing error = nil;

NSInteger const kG8DefaultResolution = 72;
NSInteger const kG8MinCredibleResolution = 70;
NSInteger const kG8MaxCredibleResolution = 2400;

namespace tesseract {
    class TessBaseAPI;
};

@interface G8Tesseract () {
    tesseract::TessBaseAPI *_tesseract;
    ETEXT_DESC *_monitor;
}

@property (nonatomic, assign, readonly) tesseract::TessBaseAPI *tesseract;

@property (nonatomic, strong) NSDictionary *configDictionary;
@property (nonatomic, strong) NSArray *configFileNames;
@property (nonatomic, strong) NSMutableDictionary *variables;

@property (readwrite, assign) CGSize imageSize;

@property (nonatomic, assign, getter=isRecognized) BOOL recognized;
@property (nonatomic, assign, getter=isLayoutAnalysed) BOOL layoutAnalysed;

@property (nonatomic, assign) G8Orientation orientation;
@property (nonatomic, assign) G8WritingDirection writingDirection;
@property (nonatomic, assign) G8TextlineOrder textlineOrder;
@property (nonatomic, assign) CGFloat deskewAngle;

@end

@implementation G8Tesseract

+ (void)initialize {
    if (self == [G8Tesseract self]) {
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarningNotification:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
#elif TARGET_OS_MAC
        // TODO: Is there an equivalent?
#endif
    }
}

+ (void)didReceiveMemoryWarningNotification:(NSNotification*)notification {
    
    [self clearCache];
    // some more cleaning here if necessary
}

+ (NSString *)version
{
    const char *version = tesseract::TessBaseAPI::Version();
    return [NSString stringWithUTF8String:version];
}

+ (void)clearCache
{
    tesseract::TessBaseAPI::ClearPersistentCache();
}

- (instancetype)init {
    
    return [self initWithLanguage:nil];
}

- (instancetype)initWithLanguage:(NSString*)language
{
    return [self initWithLanguage:language configDictionary:nil configFileNames:nil cachesRelatedDataPath:nil engineMode:G8OCREngineModeLSTMOnly];
}

- (instancetype)initWithLanguage:(NSString *)language engineMode:(G8OCREngineMode)engineMode
{
    return [self initWithLanguage:language configDictionary:nil configFileNames:nil cachesRelatedDataPath:nil engineMode:engineMode];
}

- (instancetype)initWithLanguage:(NSString *)language
                configDictionary:(NSDictionary *)configDictionary
                 configFileNames:(NSArray *)configFileNames
           cachesRelatedDataPath:(NSString *)cachesRelatedPath
                      engineMode:(G8OCREngineMode)engineMode
{
    NSString *absoluteDataPath = nil;
    if (cachesRelatedPath) {
        // config Tesseract to search trainedData in tessdata folder of the Caches folder
        NSArray *cachesPaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cachesPath = cachesPaths.firstObject;
        
        absoluteDataPath = [cachesPath stringByAppendingPathComponent:cachesRelatedPath].copy;
    }
    return [self initWithLanguage:language
                 configDictionary:configDictionary
                  configFileNames:configFileNames
                 absoluteDataPath:absoluteDataPath
                       engineMode:engineMode];
}

- (instancetype)initWithLanguage:(NSString *)language
                configDictionary:(NSDictionary *)configDictionary
                 configFileNames:(NSArray *)configFileNames
                absoluteDataPath:(NSString *)absoluteDataPath
                      engineMode:(G8OCREngineMode)engineMode
{
    self = [super init];
    if (self != nil) {
        if (configFileNames) {
            NSAssert([configFileNames isKindOfClass:[NSArray class]], @"Error! configFileNames should be of type NSArray");
        }
        if (absoluteDataPath != nil) {
            [self moveTessdataToDirectoryIfNecessary:absoluteDataPath];
        }
        _absoluteDataPath = absoluteDataPath.copy;
        _configDictionary = configDictionary;
        _configFileNames = configFileNames;
        _engineMode = engineMode;
        _pageSegmentationMode = G8PageSegmentationModeSingleBlock;
        _variables = [NSMutableDictionary dictionary];
        _sourceResolution = kG8DefaultResolution;
        _rect = CGRectZero;
        
        _monitor = new ETEXT_DESC();
        _monitor->cancel = tesseractCancelCallbackFunction;
        _monitor->cancel_this = (__bridge void*)self;
        
        if (self.absoluteDataPath == nil) {
            // config Tesseract to search trainedData in tessdata folder of the application bundle];
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
            _absoluteDataPath = [NSBundle mainBundle].bundlePath;
#elif TARGET_OS_MAC
            _absoluteDataPath = [[NSBundle mainBundle] resourcePath];
#endif
        }
        
        if ([[_absoluteDataPath substringFromIndex:_absoluteDataPath.length - 1] isEqual:@"/"]) {
            _absoluteDataPath = [_absoluteDataPath substringToIndex:_absoluteDataPath.length - 1];
        }
        
        if ([[_absoluteDataPath substringFromIndex:_absoluteDataPath.length - 8] isEqualToString:@"tessdata"]) {
            // noop
        } else {
            _absoluteDataPath = [_absoluteDataPath stringByAppendingPathComponent:@"tessdata"];
        }
        
        setenv("TESSDATA_PREFIX", _absoluteDataPath.fileSystemRepresentation, 1);
        
        self.language = language.copy;
    }
    return self;
}

- (void)dealloc
{
    if (_monitor != nullptr) {
        delete _monitor;
        _monitor = nullptr;
    }
    [self freeTesseract];
}

- (void)freeTesseract {
    
    if (_tesseract != nullptr) {
        // There is no needs to call Clear() and End() explicitly.
        // End() is sufficient to free up all memory of TessBaseAPI.
        // End() is called in destructor of TessBaseAPI.
        delete _tesseract;
        _tesseract = nullptr;
    }
}

- (BOOL)configEngine
{
    __block GenericVector<STRING> tessKeys;
    __block GenericVector<STRING> tessValues;
    [self.configDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *val, BOOL *stop) {
        tessKeys.push_back(STRING(key.UTF8String));
        tessValues.push_back(STRING(val.UTF8String));
    }];
    
    int count = (int)self.configFileNames.count;
    const char **configs = count ? (const char **)malloc(sizeof(const char *) * count) : NULL;
    for (int i = 0; i < count; i++) {
        configs[i] = ((NSString*)self.configFileNames[i]).fileSystemRepresentation;
    }
    int returnCode = self.tesseract->Init(self.absoluteDataPath.fileSystemRepresentation, self.language.UTF8String,
                                          (tesseract::OcrEngineMode)self.engineMode,
                                          (char **)configs, count,
                                          &tessKeys, &tessValues,
                                          false);
    if (configs != nullptr) {
        free(configs);
    }
    
    return returnCode == 0;
}

- (void)resetFlags
{
    self.recognized = NO;
    self.layoutAnalysed = NO;
}

- (BOOL)resetEngine
{
    BOOL isInitDone = [self configEngine];
    if (isInitDone) {
        [self loadVariables];
        [self setOtherCachedValues];
        [self resetFlags];
    } else {
        NSLog(@"ERROR! Can't init Tesseract engine.");
        _language = nil;
        _engineMode = G8OCREngineModeLSTMOnly;
        [self freeTesseract];
    }
    
    return isInitDone;
}

- (void)setOtherCachedValues {
    
    if (_image) {
        [self setEngineImage:_image];
    }
    [self setSourceResolution:_sourceResolution];
    [self setEngineRect:_rect];
    [self setVariableValue:_charWhitelist forKey:kG8ParamTesseditCharWhitelist];
    [self setVariableValue:_charBlacklist forKey:kG8ParamTesseditCharBlacklist];
    [self setVariableValue:[NSString stringWithFormat:@"%lu", (unsigned long)_pageSegmentationMode]
                    forKey:kG8ParamTesseditPagesegMode];
}

- (BOOL)moveTessdataToDirectoryIfNecessary:(NSString *)directoryPath
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Useful paths
    NSString *tessdataFolderName = @"tessdata";
    NSString *tessdataPath = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:tessdataFolderName];
    NSString *destinationPath = [directoryPath stringByAppendingPathComponent:tessdataFolderName];
    NSLog(@"Tesseract destination path: %@", destinationPath);
    
    BOOL isDirectory = YES;
    if (![fileManager fileExistsAtPath:tessdataPath isDirectory:&isDirectory] || !isDirectory) {
        // No tessdata directory in application bundle, nothing to do.
        return NO;
    }
    
    if ([fileManager fileExistsAtPath:destinationPath] == NO) {
        ERROR_DEF
        BOOL res = [fileManager createDirectoryAtPath:destinationPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (res == NO) {
            NSLog(@"Error creating folder %@: %@", destinationPath, error);
            return NO;
        }
    }
    
    BOOL result = YES;
    ERROR_DEF
    NSArray *files = [fileManager contentsOfDirectoryAtPath:tessdataPath error:&error];
    if (files == nil) {
        NSLog(@"ERROR! %@", error.description);
        result = NO;
    } else {
        for (NSString *filename in files) {
            
            NSString *destinationFileName = [destinationPath stringByAppendingPathComponent:filename];
            if (![fileManager fileExistsAtPath:destinationFileName]) {
                
                NSString *filePath = [tessdataPath stringByAppendingPathComponent:filename];
                
                // delete broken symlinks first
                [fileManager removeItemAtPath:destinationFileName error:&error];
                
                // then recreate it
                error = nil;    // don't care about previous error, that can happen if we tried to remove a symlink that doesn't exist
                BOOL res = [fileManager createSymbolicLinkAtPath:destinationFileName
                                             withDestinationPath:filePath
                                                           error:&error];
                if (res == NO) {
                    NSLog(@"Error creating symlink %@: %@", destinationPath, error);
                    result = NO;
                }
            }
        }
    }
    
    return result;
}

- (void)setVariableValue:(NSString *)value forKey:(NSString *)key
{
    /*
     * Example:
     * _tesseract->SetVariable("tessedit_char_whitelist", "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ");
     * _tesseract->SetVariable("language_model_penalty_non_freq_dict_word", "0");
     * _tesseract->SetVariable("language_model_penalty_non_dict_word ", "0");
     */
    
    [self resetFlags];
    
    if (!value) {
        value = @"";
    }
    self.variables[key] = value;
    
    if (self.isEngineConfigured) {
        _tesseract->SetVariable(key.UTF8String, value.UTF8String);
    }
}

- (NSString*)variableValueForKey:(NSString *)key {
    
    if (!self.isEngineConfigured) {
        return self.variables[key];
    } else {
        STRING val;
        _tesseract->GetVariableAsString(key.UTF8String, &val);
        return [NSString stringWithUTF8String:val.string()];
    }
}

- (void)setVariablesFromDictionary:(NSDictionary *)dictionary
{
    [dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [self setVariableValue:value forKey:key];
    }];
}

- (void)loadVariables
{
    if (self.isEngineConfigured) {
        [self.variables enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            self->_tesseract->SetVariable(key.UTF8String, value.UTF8String);
        }];
    }
}

#pragma mark - Internal getters and setters

- (tesseract::TessBaseAPI *)tesseract {
    
    if (!_tesseract) {
        _tesseract = new tesseract::TessBaseAPI();
    }
    return _tesseract;
}

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR

- (void)setEngineImage:(UIImage *)image {
    
    if (image.size.width <= 0 || image.size.height <= 0) {
        NSLog(@"ERROR: Image has invalid size!");
        return;
    }
    
    self.imageSize = image.size; //self.imageSize used in the characterBoxes method
    
    if (self.isEngineConfigured) {
        Pix *pix = nullptr;
        
        if ([self.delegate respondsToSelector:@selector(preprocessedImageForTesseract:sourceImage:)]) {
            UIImage *thresholdedImage = [self.delegate preprocessedImageForTesseract:self sourceImage:image];
            if (thresholdedImage != nil) {
                self.imageSize = thresholdedImage.size;
                
                Pix *pixs = [self pixForImage:thresholdedImage];
                pix = pixConvertTo1(pixs, UINT8_MAX / 2);
                pixDestroy(&pixs);
                
                if (pix == nullptr) {
                    NSLog(@"WARNING: Can't create Pix for custom thresholded image!");
                }
            }
        }
        
        if (pix == nullptr) {
            pix = [self pixForImage:image];
        }
        
        @try {
            _tesseract->SetImage(pix);
        }
        //LCOV_EXCL_START
        @catch (NSException *exception) {
            NSLog(@"ERROR: Can't set image: %@", exception);
        }
        //LCOV_EXCL_STOP
        pixDestroy(&pix);
    }
    
    _image = image;
    
    [self resetFlags];
}

#elif TARGET_OS_MAC

- (void)setEngineImage:(NSImage *)image {
    
    if (image.size.width <= 0 || image.size.height <= 0) {
        NSLog(@"ERROR: Image has invalid size!");
        return;
    }
    
    // TODO: Is it cheaper to create a CGImageRef and get the size from that or to
    // iterate through the representations of the NSImage and find the largest
    // width and height?
    NSInteger width = 0;
    NSInteger height = 0;
    
    for (NSImageRep * imageRep in [image representations]) {
        if ([imageRep pixelsWide] > width) width = [imageRep pixelsWide];
        if ([imageRep pixelsHigh] > height) height = [imageRep pixelsHigh];
    }
    
    NSSize imgSize = NSMakeSize((CGFloat)width, (CGFloat)height);
    
    self.imageSize = imgSize; // self.imageSize used in the characterBoxes method
    
    if (self.isEngineConfigured) {
        Pix *pix = nullptr;
        
        if ([self.delegate respondsToSelector:@selector(preprocessedImageForTesseract:sourceImage:)]) {
            NSImage *thresholdedImage = [self.delegate preprocessedImageForTesseract:self sourceImage:image];
            if (thresholdedImage != nil) {
                // TODO: Is getting the size like this okay?
                self.imageSize = thresholdedImage.size;
                
                Pix *pixs = [self pixForImage:thresholdedImage];
                pix = pixConvertTo1(pixs, UINT8_MAX / 2);
                pixDestroy(&pixs);
                
                if (pix == nullptr) {
                    NSLog(@"WARNING: Can't create Pix for custom thresholded image!");
                }
            }
        }
        
        if (pix == nullptr) {
            pix = [self pixForImage:image];
        }
        
        @try {
            _tesseract->SetImage(pix);
        }
        //LCOV_EXCL_START
        @catch (NSException *exception) {
            NSLog(@"ERROR: Can't set image: %@", exception);
        }
        //LCOV_EXCL_STOP
        pixDestroy(&pix);
    }
    
    _image = image;
    
    [self resetFlags];
}

- (BOOL)useBitmapImageRep:(NSBitmapImageRep *)imageRep {
    if (!imageRep) {
        NSLog(@"ERROR: No image rep");
        return NO;
    }

    self.imageSize = CGSizeMake(imageRep.pixelsWide, imageRep.pixelsHigh);
    if (self.imageSize.width <= 0 || self.imageSize.width <= 0) {
        NSLog(@"ERROR: Image rep with wrong size");
        return NO;
    }

    unsigned char *imageData = imageRep.bitmapData;
    if (!imageData) {
        NSLog(@"ERROR: Image rep with no imageData");
        return NO;
    }

    int bytes_per_line = (int)imageRep.bytesPerRow;
    int bytes_per_pixel = (int)imageRep.bitsPerPixel / 8;
    int bits_per_pixel = (int)(bytes_per_pixel == 0 ? 1 : bytes_per_pixel * 8);

    _tesseract->SetImage((const unsigned char*)imageData,
                         bytes_per_line * 8 / bits_per_pixel,
                         imageRep.pixelsHigh,
                         bytes_per_pixel,
                         bytes_per_line);

    NSImage *image = [[NSImage alloc] initWithSize:self.imageSize];
    [image addRepresentation:imageRep];
    _image = image;

    [self resetFlags];
    return YES;
}

#endif

- (void)setEngineSourceResolution:(NSUInteger)sourceResolution {
    if (self.isEngineConfigured) {
        _tesseract->SetSourceResolution((int)sourceResolution);
    }
}

- (void)setEngineRect:(CGRect)rect {
    
    if (!self.isEngineConfigured) {
        return;
    }
    
    CGFloat x = CGRectGetMinX(rect);
    CGFloat y = CGRectGetMinY(rect);
    CGFloat width = CGRectGetWidth(rect);
    CGFloat height = CGRectGetHeight(rect);
    
    // Because of custom preprocessing we may have to resize rect
    if (CGSizeEqualToSize(self.image.size, self.imageSize) == NO) {
        // TODO: What to do here? Is this what we want or should the image size be returning
        // the CGImageRef size?
        
        CGFloat widthFactor = self.imageSize.width / self.image.size.width;
        CGFloat heightFactor = self.imageSize.height / self.image.size.height;
        
        x *= widthFactor;
        y *= heightFactor;
        width *= widthFactor;
        heightFactor *= heightFactor;
    }
    
    CGFloat (^clip)(CGFloat, CGFloat, CGFloat) = ^(CGFloat value, CGFloat min, CGFloat max) {
        return (value < min ? min : (value > max ? max : value));
    };
    
    // Clip rect by image size
    x = clip(x, 0, self.imageSize.width);
    y = clip(y, 0, self.imageSize.height);
    width = clip(width, 0, self.imageSize.width - x);
    height = clip(height, 0, self.imageSize.height - y);
    
    _tesseract->SetRectangle(x, y, width, height);
}

#pragma mark - Public getters and setters

- (void)setLanguage:(NSString *)language
{
    if ([language isEqualToString:_language] == NO || (!language && _language) ) {
        
        _language = language.copy;
        if (!self.language) {
            NSLog(@"WARNING: Setting G8Tesseract language to nil defaults to English, so make sure you either set the language afterward or have eng.traineddata in your tessdata folder, otherwise Tesseract will crash!");
        }
        /*
         * "WARNING: On changing languages, all Tesseract parameters
         * are reset back to their default values."
         */
        [self resetEngine];
    }
}

- (void)setEngineMode:(G8OCREngineMode)engineMode
{
    if (_engineMode != engineMode) {
        _engineMode = engineMode;
        
        [self resetEngine];
    }
}

- (void)setPageSegmentationMode:(G8PageSegmentationMode)pageSegmentationMode
{
    if (_pageSegmentationMode != pageSegmentationMode) {
        _pageSegmentationMode = pageSegmentationMode;
        
        [self setVariableValue:[NSString stringWithFormat:@"%lu", (unsigned long)pageSegmentationMode]
                        forKey:kG8ParamTesseditPagesegMode];
    }
}

- (void)setCharWhitelist:(NSString *)charWhitelist
{
    if ([_charWhitelist isEqualToString:charWhitelist] == NO) {
        _charWhitelist = charWhitelist.copy;
        
        [self setVariableValue:_charWhitelist forKey:kG8ParamTesseditCharWhitelist];
    }
}

- (void)setCharBlacklist:(NSString *)charBlacklist
{
    if ([_charBlacklist isEqualToString:charBlacklist] == NO) {
        _charBlacklist = charBlacklist.copy;
        
        [self setVariableValue:_charBlacklist forKey:kG8ParamTesseditCharBlacklist];
    }
}

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR

- (void)setImage:(UIImage *)image
{
    if (_image != image) {
        [self setEngineImage:image];
        _rect = (CGRect){CGPointZero, self.imageSize};
    }
}

#elif TARGET_OS_MAC

- (void)setImage:(NSImage *)image
{
    if (_image != image) {
        [self setEngineImage:image];
        _rect = (CGRect){CGPointZero, self.imageSize};
    }
}

#endif

- (void)setRect:(CGRect)rect
{
    if (CGRectEqualToRect(_rect, rect) == NO) {
        _rect = rect;
        [self setEngineRect:_rect];
        [self resetFlags];
    }
}

- (void)setSourceResolution:(NSUInteger)sourceResolution
{
    if (_sourceResolution != sourceResolution) {
        
        if (sourceResolution > kG8MaxCredibleResolution) {
            NSLog(@"Source resolution is too big: %ld > %ld", (long)sourceResolution, (long)kG8MaxCredibleResolution);
            sourceResolution = kG8MaxCredibleResolution;
        }
        else if (sourceResolution < kG8MinCredibleResolution) {
            NSLog(@"Source resolution is too small: %ld < %ld", (long)sourceResolution, (long)kG8MinCredibleResolution);
            sourceResolution = kG8MinCredibleResolution;
        }
        _sourceResolution = sourceResolution;
        [self setEngineSourceResolution:_sourceResolution];
    }
}

- (NSUInteger)progress
{
    return _monitor->progress;
}

- (BOOL)isEngineConfigured {
    return _tesseract != nullptr;
}

#pragma mark - Result fetching

- (NSString *)recognizedText
{
    if (!self.isEngineConfigured) {
        NSLog(@"Error! Cannot get recognized text because the Tesseract engine is not properly configured!");
        return nil;
    }
    char *utf8Text = _tesseract->GetUTF8Text();
    if (utf8Text == NULL) {
        NSLog(@"No recognized text. Check that -[Tesseract setImage:] is passed an image bigger than 0x0.");
        return nil;
    }
    
    NSString *text = [NSString stringWithUTF8String:utf8Text];
    delete[] utf8Text;
    return text;
}

- (G8Orientation)orientation
{
    [self analyseLayout];
    return _orientation;
}

- (G8WritingDirection)writingDirection
{
    [self analyseLayout];
    return _writingDirection;
}

- (G8TextlineOrder)textlineOrder
{
    [self analyseLayout];
    return _textlineOrder;
}

- (CGFloat)deskewAngle
{
    [self analyseLayout];
    return _deskewAngle;
}

- (void)analyseLayout
{
    // Only perform the layout analysis if we haven't already
    if (self.layoutAnalysed) return;
    
    if (!self.isEngineConfigured) {
        NSLog(@"Error! Cannot perform layout analysis because the engine is not properly configured!");
        return;
    }
    
    tesseract::Orientation orientation;
    tesseract::WritingDirection direction;
    tesseract::TextlineOrder order;
    float deskewAngle;
    
    tesseract::PageIterator *iterator = _tesseract->AnalyseLayout();
    if (iterator == NULL) {
        NSLog(@"Can't analyse layout. Make sure 'osd.traineddata' available in 'tessdata'.");
        return;
    }
    
    iterator->Orientation(&orientation, &direction, &order, &deskewAngle);
    delete iterator;
    
    self.orientation = (G8Orientation)orientation;
    self.writingDirection = (G8WritingDirection)direction;
    self.textlineOrder = (G8TextlineOrder)order;
    self.deskewAngle = deskewAngle;
    
    self.layoutAnalysed = YES;
}


- (CGRect)normalizedRectForX:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height
{
    x /= self.imageSize.width;
    y /= self.imageSize.height;
    width /= self.imageSize.width;
    height /= self.imageSize.height;
    return CGRectMake(x, y, width, height);
}

- (G8RecognizedBlock *)blockFromIterator:(tesseract::ResultIterator *)iterator
                           iteratorLevel:(G8PageIteratorLevel)iteratorLevel
{
    tesseract::PageIteratorLevel level = (tesseract::PageIteratorLevel)iteratorLevel;
    
    G8RecognizedBlock *block = nil;
    const char *word = iterator->GetUTF8Text(level);
    if (word != NULL) {
        // BoundingBox parameters are (Left Top Right Bottom).
        // (L, T) is the top left corner of the box, and (R, B) is the bottom right corner
        // Tesseract has (0, 0) in the bottom left corner and UIKit has (0, 0) in the top left corner
        // Need to flip to work with UIKit
        int x1, y1, x2, y2;
        iterator->BoundingBox(level, &x1, &y1, &x2, &y2); // left top right bottom
        
        // TODO: Maybe it needs to be thresholded image in some cases?
#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
        CGFloat y = y1;
#elif TARGET_OS_MAC
        CGImage *cgImage = [self.image CGImageForProposedRect: nil context: nil hints: nil];
        CGFloat imgHeight = (CGFloat)CGImageGetHeight(cgImage);
        // This is for AppKit (macOS) because coordinate system starts in bottom left as
        // opposed to top left for UIKit
        CGFloat y = (imgHeight - y1) - (y2 - y1);
#endif
        
        CGFloat x = x1;
        CGFloat width = x2 - x1;
        CGFloat height = y2 - y1;
        
        NSString *text = [NSString stringWithUTF8String:word];
        
        CGRect boundingBox = [self normalizedRectForX:x y:y width:width height:height];
        CGFloat confidence = iterator->Confidence(level);
        delete[] word;
        
        block = [[G8RecognizedBlock alloc] initWithText:text
                                            boundingBox:boundingBox
                                             confidence:confidence
                                                  level:iteratorLevel];
    }
    return block;
}

- (void)forEachWord:(G8AlternativeTesseractOCRResultBlock_t)block {
    //    hxAssert0(block);

    // https://code.google.com/p/tesseract-ocr/wiki/APIExample
    tesseract::ResultIterator* iterator = _tesseract->GetIterator();
    tesseract::PageIteratorLevel level = tesseract::RIL_WORD;
    if (iterator != 0) {
        do {
            const char *word = iterator->GetUTF8Text(level);
            if (word) {
                if (strlen(word)) {
                    G8AlternativeTesseractOCRResult result;

                    NSString *text = [NSString stringWithUTF8String:word];
                    result.word = text;

                    int x1, y1, x2, y2;
                    iterator->BoundingBox(level, &x1, &y1, &x2, &y2);
                    result.rect = CGRectMake(x1, self.imageSize.height - y2, x2 - x1, y2 - y1);

                    iterator->Baseline(level, &x1, &y1, &x2, &y2);
                    result.baseline = self.imageSize.height - ((y1 + y2) / 2.);

                    CGFloat confidence = iterator->Confidence(level);
                    result.confidence = confidence;

                    iterator->WordFontAttributes(&result.bold,
                                                 &result.italic,
                                                 &result.underlined,
                                                 &result.monospace,
                                                 &result.serif,
                                                 &result.smallcaps,
                                                 &result.pointsize,
                                                 &result.font_id);

                    if(block) {
                        block(result);
                    }
                }
                delete[] word;
            }
        } while (iterator->Next(level));
    }
    delete iterator;
}

- (G8HierarchicalRecognizedBlock *)hierarchicalBlockFromIterator:(tesseract::ResultIterator *)iterator
                                                   iteratorLevel:(G8PageIteratorLevel)iteratorLevel {
    
    G8HierarchicalRecognizedBlock* block = [[G8HierarchicalRecognizedBlock alloc] initWithBlock:[self blockFromIterator:iterator iteratorLevel:iteratorLevel]];
    
    if (iteratorLevel == G8PageIteratorLevelWord) {
        bool isBold;
        bool isItalic;
        bool isUnderlined;
        bool isMonospace;
        bool isSerif;
        bool isSmallcaps;
        int pointsize;
        int fontId;
        
        iterator->WordFontAttributes(&isBold, &isItalic, &isUnderlined, &isMonospace, &isSerif, &isSmallcaps, &pointsize, &fontId);
        
        block.isFromDict = iterator->WordIsFromDictionary();
        block.isNumeric = iterator->WordIsNumeric();
        block.isBold = isBold;
        block.isItalic = isItalic;
    } else if (iteratorLevel == G8PageIteratorLevelSymbol) {
        // get character choices
        NSMutableArray *choices = [NSMutableArray array];
        
        tesseract::ChoiceIterator choiceIterator(*iterator);
        do {
            const char *choiceWord = choiceIterator.GetUTF8Text();
            if (choiceWord != NULL) {
                NSString *text = [NSString stringWithUTF8String:choiceWord];
                CGFloat confidence = choiceIterator.Confidence();
                
                G8RecognizedBlock *choiceBlock = [[G8RecognizedBlock alloc] initWithText:text
                                                                             boundingBox:block.boundingBox
                                                                              confidence:confidence
                                                                                   level:G8PageIteratorLevelSymbol];
                [choices addObject:choiceBlock];
            }
        } while (choiceIterator.Next());
        
        block.characterChoices = [choices copy];
    }
    return block;
}

- (NSArray *)characterChoices
{
    if (!self.isEngineConfigured) {
        return nil;
    }
    NSMutableArray *array = [NSMutableArray array];
    //  Get iterators
    tesseract::ResultIterator *resultIterator = _tesseract->GetIterator();
    
    if (resultIterator != NULL) {
        do {
            G8RecognizedBlock *block = [self blockFromIterator:resultIterator iteratorLevel:G8PageIteratorLevelSymbol];
            NSMutableArray *choices = [NSMutableArray array];
            
            tesseract::ChoiceIterator choiceIterator(*resultIterator);
            do {
                const char *choiceWord = choiceIterator.GetUTF8Text();
                if (choiceWord != NULL) {
                    NSString *text = [NSString stringWithUTF8String:choiceWord];
                    CGFloat confidence = choiceIterator.Confidence();
                    
                    G8RecognizedBlock *choiceBlock = [[G8RecognizedBlock alloc] initWithText:text
                                                                                 boundingBox:block.boundingBox
                                                                                  confidence:confidence
                                                                                       level:G8PageIteratorLevelSymbol];
                    [choices addObject:choiceBlock];
                }
            } while (choiceIterator.Next());
            
            [array addObject:[choices copy]];
        } while (resultIterator->Next(tesseract::RIL_SYMBOL));
        delete resultIterator;
    }
    
    return [array copy];
}

- (NSArray *) recognizedHierarchicalBlocksByIteratorLevel:(G8PageIteratorLevel)pageIteratorLevel {
    if (!self.engineConfigured) {
        return nil;
    }
    
    tesseract::ResultIterator *resultIterator = _tesseract->GetIterator();
    
    NSArray *blocks = [self getBlocksFromIterator:resultIterator forLevel:pageIteratorLevel highestLevel:pageIteratorLevel];
    
    return blocks;
}

-(NSArray*) getBlocksFromIterator:(tesseract::ResultIterator*)resultIterator forLevel:(G8PageIteratorLevel)pageIteratorLevel highestLevel:(G8PageIteratorLevel)highestLevel {
    
    NSMutableArray *blocks = [[NSMutableArray alloc] init];
    
    tesseract::PageIteratorLevel level = (tesseract::PageIteratorLevel)pageIteratorLevel;
    
    BOOL endOfBlock = NO;
    
    do {
        G8HierarchicalRecognizedBlock *block = [self hierarchicalBlockFromIterator:resultIterator iteratorLevel:pageIteratorLevel];
        [blocks addObject:block];
        
        // if we are on a higher level than symbol call the getblocks function for the next deeper level
        if (pageIteratorLevel != G8PageIteratorLevelSymbol) {
            block.childBlocks = [self getBlocksFromIterator:resultIterator forLevel:[self getDeeperIteratorLevel:pageIteratorLevel] highestLevel:highestLevel];
        }
        
        // check if we are at the end of a block
        endOfBlock = (pageIteratorLevel != highestLevel && resultIterator->IsAtFinalElement((tesseract::PageIteratorLevel)[self getHigherIteratorLevel:pageIteratorLevel], level)) || !resultIterator->Next(level);
        
        
    } while (!endOfBlock);
    
    return blocks;
}

-(G8PageIteratorLevel)getDeeperIteratorLevel:(G8PageIteratorLevel)iteratorLevel {
    switch (iteratorLevel) {
        case G8PageIteratorLevelBlock: return G8PageIteratorLevelParagraph;
        case G8PageIteratorLevelParagraph: return G8PageIteratorLevelTextline;
        case G8PageIteratorLevelTextline: return G8PageIteratorLevelWord;
        case G8PageIteratorLevelWord: return G8PageIteratorLevelSymbol;
        case G8PageIteratorLevelSymbol: return G8PageIteratorLevelSymbol;
    }
}


-(G8PageIteratorLevel)getHigherIteratorLevel:(G8PageIteratorLevel)iteratorLevel {
    switch (iteratorLevel) {
        case G8PageIteratorLevelBlock: return G8PageIteratorLevelBlock;
        case G8PageIteratorLevelParagraph: return G8PageIteratorLevelBlock;
        case G8PageIteratorLevelTextline: return G8PageIteratorLevelParagraph;
        case G8PageIteratorLevelWord: return G8PageIteratorLevelTextline;
        case G8PageIteratorLevelSymbol: return G8PageIteratorLevelWord;
    }
}


- (NSArray *)recognizedBlocksByIteratorLevel:(G8PageIteratorLevel)pageIteratorLevel
{
    if (!self.isEngineConfigured) {
        return nil;
    }
    tesseract::PageIteratorLevel level = (tesseract::PageIteratorLevel)pageIteratorLevel;
    
    NSMutableArray *array = [NSMutableArray array];
    //  Get iterators
    tesseract::ResultIterator *resultIterator = _tesseract->GetIterator();
    
    if (resultIterator != NULL) {
        do {
            G8RecognizedBlock *block = [self blockFromIterator:resultIterator iteratorLevel:pageIteratorLevel];
            if (block != nil) {
                [array addObject:block];
            }
        } while (resultIterator->Next(level));
        delete resultIterator;
    }
    
    return [array copy];
}

- (NSString *)recognizedHOCRForPageNumber:(int)pageNumber {
    if (self.isEngineConfigured) {
        
        char *hocr = _tesseract->GetHOCRText(pageNumber);
        if (hocr) {
            NSString *text = [NSString stringWithUTF8String:hocr];
            free(hocr);
            return text;
        }
    }
    return nil;
}

// outputbase is the name of the output file excluding
// extension. For example, "/path/to/chocolate-chip-cookie-recipe"
- (NSData *)recognizedPDFForImages:(NSArray*)images {
    if (!self.isEngineConfigured) {
        return nil;
    }

    ERROR_DEF
    NSString *tempDirPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    NSLog(@"Temp folder %@", tempDirPath);
    [NSFileManager.defaultManager createDirectoryAtPath:tempDirPath withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *outputbase = [tempDirPath stringByAppendingPathComponent:@"outputbase"];
    // TODO:2018-09-21 Check for errors
    NSLog(@"Output base %@ and error %@", tempDirPath, error);

    tesseract::TessPDFRenderer *renderer = new tesseract::TessPDFRenderer(outputbase.fileSystemRepresentation,
                                                                          self.absoluteDataPath.fileSystemRepresentation,
                                                                          false);
    
    // Begin producing output
    const char* kUnknownTitle = "PDF Renderer";
    if (renderer && !renderer->BeginDocument(kUnknownTitle)) {
        return nil; // LCOV_EXCL_LINE
    }
    
    bool result = YES;
    
    for (int page = 0; page < images.count && result; page++) {
        XXImage *image = images[page];
        if ([image isKindOfClass:[XXImage class]]) {
            Pix *pixs = [self pixForImage:image];
            // Pix *pix = pixConvertTo1(pixs, UINT8_MAX / 2);
            // Pix *pix = pixConvertTo8(pixs, UINT8_MAX / 2);
            Pix *pix = pixConvertTo32(pixs);
            pixDestroy(&pixs);
            
            if (self.maximumRecognitionTime > FLT_EPSILON) {
                _monitor->set_deadline_msecs((int32_t)(self.maximumRecognitionTime * 1000));
            }
            
            const char *pagename = [NSString stringWithFormat:@"page.%i", page].UTF8String;
            _tesseract->SetInputName(pagename);
            _tesseract->SetImage(pix);

            if (_tesseract->Recognize(_monitor) != 0) {
                NSLog(@"Failed applying OCR to image");
                result = NO;
            } else {                
                if (renderer && renderer->AddImage(_tesseract) != 0) {
                    NSLog(@"Failed adding image to PDF");
                    result = NO;
                }
            }
            
            pixDestroy(&pix);

            if (!result) {
                break;
            }
        }
    }
    
    //  error
    if (!result) {
        return nil; // LCOV_EXCL_LINE
    }
    
    // Finish producing output
    if (renderer && !renderer->EndDocument()) {
        return nil; // LCOV_EXCL_LINE
    }
    
    delete renderer;
    renderer = nullptr;
    
    NSString *outputbaseFilePath = [outputbase stringByAppendingPathExtension:@"pdf"];
    NSData *data = [NSData dataWithContentsOfFile:outputbaseFilePath];

    // Cleanup
    [[NSFileManager defaultManager] removeItemAtPath:outputbaseFilePath error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:tempDirPath error:&error];
    return data;
}

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR

- (UIImage *)imageWithBlocks:(NSArray *)blocks drawText:(BOOL)drawText thresholded:(BOOL)thresholded
{
    UIImage *image = thresholded ? self.thresholdedImage : self.image;
    
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIGraphicsPushContext(context);
    
    [image drawInRect:(CGRect){CGPointZero, image.size}];
    
    CGContextSetLineWidth(context, 2.0f);
    CGContextSetStrokeColorWithColor(context, [UIColor redColor].CGColor);
    
    for (G8RecognizedBlock *block in blocks) {
        CGRect boundingBox = [block boundingBoxAtImageOfSize:image.size];
        CGRect rect = CGRectMake(boundingBox.origin.x, boundingBox.origin.y,
                                 boundingBox.size.width, boundingBox.size.height);
        CGContextStrokeRect(context, rect);
        
        if (drawText) {
            NSAttributedString *string =
            [[NSAttributedString alloc] initWithString:block.text attributes:@{
                                                                               NSForegroundColorAttributeName: [UIColor redColor]
                                                                               }];
            [string drawAtPoint:(CGPoint){CGRectGetMidX(rect), CGRectGetMaxY(rect) + 2}];
        }
    }
    
    UIGraphicsPopContext();
    UIImage *outputImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return outputImage;
}

#elif TARGET_OS_MAC

- (NSImage *)imageWithBlocks:(NSArray *)blocks drawText:(BOOL)drawText thresholded:(BOOL)thresholded
{
    NSImage *image = thresholded ? self.thresholdedImage : self.image;
    
    CGImage *cgImage = [image CGImageForProposedRect: nil context: nil hints: nil];
    NSInteger width = (NSInteger)CGImageGetWidth(cgImage);
    NSInteger height = (NSInteger)CGImageGetHeight(cgImage);
    NSSize size = NSMakeSize(width, height);
    
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                             initWithBitmapDataPlanes:NULL
                             pixelsWide:size.width
                             pixelsHigh:size.height
                             bitsPerSample:8
                             samplesPerPixel:4
                             hasAlpha:YES
                             isPlanar:NO
                             colorSpaceName:NSCalibratedRGBColorSpace
                             bytesPerRow:0
                             bitsPerPixel:0];
    rep.size = size;
    
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    
    CGContextSetLineWidth(context, 2.0f);
    CGContextSetStrokeColorWithColor(context, [NSColor redColor].CGColor);
    
    [image drawInRect:NSMakeRect(0, 0, size.width, size.height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    
    for (G8RecognizedBlock *block in blocks) {
        CGRect boundingBox = [block boundingBoxAtImageOfSize:size];
        CGRect rect = CGRectMake(boundingBox.origin.x, boundingBox.origin.y,
                                 boundingBox.size.width, boundingBox.size.height);
        
        CGContextStrokeRect(context, rect);
        
        if (drawText) {
            NSAttributedString *string =
            [[NSAttributedString alloc] initWithString:block.text attributes:@{
                                                                               NSForegroundColorAttributeName: [NSColor redColor]
                                                                               }];
            [string drawAtPoint:(CGPoint){CGRectGetMidX(rect), CGRectGetMinY(rect) - 17}];
        }
    }
    
    [NSGraphicsContext restoreGraphicsState];
    
    NSImage *newImage = [[NSImage alloc] initWithSize:size];
    [newImage addRepresentation:rep];
    return newImage;
}

#endif

#pragma mark - Other functions

- (BOOL)recognize
{
    if (!self.isEngineConfigured) {
        NSLog(@"Error! Cannot recognize text because the Tesseract engine is not properly configured!");
        return NO;
    }
    
    if (self.maximumRecognitionTime > FLT_EPSILON) {
        _monitor->set_deadline_msecs((int32_t)(self.maximumRecognitionTime * 1000));
    }
    
    self.recognized = NO;
    int returnCode = 0;
    @try {
        returnCode = _tesseract->Recognize(_monitor);
        self.recognized = YES;
    }
    //LCOV_EXCL_START
    @catch (NSException *exception) {
        NSLog(@"Exception was raised while recognizing: %@", exception);
    }
    //LCOV_EXCL_STOP
    return returnCode == 0 && self.recognized;
}

- (XXImage *)thresholdedImage
{
    if (!self.isEngineConfigured) {
        return nil;
    }
    Pix *pixs = _tesseract->GetThresholdedImage();
    Pix *pix = pixUnpackBinary(pixs, 32, 0);
    
    pixDestroy(&pixs);
    
    return [self imageFromPix:pix];
}

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
- (UIImage *)imageFromPix:(Pix *)pix
{
    // Get Pix parameters
    l_uint32 width = pixGetWidth(pix);
    l_uint32 height = pixGetHeight(pix);
    l_uint32 bitsPerPixel = pixGetDepth(pix);
    l_uint32 bytesPerRow = pixGetWpl(pix) * 4;
    l_uint32 bitsPerComponent = 8;
    // By default Leptonica uses 3 spp (RGB)
    if (pixSetSpp(pix, 4) == 0) {
        bitsPerComponent = bitsPerPixel / pixGetSpp(pix);
    }
    
    l_uint32 *pixData = pixGetData(pix);
    
    // Create CGImage
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixData, bytesPerRow * height, NULL);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGImageRef cgImage = CGImageCreate(width, height,
                                       bitsPerComponent, bitsPerPixel, bytesPerRow,
                                       colorSpace, kCGBitmapByteOrderDefault,
                                       provider, NULL, NO, kCGRenderingIntentDefault);
    
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
    // Draw CGImage to create UIImage
    //      Creating UIImage by [UIImage imageWithCGImage:] worked wrong
    //      and image became broken after some releases.
    CGRect frame = { CGPointZero, CGSizeMake(width, height) };
    UIGraphicsBeginImageContextWithOptions(frame.size, YES, self.image.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Context must be mirrored vertical
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, frame, cgImage);
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    CGImageRelease(cgImage);
    pixDestroy(&pix);
    
    return image;
}
#elif TARGET_OS_MAC
- (NSImage *)imageFromPix:(Pix *)pix
{
    // Get Pix parameters
    l_uint32 width = pixGetWidth(pix);
    l_uint32 height = pixGetHeight(pix);
    l_uint32 bitsPerPixel = pixGetDepth(pix);
    l_uint32 bytesPerRow = pixGetWpl(pix) * 4;
    l_uint32 bitsPerComponent = 8;
    // By default Leptonica uses 3 spp (RGB)
    if (pixSetSpp(pix, 4) == 0) {
        bitsPerComponent = bitsPerPixel / pixGetSpp(pix);
    }
    
    l_uint32 *pixData = pixGetData(pix);
    
    // Create CGImage
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixData, bytesPerRow * height, NULL);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGImageRef cgImage = CGImageCreate(width, height,
                                       bitsPerComponent, bitsPerPixel, bytesPerRow,
                                       colorSpace, kCGBitmapByteOrderDefault,
                                       provider, NULL, NO, kCGRenderingIntentDefault);
    
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
    // Draw CGImage to create UIImage.
    // Creating UIImage by [UIImage imageWithCGImage:] worked wrong
    // and image became broken after some releases.
    CGRect frame = { CGPointZero, CGSizeMake(width, height) };
    
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                             initWithBitmapDataPlanes:NULL
                             pixelsWide:frame.size.width
                             pixelsHigh:frame.size.height
                             bitsPerSample:8
                             samplesPerPixel:4
                             hasAlpha:YES
                             isPlanar:NO
                             colorSpaceName:NSCalibratedRGBColorSpace
                             bytesPerRow:0
                             bitsPerPixel:0];
    rep.size = frame.size;
    
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    
    // Don't need to mirror vertically because Quartz coordinate system has
    // origin in bottom left, not top left as it is in iOS
    CGContextDrawImage(context, frame, cgImage);
    
    CGImageRelease(cgImage);
    pixDestroy(&pix);
    
    [NSGraphicsContext restoreGraphicsState];
    
    NSImage *newImage = [[NSImage alloc] initWithSize:frame.size];
    [newImage addRepresentation:rep];
    
    return newImage;
}
#endif

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
- (Pix *)pixForImage:(UIImage *)image
{
    int width = image.size.width;
    int height = image.size.height;
    
    CGImage *cgImage = image.CGImage;
    CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    const UInt8 *pixels = CFDataGetBytePtr(imageData);
    
    size_t bitsPerPixel = CGImageGetBitsPerPixel(cgImage);
    size_t bytesPerPixel = bitsPerPixel / 8;
    size_t bytesPerRow = CGImageGetBytesPerRow(cgImage);
    
    int bpp = MAX(1, (int)bitsPerPixel);
    Pix *pix = pixCreate(width, height, bpp == 24 ? 32 : bpp);
    l_uint32 *data = pixGetData(pix);
    int wpl = pixGetWpl(pix);
    
    void (^copyBlock)(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) = nil;
    switch (bpp) {
            
#if 0 // BPP1 start. Uncomment this if UIImage can support 1bpp someday
            // Just a reference for the copyBlock
        case 1:
            for (int y = 0; y < height; ++y, data += wpl, pixels += bytesPerRow) {
                for (int x = 0; x < width; ++x) {
                    if (pixels[x / 8] & (0x80 >> (x % 8))) {
                        CLEAR_DATA_BIT(data, x);
                    }
                    else {
                        SET_DATA_BIT(data, x);
                    }
                }
            }
            break;
#endif // BPP1 end
            
        case 8: {
            copyBlock = ^(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) {
                SET_DATA_BYTE(toAddr, toOffset, fromAddr[fromOffset]);
            };
            break;
        }
            
#if 0 // BPP24 start. Uncomment this if UIImage can support 24bpp someday
            // Just a reference for the copyBlock
        case 24:
            // Put the colors in the correct places in the line buffer.
            for (int y = 0; y < height; ++y, pixels += bytesPerRow) {
                for (int x = 0; x < width; ++x, ++data) {
                    SET_DATA_BYTE(data, COLOR_RED, pixels[3 * x]);
                    SET_DATA_BYTE(data, COLOR_GREEN, pixels[3 * x + 1]);
                    SET_DATA_BYTE(data, COLOR_BLUE, pixels[3 * x + 2]);
                }
            }
            break;
#endif // BPP24 end
            
        case 32: {
            copyBlock = ^(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) {
                toAddr[toOffset] = (fromAddr[fromOffset] << 24) | (fromAddr[fromOffset + 1] << 16) |
                (fromAddr[fromOffset + 2] << 8) | fromAddr[fromOffset + 3];
            };
            break;
        }
            
        default:
            NSLog(@"Cannot convert image to Pix with bpp = %d", bpp); // LCOV_EXCL_LINE
    }
    
    if (copyBlock) {
        switch (image.imageOrientation) {
            case UIImageOrientationUp:
                // Maintain byte order consistency across different endianness.
                for (int y = 0; y < height; ++y, pixels += bytesPerRow, data += wpl) {
                    for (int x = 0; x < width; ++x) {
                        copyBlock(data, x, pixels, x * bytesPerPixel);
                    }
                }
                break;
                
            case UIImageOrientationUpMirrored:
                // Maintain byte order consistency across different endianness.
                for (int y = 0; y < height; ++y, pixels += bytesPerRow, data += wpl) {
                    int maxX = width - 1;
                    for (int x = maxX; x >= 0; --x) {
                        copyBlock(data, maxX - x, pixels, x * bytesPerPixel);
                    }
                }
                break;
                
            case UIImageOrientationDown:
                // Maintain byte order consistency across different endianness.
                pixels += (height - 1) * bytesPerRow;
                for (int y = height - 1; y >= 0; --y, pixels -= bytesPerRow, data += wpl) {
                    int maxX = width - 1;
                    for (int x = maxX; x >= 0; --x) {
                        copyBlock(data, maxX - x, pixels, x * bytesPerPixel);
                    }
                }
                break;
                
            case UIImageOrientationDownMirrored:
                // Maintain byte order consistency across different endianness.
                pixels += (height - 1) * bytesPerRow;
                for (int y = height - 1; y >= 0; --y, pixels -= bytesPerRow, data += wpl) {
                    for (int x = 0; x < width; ++x) {
                        copyBlock(data, x, pixels, x * bytesPerPixel);
                    }
                }
                break;
                
            case UIImageOrientationLeft:
                // Maintain byte order consistency across different endianness.
                for (int x = 0; x < height; ++x, data += wpl) {
                    int maxY = width - 1;
                    for (int y = maxY; y >= 0; --y) {
                        int x0 = y * (int)bytesPerRow + x * (int)bytesPerPixel;
                        copyBlock(data, maxY - y, pixels, x0);
                    }
                }
                break;
                
            case UIImageOrientationLeftMirrored:
                // Maintain byte order consistency across different endianness.
                for (int x = height - 1; x >= 0; --x, data += wpl) {
                    int maxY = width - 1;
                    for (int y = maxY; y >= 0; --y) {
                        int x0 = y * (int)bytesPerRow + x * (int)bytesPerPixel;
                        copyBlock(data, maxY - y, pixels, x0);
                    }
                }
                break;
                
            case UIImageOrientationRight:
                // Maintain byte order consistency across different endianness.
                for (int x = height - 1; x >=0; --x, data += wpl) {
                    for (int y = 0; y < width; ++y) {
                        int x0 = y * (int)bytesPerRow + x * (int)bytesPerPixel;
                        copyBlock(data, y, pixels, x0);
                    }
                }
                break;
                
            case UIImageOrientationRightMirrored:
                // Maintain byte order consistency across different endianness.
                for (int x = 0; x < height; ++x, data += wpl) {
                    for (int y = 0; y < width; ++y) {
                        int x0 = y * (int)bytesPerRow + x * (int)bytesPerPixel;
                        copyBlock(data, y, pixels, x0);
                    }
                }
                break;
                
            default:
                break;  // LCOV_EXCL_LINE
        }
    }
    
    pixSetYRes(pix, (l_int32)self.sourceResolution);
    
    CFRelease(imageData);
    
    return pix;
}
#elif TARGET_OS_MAC
- (Pix *)pixForImage:(NSImage *)image
{
    l_int32 width = 0;
    l_int32 height = 0;
    
    for (NSImageRep * imageRep in [image representations]) {
        if ([imageRep pixelsWide] > width) { width = (l_int32)[imageRep pixelsWide]; }
        if ([imageRep pixelsHigh] > height) { height = (l_int32)[imageRep pixelsHigh]; }
        // Representations with both width and height of 0 seem to be problematic,
        // specifically on macOS, so we just remove them.
        // TODO: Maybe this could be done in setEngineImage?
        if ([imageRep pixelsWide] == 0 && [imageRep pixelsHigh] == 0) { [image removeRepresentation:imageRep]; }
    }
    
    struct CGImage *cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
    CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    
    const UInt8 *pixels = CFDataGetBytePtr(imageData);
    
    size_t bitsPerPixel = CGImageGetBitsPerPixel(cgImage);
    size_t bytesPerPixel = bitsPerPixel / 8;
    size_t bytesPerRow = CGImageGetBytesPerRow(cgImage);
    
    int bpp = MAX(1, (int)bitsPerPixel);
    Pix *pix = pixCreate(width, height, bpp == 24 ? 32 : bpp);
    l_uint32 *data = pixGetData(pix);
    int wpl = pixGetWpl(pix);
    
    void (^copyBlock)(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) = nil;
    switch (bpp) {
            
#if 0 // BPP1 start. Uncomment this if UIImage can support 1bpp someday
            // Just a reference for the copyBlock
        case 1:
            for (int y = 0; y < height; ++y, data += wpl, pixels += bytesPerRow) {
                for (int x = 0; x < width; ++x) {
                    if (pixels[x / 8] & (0x80 >> (x % 8))) {
                        CLEAR_DATA_BIT(data, x);
                    }
                    else {
                        SET_DATA_BIT(data, x);
                    }
                }
            }
            break;
#endif // BPP1 end
            
        case 8: {
            copyBlock = ^(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) {
                SET_DATA_BYTE(toAddr, toOffset, fromAddr[fromOffset]);
            };
            break;
        }
            
#if 0 // BPP24 start. Uncomment this if UIImage can support 24bpp someday
            // Just a reference for the copyBlock
        case 24:
            // Put the colors in the correct places in the line buffer.
            for (int y = 0; y < height; ++y, pixels += bytesPerRow) {
                for (int x = 0; x < width; ++x, ++data) {
                    SET_DATA_BYTE(data, COLOR_RED, pixels[3 * x]);
                    SET_DATA_BYTE(data, COLOR_GREEN, pixels[3 * x + 1]);
                    SET_DATA_BYTE(data, COLOR_BLUE, pixels[3 * x + 2]);
                }
            }
            break;
#endif // BPP24 end
            
        case 32: {
            copyBlock = ^(l_uint32 *toAddr, NSUInteger toOffset, const UInt8 *fromAddr, NSUInteger fromOffset) {
                toAddr[toOffset] = (fromAddr[fromOffset] << 24) | (fromAddr[fromOffset + 1] << 16) |
                (fromAddr[fromOffset + 2] << 8) | fromAddr[fromOffset + 3];
            };
            break;
        }
            
        default:
            NSLog(@"Cannot convert image to Pix with bpp = %d", bpp); // LCOV_EXCL_LINE
    }
    
    // TODO: Not sure what to do here with orientation. Can we just assume that the
    // orientation will have already been sorted if its on macOS?
    if (copyBlock) {
        // Maintain byte order consistency across different endianness.
        for (int y = 0; y < height; ++y, pixels += bytesPerRow, data += wpl) {
            for (int x = 0; x < width; ++x) {
                copyBlock(data, x, pixels, x * bytesPerPixel);
            }
        }
    }
    
    pixSetYRes(pix, (l_int32)self.sourceResolution);
    
    CFRelease(imageData);
    
    return pix;
}
#endif

- (void)tesseractProgressCallbackFunction:(int)words
{
    if([self.delegate respondsToSelector:@selector(progressImageRecognitionForTesseract:)]) {
        [self.delegate progressImageRecognitionForTesseract:self];
    }
}

- (BOOL)tesseractCancelCallbackFunction:(int)words
{
    if (_monitor->ocr_alive == 1) {
        _monitor->ocr_alive = 0;
    }
    
    [self tesseractProgressCallbackFunction:words];
    
    BOOL isCancel = NO;
    if ([self.delegate respondsToSelector:@selector(shouldCancelImageRecognitionForTesseract:)]) {
        isCancel = [self.delegate shouldCancelImageRecognitionForTesseract:self];
    }
    return isCancel;
}

static bool tesseractCancelCallbackFunction(void *cancel_this, int words) {
    return [(__bridge G8Tesseract *)cancel_this tesseractCancelCallbackFunction:words];
}

@end
