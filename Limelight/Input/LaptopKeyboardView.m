//
//  LaptopKeyboardView.m
//  Moonlight
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

#import "LaptopKeyboardView.h"
#include <Limelight.h>

typedef NS_ENUM(NSInteger, LaptopKeyKind) {
    LaptopKeyKindNormal,
    LaptopKeyKindModifier,
    // Switches the number row to F1-F12, and isn't sent to the host
    LaptopKeyKindFn,
};

// Win32 VK_* codes, which is what the host expects
// https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
@interface LaptopKey : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *shiftedLabel;
@property (nonatomic) short keyCode;
@property (nonatomic, copy) NSString *fnLabel;
@property (nonatomic) short fnKeyCode;
@property (nonatomic) CGFloat width;
@property (nonatomic) LaptopKeyKind kind;
@property (nonatomic) char modifierFlag;

@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UILabel *titleLabel;

// What's held on the host for this key right now (0 if nothing)
@property (nonatomic) short sentKeyCode;
@property (nonatomic) BOOL touched;
// A modifier that was tapped by itself stays down for the next key
@property (nonatomic) BOOL latched;
@property (nonatomic) BOOL usedWhileHeld;
@end

@implementation LaptopKey
@end

static const CGFloat kRowUnits = 15;
static const CGFloat kKeySpacing = 5;

@implementation LaptopKeyboardView {
    NSArray<NSArray<LaptopKey *> *> *_rows;
    NSMapTable<UITouch *, LaptopKey *> *_touchedKeys;
    UIImpactFeedbackGenerator *_feedback;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        _touchedKeys = [NSMapTable weakToStrongObjectsMapTable];
        _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [self buildKeys];
    }
    return self;
}

- (LaptopKey *)key:(NSString *)label shifted:(NSString *)shiftedLabel code:(short)keyCode width:(CGFloat)width
{
    LaptopKey *key = [[LaptopKey alloc] init];
    key.label = label;
    key.shiftedLabel = shiftedLabel;
    key.keyCode = keyCode;
    key.width = width;
    key.kind = LaptopKeyKindNormal;
    return key;
}

- (LaptopKey *)key:(NSString *)label code:(short)keyCode width:(CGFloat)width
{
    return [self key:label shifted:nil code:keyCode width:width];
}

- (LaptopKey *)modifier:(NSString *)label code:(short)keyCode flag:(char)flag width:(CGFloat)width
{
    LaptopKey *key = [self key:label code:keyCode width:width];
    key.kind = LaptopKeyKindModifier;
    key.modifierFlag = flag;
    return key;
}

- (NSArray<LaptopKey *> *)lettersFrom:(NSString *)letters
{
    NSMutableArray *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < letters.length; i++) {
        unichar c = [letters characterAtIndex:i];
        NSString *label = [NSString stringWithCharacters:&c length:1];
        [keys addObject:[self key:label shifted:label.uppercaseString code:(short)toupper(c) width:1]];
    }
    return keys;
}

