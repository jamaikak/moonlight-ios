//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "Utils.h"
#import "AppDelegate.h"
#import "LaptopKeyboardView.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;
    BOOL _connectionActive;
    BOOL _restartingStream;
    CGSize _streamViewSize;
    
    // When an external display is connected, the video goes there and
    // our own screen becomes a touchpad
    UIWindow *_externalWindow;
    UIView *_externalRenderView;
    BOOL _streamingToExternalDisplay;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
    UILabel *_touchpadLabel;
    UIButton *_keyboardButton;
    id _externalDisplayRegistration;
    int _externalDisplayWaits;
    
    // Laptop mode: when a foldable is half open with the hinge across the
    // screen, video goes above the hinge and a keyboard and touchpad below it
    id _hingeInteraction;
    BOOL _hingeKnown;
    BOOL _hingePartiallyOpen;
    BOOL _streamingInLaptopMode;
    UIView *_laptopVideoView;
    LaptopKeyboardView *_laptopKeyboard;
    CGSize _laptopVideoSize;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleMedium];
#endif
    [_spinner setColor:[UIColor whiteColor]];
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
#if !TARGET_OS_TV
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalDisplaysChanged:)
                                                 name:UISceneWillConnectNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(externalDisplaysChanged:)
                                                 name:UISceneDidDisconnectNotification
                                               object:nil];
    
#if defined(__IPHONE_27_0)
    if (@available(iOS 27.0, *)) {
        // Since iOS 27, external displays only get their own scene (instead
        // of mirroring) while a view controller asks for one
        UISceneConfiguration *configuration = [UISceneConfiguration configurationWithName:@"External Display"
                                                                              sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        configuration.delegateClass = [ExternalDisplaySceneDelegate class];
        _externalDisplayRegistration = [self registerSceneAccessory:[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:configuration]];
    }
#endif
    
    [self updateExternalDisplayExcluding:nil];
    
#if defined(__IPHONE_27_1)
    if (@available(iOS 27.1, *)) {
        __weak StreamFrameViewController *weakSelf = self;
        _hingeInteraction = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
            [weakSelf hingeUpdated:update.hinge];
        }];
        [self.view addInteraction:_hingeInteraction];
    }
#endif
#endif
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    if (_externalWindow != nil) {
        [_tipLabel setText:@"Streaming to your external display. Swipe from the left edge to disconnect."];
    }
    else {
        [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
    }
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
#if TARGET_OS_TV
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];
#else
    // Follow our own scene rather than the whole app, which stays
    // active while an external display scene is connected
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneStateChanged:)
                                                 name:UISceneWillDeactivateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneStateChanged:)
                                                 name:UISceneDidActivateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneStateChanged:)
                                                 name:UISceneDidEnterBackgroundNotification
                                               object:nil];
#endif

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    [self startFirstStream];
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
}

// Starts the stream the first time, on an external display if one is connected
- (void)startFirstStream
{
#if !TARGET_OS_TV
    // An external display's scene connects a moment after we ask for it,
    // and the display isn't listed anywhere until then. Wait briefly for it
    // rather than starting on our own screen and then restarting the stream
    // to move it over.
    // The hinge's state also arrives a moment after we're on screen.
    BOOL waitingForDisplay = _externalWindow == nil && _externalDisplayRegistration != nil;
    BOOL waitingForHinge = _hingeInteraction != nil && !_hingeKnown;
    if ((waitingForDisplay || waitingForHinge) && _externalDisplayWaits < 3) {
        _externalDisplayWaits++;
        [self performSelector:@selector(startFirstStream) withObject:nil afterDelay:0.1];
        return;
    }
    
    // Use the display's resolution instead of the one in settings when
    // streaming to an external display, or when settings ask to follow
    // our own display (which may have folded or unfolded since then)
    if (_externalWindow != nil || [self matchDisplayScale] > 0 || [self shouldUseLaptopMode]) {
        CGSize resolution = [self streamResolutionForCurrentDisplay];
        self.streamConfig.width = (int)resolution.width;
        self.streamConfig.height = (int)resolution.height;
    }
#endif
    
    [self startStream];
}

