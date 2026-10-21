//
//  Utils.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface Utils : NSObject

typedef NS_ENUM(int, PairState) {
    PairStateUnknown,
    PairStateUnpaired,
    PairStatePaired
};

typedef NS_ENUM(int, State) {
    StateUnknown,
    StateOffline,
    StateOnline
};

FOUNDATION_EXPORT NSString *const deviceName;

// User defaults key for the "Full" resolution setting's scale (1.0 is the
// display's own resolution). Zero or missing means a fixed resolution from
// settings is used instead of following the display.
FOUNDATION_EXPORT NSString *const matchDisplayScaleKey;

+ (NSData*) randomBytes:(NSInteger)length;
+ (NSString*) bytesToHex:(NSData*)data;
+ (NSData*) hexToBytes:(NSString*) hex;
+ (void) addHelpOptionToDialog:(UIAlertController*)dialog;
+ (BOOL) isActiveNetworkVPN;
+ (BOOL) parseAddressPortString:(NSString*)addressPort address:(NSRange*)address port:(NSRange*)port;
+ (NSString*) addressPortStringToAddress:(NSString*)addressPort;
+ (unsigned short) addressPortStringToPort:(NSString*)addressPort;
+ (NSString*) addressAndPortToAddressPortString:(NSString*)address port:(unsigned short)port;

// Returns the screen showing the given view, from its window scene.
// Falls back to the first foreground window scene if the view isn't
// in a window yet. Use this instead of [UIScreen mainScreen], which
// doesn't describe the active display on devices with more than one.
+ (UIScreen*) screenForView:(UIView*)view;

// Returns the key window of our app's foreground window scene, or that
// scene's first window if none is key. Use this instead of
// [UIApplication keyWindow], which looks across every scene, including
// the one for an external display.
+ (UIWindow*) keyWindow;

// Returns a stream resolution with the same shape as a display of the given
// size in pixels, scaled down by the given factor. Both sides are multiples
// of 8 for the host's encoder, and the size is picked so that fitting the
// video to the display leaves less than a pixel of black bars.
+ (CGSize) streamSizeForDisplaySize:(CGSize)displaySize scale:(double)scale;

#if !TARGET_OS_TV
+ (void) launchUrl:(NSString*)urlString;
#endif

@end

@interface NSString (NSStringWithTrim)

- (NSString*) trim;

@end