- (void)buildKeys
{
    // Number row, which becomes F1-F12 while Fn is down
    NSMutableArray *numberRow = [NSMutableArray arrayWithObject:[self key:@"esc" code:0x1B width:1]];
    NSString *digits = @"1234567890", *symbols = @"!@#$%^&*()";
    for (NSUInteger i = 0; i < digits.length; i++) {
        unichar d = [digits characterAtIndex:i], s = [symbols characterAtIndex:i];
        LaptopKey *key = [self key:[NSString stringWithCharacters:&d length:1]
                           shifted:[NSString stringWithCharacters:&s length:1]
                              code:(short)d
                             width:1];
        key.fnLabel = [NSString stringWithFormat:@"F%lu", (unsigned long)i + 1];
        key.fnKeyCode = (short)(0x70 + i);
        [numberRow addObject:key];
    }
    LaptopKey *minus = [self key:@"-" shifted:@"_" code:0xBD width:1];
    minus.fnLabel = @"F11";
    minus.fnKeyCode = 0x7A;
    LaptopKey *equals = [self key:@"=" shifted:@"+" code:0xBB width:1];
    equals.fnLabel = @"F12";
    equals.fnKeyCode = 0x7B;
    LaptopKey *backspace = [self key:@"⌫" code:0x08 width:2];
    backspace.fnLabel = @"del";
    backspace.fnKeyCode = 0x2E;
    [numberRow addObjectsFromArray:@[minus, equals, backspace]];

    NSMutableArray *topRow = [NSMutableArray arrayWithObject:[self key:@"tab" code:0x09 width:1.5]];
    [topRow addObjectsFromArray:[self lettersFrom:@"qwertyuiop"]];
    [topRow addObjectsFromArray:@[[self key:@"[" shifted:@"{" code:0xDB width:1],
                                  [self key:@"]" shifted:@"}" code:0xDD width:1],
                                  [self key:@"\\" shifted:@"|" code:0xDC width:1.5]]];

    LaptopKey *fn = [self key:@"fn" code:0 width:1.75];
    fn.kind = LaptopKeyKindFn;
    NSMutableArray *homeRow = [NSMutableArray arrayWithObject:fn];
    [homeRow addObjectsFromArray:[self lettersFrom:@"asdfghjkl"]];
    [homeRow addObjectsFromArray:@[[self key:@";" shifted:@":" code:0xBA width:1],
                                   [self key:@"'" shifted:@"\"" code:0xDE width:1],
                                   [self key:@"return" code:0x0D width:2.25]]];

    NSMutableArray *bottomRow = [NSMutableArray arrayWithObject:[self modifier:@"shift" code:0xA0 flag:MODIFIER_SHIFT width:2.25]];
    [bottomRow addObjectsFromArray:[self lettersFrom:@"zxcvbnm"]];
    [bottomRow addObjectsFromArray:@[[self key:@"," shifted:@"<" code:0xBC width:1],
                                     [self key:@"." shifted:@">" code:0xBE width:1],
                                     [self key:@"/" shifted:@"?" code:0xBF width:1],
                                     [self modifier:@"shift" code:0xA1 flag:MODIFIER_SHIFT width:2.75]]];

    NSArray *spaceRow = @[[self modifier:@"ctrl" code:0xA2 flag:MODIFIER_CTRL width:1.5],
                          [self modifier:@"win" code:0x5B flag:MODIFIER_META width:1.25],
                          [self modifier:@"alt" code:0xA4 flag:MODIFIER_ALT width:1.25],
                          [self key:@"`" shifted:@"~" code:0xC0 width:1],
                          [self key:@"" code:0x20 width:6],
                          [self key:@"←" code:0x25 width:1],
                          [self key:@"↑" code:0x26 width:1],
                          [self key:@"↓" code:0x28 width:1],
                          [self key:@"→" code:0x27 width:1]];

    _rows = @[numberRow, topRow, homeRow, bottomRow, spaceRow];

    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            key.view = [[UIView alloc] init];
            key.view.userInteractionEnabled = NO;
            key.view.layer.cornerRadius = 6;
            key.view.layer.cornerCurve = kCACornerCurveContinuous;

            key.titleLabel = [[UILabel alloc] init];
            key.titleLabel.textAlignment = NSTextAlignmentCenter;
            key.titleLabel.textColor = [UIColor whiteColor];
            key.titleLabel.adjustsFontSizeToFitWidth = YES;
            key.titleLabel.minimumScaleFactor = 0.5;
            [key.view addSubview:key.titleLabel];

            key.view.isAccessibilityElement = YES;
            key.view.accessibilityTraits = UIAccessibilityTraitKeyboardKey;
            key.view.accessibilityLabel = key.keyCode == 0x20 ? @"space" : key.label;

            [self addSubview:key.view];
        }
    }

    [self updateKeyAppearance];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    UIEdgeInsets insets = self.safeAreaInsets;
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(kKeySpacing, kKeySpacing + insets.left,
                                                                       kKeySpacing, kKeySpacing + insets.right));
    CGFloat rowHeight = (area.size.height - kKeySpacing * (_rows.count - 1)) / _rows.count;

    CGFloat fontSize = MAX(11, MIN(20, rowHeight * 0.42));

    CGFloat y = area.origin.y;
    for (NSArray<LaptopKey *> *row in _rows) {
        CGFloat available = area.size.width - kKeySpacing * (row.count - 1);
        CGFloat x = area.origin.x;
        for (LaptopKey *key in row) {
            CGFloat width = available * key.width / kRowUnits;
            key.view.frame = CGRectMake(x, y, width, rowHeight);
            key.titleLabel.frame = CGRectInset(key.view.bounds, 2, 0);
            BOOL isWord = key.label.length > 1;
            key.titleLabel.font = [UIFont systemFontOfSize:isWord ? fontSize * 0.75 : fontSize
                                                    weight:UIFontWeightRegular];
            x += width + kKeySpacing;
        }
        y += rowHeight + kKeySpacing;
    }
}

#pragma mark - Key state

- (BOOL)isKeyActive:(LaptopKey *)key
{
    return key.touched || key.latched;
}

- (BOOL)isFnActive
{
    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            if (key.kind == LaptopKeyKindFn && [self isKeyActive:key]) {
                return YES;
            }
        }
    }
    return NO;
}

- (char)activeModifierFlags
{
    char flags = 0;
    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            if (key.kind == LaptopKeyKindModifier && key.sentKeyCode != 0) {
                flags |= key.modifierFlag;
            }
        }
    }
    return flags;
}