// Creates the stream view for the current stream configuration and starts
// streaming into it. This runs once on load and again when the stream is
// restarted at a new resolution after the view changes size.
- (void)startStream
{
    _streamViewSize = self.view.bounds.size;
    _streamingToExternalDisplay = _externalWindow != nil;
#if !TARGET_OS_TV
    _streamingInLaptopMode = !_streamingToExternalDisplay && [self shouldUseLaptopMode];
    BOOL touchpadMode = _streamingToExternalDisplay || _streamingInLaptopMode;
#else
    BOOL touchpadMode = NO;
#endif
    _streamView = [[StreamView alloc] initWithFrame:self.view.bounds];
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig touchpadMode:touchpadMode];
    
    UIView *renderView = _streamView;
    
    if (_streamingToExternalDisplay) {
        // Our screen is only a touchpad, so it can follow our size freely
        _streamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _streamView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        [self.view insertSubview:_streamView atIndex:0];
        
        // The video is drawn on the external display
        UIView *externalRootView = _externalWindow.rootViewController.view;
        _externalRenderView = [[UIView alloc] initWithFrame:externalRootView.bounds];
        _externalRenderView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _externalRenderView.backgroundColor = [UIColor blackColor];
        [externalRootView addSubview:_externalRenderView];
        renderView = _externalRenderView;
    }
#if !TARGET_OS_TV
    else if (_streamingInLaptopMode) {
        // The stream view is only the touchpad below the keyboard
        _streamView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
        _streamView.layer.cornerRadius = 12;
        _streamView.layer.cornerCurve = kCACornerCurveContinuous;
        [self.view insertSubview:_streamView atIndex:0];
        
        // The video is drawn above the hinge
        _laptopVideoView = [[UIView alloc] init];
        _laptopVideoView.backgroundColor = [UIColor blackColor];
        _laptopVideoView.userInteractionEnabled = NO;
        [self.view insertSubview:_laptopVideoView atIndex:0];
        renderView = _laptopVideoView;
        
        if (_laptopKeyboard == nil) {
            _laptopKeyboard = [[LaptopKeyboardView alloc] init];
        }
        [self.view addSubview:_laptopKeyboard];
        
        // The video layer is sized to its view when the stream starts
        [self layoutLaptopViews];
        _laptopVideoSize = _laptopVideoView.bounds.size;
    }
#endif
    // Only enable scroll and zoom in absolute touch mode
    else if (_settings.absoluteTouchMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view insertSubview:_scrollView atIndex:0];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view insertSubview:_streamView atIndex:0];
    }
    
#if !TARGET_OS_TV
    [self updateTouchpadControls];
#endif
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:renderView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
}

#if !TARGET_OS_TV
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // This fires when the device folds or unfolds, rotates, or our window is
    // resized by multitasking. Wait for the transition to finish so our
    // bounds reflect the new size.
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self scheduleResolutionCheck];
    }];
}

- (void)scheduleResolutionCheck
{
    // Window resizing can deliver several size changes in a row,
    // so only act once things have settled.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartStreamIfResolutionChanged) object:nil];
    [self performSelector:@selector(restartStreamIfResolutionChanged) withObject:nil afterDelay:0.5];
}

// The "Full" resolution's scale from settings, or 0 if a fixed resolution
// was chosen instead
- (double)matchDisplayScale
{
    return MIN(1.0, [[NSUserDefaults standardUserDefaults] doubleForKey:matchDisplayScaleKey]);
}

