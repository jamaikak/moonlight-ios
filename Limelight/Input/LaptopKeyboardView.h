//
//  LaptopKeyboardView.h
//  Moonlight
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// A full keyboard drawn by the app that stays on screen, like a laptop's.
// Unlike the system keyboard, keys go down when touched and up when
// released, so they can be held (for games) and pressed together.
// Modifiers can be held with another finger, or tapped once to apply
// to the next key.
@interface LaptopKeyboardView : UIView

// Releases any keys that are still held down
- (void)releaseAllKeys;

@end

NS_ASSUME_NONNULL_END