- (void)updateKeyAppearance
{
    BOOL fnActive = [self isFnActive];
    BOOL shiftActive = ([self activeModifierFlags] & MODIFIER_SHIFT) != 0;

    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            NSString *title = key.label;
            if (fnActive && key.fnLabel != nil) {
                title = key.fnLabel;
            }
            else if (shiftActive && key.shiftedLabel != nil) {
                title = key.shiftedLabel;
            }
            key.titleLabel.text = title;

            UIColor *color;
            if (key.latched) {
                color = [UIColor systemBlueColor];
            }
            else if (key.touched) {
                color = [UIColor colorWithWhite:0.45 alpha:1.0];
            }
            else if (key.kind == LaptopKeyKindNormal && key.label.length <= 1) {
                color = [UIColor colorWithWhite:0.24 alpha:1.0];
            }
            else {
                color = [UIColor colorWithWhite:0.17 alpha:1.0];
            }
            key.view.backgroundColor = color;
        }
    }
}

- (void)sendKey:(short)keyCode down:(BOOL)down
{
    LiSendKeyboardEvent(keyCode, down ? KEY_ACTION_DOWN : KEY_ACTION_UP, [self activeModifierFlags]);
}

- (void)keyTouchedDown:(LaptopKey *)key
{
    [_feedback impactOccurred];
    key.touched = YES;
    key.usedWhileHeld = NO;

    switch (key.kind) {
        case LaptopKeyKindModifier:
        case LaptopKeyKindFn:
            if (key.latched) {
                // Tapping a latched modifier again turns it off
                [self releaseModifier:key];
                key.usedWhileHeld = YES;
                break;
            }
            if (key.kind == LaptopKeyKindModifier && key.sentKeyCode == 0) {
                key.sentKeyCode = key.keyCode;
                [self sendKey:key.keyCode down:YES];
            }
            break;

        case LaptopKeyKindNormal: {
            // Pressing a key while a modifier is held means the
            // modifier was used, so it shouldn't latch
            for (NSArray<LaptopKey *> *row in _rows) {
                for (LaptopKey *other in row) {
                    if (other.kind != LaptopKeyKindNormal && other.touched) {
                        other.usedWhileHeld = YES;
                    }
                }
            }

            short keyCode = [self isFnActive] && key.fnKeyCode != 0 ? key.fnKeyCode : key.keyCode;
            key.sentKeyCode = keyCode;
            [self sendKey:keyCode down:YES];
            break;
        }
    }

    [self updateKeyAppearance];
}

- (void)keyTouchedUp:(LaptopKey *)key
{
    key.touched = NO;

    switch (key.kind) {
        case LaptopKeyKindModifier:
        case LaptopKeyKindFn:
            if (!key.usedWhileHeld) {
                // Tapped by itself, so keep it down for the next key
                key.latched = YES;
            }
            else {
                [self releaseModifier:key];
            }
            break;

        case LaptopKeyKindNormal:
            if (key.sentKeyCode != 0) {
                [self sendKey:key.sentKeyCode down:NO];
                key.sentKeyCode = 0;
            }
            [self releaseLatchedModifiers];
            break;
    }

    [self updateKeyAppearance];
}

- (void)releaseModifier:(LaptopKey *)key
{
    if (key.kind == LaptopKeyKindModifier && key.sentKeyCode != 0) {
        short keyCode = key.sentKeyCode;
        key.sentKeyCode = 0;
        [self sendKey:keyCode down:NO];
    }
    key.latched = NO;
}

// A tapped modifier (or Fn) only applies to the next key
- (void)releaseLatchedModifiers
{
    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            if (key.latched && !key.touched) {
                [self releaseModifier:key];
            }
        }
    }
}

- (void)releaseAllKeys
{
    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            key.touched = NO;
            if (key.kind == LaptopKeyKindNormal) {
                if (key.sentKeyCode != 0) {
                    [self sendKey:key.sentKeyCode down:NO];
                    key.sentKeyCode = 0;
                }
            }
            else {
                [self releaseModifier:key];
            }
        }
    }
    [_touchedKeys removeAllObjects];
    [self updateKeyAppearance];
}

#pragma mark - Touches

- (LaptopKey *)keyAtPoint:(CGPoint)point
{
    LaptopKey *closest = nil;
    CGFloat closestDistance = CGFLOAT_MAX;

    // Pick the nearest key so touches in the gaps still land somewhere
    for (NSArray<LaptopKey *> *row in _rows) {
        for (LaptopKey *key in row) {
            CGRect frame = key.view.frame;
            CGFloat dx = MAX(0, MAX(CGRectGetMinX(frame) - point.x, point.x - CGRectGetMaxX(frame)));
            CGFloat dy = MAX(0, MAX(CGRectGetMinY(frame) - point.y, point.y - CGRectGetMaxY(frame)));
            CGFloat distance = dx * dx + dy * dy;
            if (distance < closestDistance) {
                closestDistance = distance;
                closest = key;
            }
        }
    }

    return closest;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        LaptopKey *key = [self keyAtPoint:[touch locationInView:self]];
        if (key == nil || key.touched) {
            continue;
        }
        [_touchedKeys setObject:key forKey:touch];
        [self keyTouchedDown:key];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        LaptopKey *key = [_touchedKeys objectForKey:touch];
        if (key != nil) {
            [_touchedKeys removeObjectForKey:touch];
            [self keyTouchedUp:key];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}

@end