// Picks a stream resolution with the same aspect ratio as the display the
// video is shown on (our view, or the external display). On our own display
// this is the scale chosen with the "Full" setting. Otherwise it uses no more
// pixels than the resolution chosen in settings.
- (CGSize)streamResolutionForCurrentDisplay
{
    CGSize displaySize;
    CGFloat scale;
    if (_externalWindow != nil) {
        displaySize = _externalWindow.bounds.size;
        scale = _externalWindow.windowScene.screen.scale;
    }
    else {
        displaySize = self.view.bounds.size;
        
        if ([self shouldUseLaptopMode]) {
            // Only the part above the hinge shows video
            displaySize = [self laptopVideoFrame].size;
        }
        // We may still be in portrait from touchpad mode, but we'll be
        // turned to landscape before video shows on our own screen
        else if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
                 !_hingePartiallyOpen && displaySize.height > displaySize.width) {
            displaySize = CGSizeMake(displaySize.height, displaySize.width);
        }
        
        scale = self.traitCollection.displayScale;
        if (scale <= 0) {
            scale = [Utils screenForView:self.view].scale;
        }
    }
    
    double viewWidth = displaySize.width * scale;
    double viewHeight = displaySize.height * scale;
    if (viewWidth <= 0 || viewHeight <= 0) {
        return CGSizeMake(self.streamConfig.width, self.streamConfig.height);
    }
    
    double factor = [self matchDisplayScale];
    if (_externalWindow != nil || factor <= 0) {
        // This also keeps a fixed resolution's pixel count when only part
        // of our screen shows video in laptop mode
        double maxPixels = [_settings.width doubleValue] * [_settings.height doubleValue];
        factor = MIN(1.0, sqrt(maxPixels / (viewWidth * viewHeight)));
    }
    
    return [Utils streamSizeForDisplaySize:CGSizeMake(viewWidth, viewHeight) scale:factor];
}

- (void)restartStreamIfResolutionChanged
{
    if (!_connectionActive || _restartingStream) {
        // We'll check again once the current connection is up
        return;
    }
    
    BOOL useExternalDisplay = _externalWindow != nil;
    BOOL useLaptopMode = !useExternalDisplay && [self shouldUseLaptopMode];
    if (useExternalDisplay != _streamingToExternalDisplay) {
        Log(LOG_I, @"External display %s, restarting stream", useExternalDisplay ? "connected" : "disconnected");
    }
    else if (useLaptopMode != _streamingInLaptopMode) {
        Log(LOG_I, @"%s laptop mode, restarting stream", useLaptopMode ? "Entering" : "Leaving");
    }
    else {
        // While we're on an external display, our own screen is only a
        // touchpad, so its size doesn't matter
        if (useExternalDisplay) {
            return;
        }
        
        // Only react to real size changes, so a stream whose resolution doesn't
        // match the display (as chosen in settings) is left alone until then
        if (CGSizeEqualToSize(self.view.bounds.size, _streamViewSize) &&
            (!useLaptopMode || CGSizeEqualToSize([self laptopVideoFrame].size, _laptopVideoSize))) {
            return;
        }
        
        Log(LOG_I, @"View size changed, restarting stream");
    }
    
    // Restart even if the resolution comes out the same, because the stream
    // view and video layer were laid out for the old size
    _connectionActive = NO;
    _restartingStream = YES;
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    [_overlayView setHidden:YES];
    
    [_laptopKeyboard releaseAllKeys];
    
    [_stageLabel setText:useExternalDisplay != _streamingToExternalDisplay ? @"Switching displays..." : @"Resizing stream..."];
    [_stageLabel sizeToFit];
    _stageLabel.hidden = NO;
    [_spinner startAnimating];
    [self layoutStatusViews];
    
    [_streamMan stopStreamWithCompletion:^{
        // Bail if the user left the stream while we were stopping
        if (self.parentViewController == nil) {
            return;
        }
        
        [self->_scrollView removeFromSuperview];
        [self->_streamView removeFromSuperview];
        [self->_externalRenderView removeFromSuperview];
        [self->_laptopVideoView removeFromSuperview];
        [self->_laptopKeyboard removeFromSuperview];
        self->_laptopVideoView = nil;
        self->_scrollView = nil;
        self->_streamView = nil;
        self->_externalRenderView = nil;
        
        // Use whichever display we have now, in case it changed while we were stopping
        CGSize resolution = [self streamResolutionForCurrentDisplay];
        Log(LOG_I, @"Restarting stream at %dx%d (was %dx%d)",
            (int)resolution.width, (int)resolution.height, self.streamConfig.width, self.streamConfig.height);
        
        self.streamConfig.width = (int)resolution.width;
        self.streamConfig.height = (int)resolution.height;
        
        // The new session needs to hear about our controllers again
        [self->_controllerSupport resetControllerArrivals];
        
        self->_restartingStream = NO;
        [self startStream];
    }];
}

- (void)sceneStateChanged:(NSNotification *)notification
{
    if (notification.object != self.view.window.windowScene) {
        return;
    }
    
    if ([notification.name isEqualToString:UISceneWillDeactivateNotification]) {
        [self applicationWillResignActive:notification];
    }
    else if ([notification.name isEqualToString:UISceneDidActivateNotification]) {
        [self applicationDidBecomeActive:notification];
    }
    else if ([notification.name isEqualToString:UISceneDidEnterBackgroundNotification]) {
        [self applicationDidEnterBackground:notification];
    }
}

- (void)externalDisplaysChanged:(NSNotification *)notification
{
    // The disconnected scene may still be listed while this is delivered
    UIScene *goneScene = [notification.name isEqualToString:UISceneDidDisconnectNotification] ? notification.object : nil;
    
    // Let the scene finish connecting before we add our window to it
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateExternalDisplayExcluding:goneScene];
        [self scheduleResolutionCheck];
    });
}

// Finds the scene for a display other than the device's own, like one
// connected over USB-C or AirPlay
- (UIWindowScene *)findExternalDisplaySceneExcluding:(UIScene *)excludedScene
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene != excludedScene &&
            [scene isKindOfClass:[UIWindowScene class]] &&
            ![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            return (UIWindowScene *)scene;
        }
    }
    
    return nil;
}

// Creates or removes our window on the external display to match what's
// connected. Returns whether we have an external display to stream to.
- (BOOL)updateExternalDisplayExcluding:(UIScene *)excludedScene
{
    UIWindowScene *scene = [self findExternalDisplaySceneExcluding:excludedScene];
    if (_externalWindow != nil && _externalWindow.windowScene == scene) {
        return YES;
    }
    
    [self removeExternalWindow];
    if (scene == nil) {
        return NO;
    }
    
    Log(LOG_I, @"Using external display: %dx%d", (int)scene.screen.nativeBounds.size.width, (int)scene.screen.nativeBounds.size.height);
    
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    
    // Cover the placeholder that ExternalDisplaySceneDelegate shows
    window.windowLevel = UIWindowLevelNormal + 1;
    
    UIViewController *rootViewController = [[UIViewController alloc] init];
    rootViewController.view.backgroundColor = [UIColor blackColor];
    window.rootViewController = rootViewController;
    window.backgroundColor = [UIColor blackColor];
    
    // Show the window without making it key, so keyboard input
    // keeps going to the stream view on our own screen
    window.hidden = NO;
    
    _externalWindow = window;
    return YES;
}

- (void)removeExternalWindow
{
    // The video layer stays in this window until the stream restarts,
    // but nothing will see it after the window is hidden
    _externalWindow.hidden = YES;
    _externalWindow = nil;
}

- (void)updateTouchpadControls
{
    if (_touchpadLabel == nil) {
        _touchpadLabel = [[UILabel alloc] init];
        [_touchpadLabel setUserInteractionEnabled:NO];
        _touchpadLabel.text = @"Touchpad\n\nDrag to move the mouse, tap to click,\nhold to drag, two fingers to right-click or scroll.";
        _touchpadLabel.numberOfLines = 0;
        _touchpadLabel.font = [UIFont systemFontOfSize:15];
        _touchpadLabel.textAlignment = NSTextAlignmentCenter;
        _touchpadLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        [self.view addSubview:_touchpadLabel];
        
        _keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_keyboardButton setImage:[UIImage systemImageNamed:@"keyboard"] forState:UIControlStateNormal];
        _keyboardButton.tintColor = [UIColor whiteColor];
        _keyboardButton.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0];
        _keyboardButton.layer.cornerRadius = 28;
        _keyboardButton.accessibilityLabel = @"Keyboard";
        [_keyboardButton addTarget:self action:@selector(keyboardButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:_keyboardButton];
    }
    
    _touchpadLabel.hidden = !_streamingToExternalDisplay && !_streamingInLaptopMode;
    _touchpadLabel.text = _streamingInLaptopMode ?
        @"Drag to move the mouse, tap to click,\nhold to drag, two fingers to right-click or scroll." :
        @"Touchpad\n\nDrag to move the mouse, tap to click,\nhold to drag, two fingers to right-click or scroll.";
    
    // The keyboard is always shown in laptop mode
    _keyboardButton.hidden = !_streamingToExternalDisplay;
    
    [self updateSupportedOrientations];
    [self.view bringSubviewToFront:_touchpadLabel];
    [self.view bringSubviewToFront:_keyboardButton];
    [self layoutTouchpadControls];
}

- (void)updateSupportedOrientations
{
    // Allow portrait only while we're a touchpad or might be in laptop mode
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
        [[self revealViewController] setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

#if defined(__IPHONE_27_1)
- (void)hingeUpdated:(UIHinge *)hinge API_AVAILABLE(ios(27.1))
{
    BOOL partiallyOpen = hinge != nil && hinge.status == UIHingeStatusPartiallyOpen;
    _hingeKnown = YES;
    if (partiallyOpen == _hingePartiallyOpen) {
        return;
    }
    
    Log(LOG_I, @"Hinge is %s (%.0f degrees)", partiallyOpen ? "partially open" : "not partially open", hinge.angle * 180 / M_PI);
    _hingePartiallyOpen = partiallyOpen;
    
    // Let the user turn the device to portrait to type like on a laptop
    [self updateSupportedOrientations];
    [self scheduleResolutionCheck];
}
#endif

// The hinge's frame in our view while it runs across the screen, which is
// how the device sits when half open like a laptop. Returns CGRectNull otherwise.
- (CGRect)horizontalHingeFrame
{
#if defined(__IPHONE_27_1)
    if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *region in [self.view reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]]) {
            if (region.active && region.frame.size.width > region.frame.size.height) {
                return region.frame;
            }
        }
    }
#endif
    return CGRectNull;
}

- (BOOL)shouldUseLaptopMode
{
    return _externalWindow == nil && _hingePartiallyOpen && !CGRectIsNull([self horizontalHingeFrame]);
}

// Video goes above the hinge
- (CGRect)laptopVideoFrame
{
    CGRect bounds = self.view.bounds;
    CGRect hinge = [self horizontalHingeFrame];
    if (CGRectIsNull(hinge)) {
        return bounds;
    }
    
    CGFloat top = self.view.safeAreaInsets.top;
    return CGRectMake(0, top, bounds.size.width, MAX(0, CGRectGetMinY(hinge) - top));
}

// Below the hinge, the keyboard sits nearest the hinge with the touchpad
// under it, like on a laptop
- (void)layoutLaptopViews
{
    CGRect bounds = self.view.bounds;
    CGRect hinge = [self horizontalHingeFrame];
    if (CGRectIsNull(hinge)) {
        // We're leaving laptop mode, and will restart the stream shortly
        return;
    }
    
    _laptopVideoView.frame = [self laptopVideoFrame];
    
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    CGFloat lowerTop = CGRectGetMaxY(hinge);
    CGFloat lowerHeight = MAX(0, bounds.size.height - safeArea.bottom - lowerTop);
    
    // Keys get about 5mm rows at most, and the touchpad gets the rest
    CGFloat keyboardHeight = MIN(lowerHeight * 0.6, 5 * 50 + 30);
    _laptopKeyboard.frame = CGRectMake(0, lowerTop, bounds.size.width, keyboardHeight);
    
    const CGFloat margin = 12;
    _streamView.frame = CGRectMake(safeArea.left + margin,
                                   lowerTop + keyboardHeight + margin / 2,
                                   bounds.size.width - safeArea.left - safeArea.right - margin * 2,
                                   MAX(0, lowerHeight - keyboardHeight - margin * 1.5));
}

- (void)layoutTouchpadControls
{
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    
    [_touchpadLabel sizeToFit];
    if (_streamingInLaptopMode) {
        _touchpadLabel.center = CGPointMake(CGRectGetMidX(_streamView.frame), CGRectGetMidY(_streamView.frame));
    }
    else {
        _touchpadLabel.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    }
    
    const CGFloat buttonSize = 56, margin = 16;
    _keyboardButton.frame = CGRectMake(bounds.size.width - safeArea.right - margin - buttonSize,
                                       bounds.size.height - safeArea.bottom - margin - buttonSize,
                                       buttonSize, buttonSize);
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (_streamingInLaptopMode) {
        [self layoutLaptopViews];
        
        // The hinge has no notification of its own when it moves
        if (!CGSizeEqualToSize([self laptopVideoFrame].size, _laptopVideoSize)) {
            [self scheduleResolutionCheck];
        }
    }
    [self layoutTouchpadControls];
    if (_streamingToExternalDisplay || _streamingInLaptopMode) {
        // We can rotate while we're a touchpad
        [self layoutStatusViews];
    }
}

- (void)keyboardButtonPressed:(UIButton *)sender
{
    [_streamView toggleKeyboard];
}
#endif

- (void)layoutStatusViews
{
    CGRect area = self.view.bounds;
#if !TARGET_OS_TV
    if (_streamingInLaptopMode) {
        // Keep these over the video, not the keyboard
        area = [self laptopVideoFrame];
    }
#endif
    CGFloat midX = CGRectGetMidX(area), midY = CGRectGetMidY(area);
    _stageLabel.center = CGPointMake(midX, midY);
    _spinner.center = CGPointMake(midX, midY - _stageLabel.frame.size.height - _spinner.frame.size.height);
    _tipLabel.center = CGPointMake(midX, CGRectGetMinY(area) + area.size.height * 0.9);
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
#if !TARGET_OS_TV
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UISceneWillConnectNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UISceneDidDisconnectNotification object:nil];
        [self removeExternalWindow];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startFirstStream) object:nil];
#if defined(__IPHONE_27_0)
        if (@available(iOS 27.0, *)) {
            if (_externalDisplayRegistration != nil) {
                [self unregisterSceneAccessory:_externalDisplayRegistration];
                _externalDisplayRegistration = nil;
            }
        }
#endif
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    _connectionActive = NO;
#if !TARGET_OS_TV
    [_laptopKeyboard releaseAllKeys];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartStreamIfResolutionChanged) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startFirstStream) object:nil];
#endif
    
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(NSNotification *)notification {
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_connectionActive = YES;
        
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
#if !TARGET_OS_TV
        // Catch a size change that happened while we were connecting
        [self scheduleResolutionCheck];
#endif
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_connectionActive = NO;
        
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // The touchpad works in portrait too, but video on our own screen
    // stays landscape on iPhone, unless it's half open for laptop mode
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        !_streamingToExternalDisplay && !_hingePartiallyOpen) {
        return UIInterfaceOrientationMaskLandscape;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
