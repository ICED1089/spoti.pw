#import "SGDJMonitor.h"
#import "Shared/DJ/SGDJ.h"

@interface SGDJOverlapView : UIView
@property (nonatomic) CGFloat progress;
@property (nonatomic) CGFloat plannedSeconds;
@property (nonatomic) BOOL beatSync;
@property (nonatomic) CGFloat deckASeconds;
@property (nonatomic) CGFloat deckBSeconds;
@end

@implementation SGDJOverlapView
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    return self;
}
- (void)setProgress:(CGFloat)v { _progress = MAX(0, MIN(1, v)); [self setNeedsDisplay]; }
- (void)setPlannedSeconds:(CGFloat)v { _plannedSeconds = MAX(0, v); [self setNeedsDisplay]; }
- (void)setBeatSync:(BOOL)v { _beatSync = v; [self setNeedsDisplay]; }
- (void)setDeckASeconds:(CGFloat)v { _deckASeconds = MAX(0, v); [self setNeedsDisplay]; }
- (void)setDeckBSeconds:(CGFloat)v { _deckBSeconds = MAX(0, v); [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGRect b = CGRectInset(self.bounds, 6, 8);
    CGFloat laneH = 16;
    CGFloat gap = 16;
    CGFloat yA = CGRectGetMidY(b) - laneH - gap / 2;
    CGFloat yB = CGRectGetMidY(b) + gap / 2;
    CGFloat radius = laneH / 2;

    UIColor *track = [UIColor.whiteColor colorWithAlphaComponent:0.13];
    UIColor *aColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.95];
    UIColor *bColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.95];
    UIColor *mixColor = [UIColor.systemPurpleColor colorWithAlphaComponent:0.88];

    CGRect aLane = CGRectMake(CGRectGetMinX(b), yA, CGRectGetWidth(b), laneH);
    CGRect bLane = CGRectMake(CGRectGetMinX(b), yB, CGRectGetWidth(b), laneH);
    [track setFill];
    [[UIBezierPath bezierPathWithRoundedRect:aLane cornerRadius:radius] fill];
    [[UIBezierPath bezierPathWithRoundedRect:bLane cornerRadius:radius] fill];

    CGFloat overlapW = CGRectGetWidth(b) * 0.48;
    CGFloat overlapX = CGRectGetMidX(b) - overlapW / 2;
    CGRect aActive = CGRectMake(CGRectGetMinX(b), yA, overlapX + overlapW - CGRectGetMinX(b), laneH);
    CGRect bActive = CGRectMake(overlapX, yB, CGRectGetMaxX(b) - overlapX, laneH);
    [aColor setFill];
    [[UIBezierPath bezierPathWithRoundedRect:aActive cornerRadius:radius] fill];
    [bColor setFill];
    [[UIBezierPath bezierPathWithRoundedRect:bActive cornerRadius:radius] fill];

    CGRect overlap = CGRectMake(overlapX, CGRectGetMidY(b) - 5, overlapW, 10);
    [mixColor setFill];
    [[UIBezierPath bezierPathWithRoundedRect:overlap cornerRadius:5] fill];

    CGFloat playX = overlapX + overlapW * self.progress;
    CGContextSetStrokeColorWithColor(ctx, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(ctx, 2);
    CGContextMoveToPoint(ctx, playX, yA - 5);
    CGContextAddLineToPoint(ctx, playX, CGRectGetMaxY(bLane) + 5);
    CGContextStrokePath(ctx);

    if (self.beatSync) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor.whiteColor colorWithAlphaComponent:0.55].CGColor);
        CGContextSetLineWidth(ctx, 1);
        CGFloat step = MAX(14, overlapW / 8.0);
        for (CGFloat x = overlapX; x <= overlapX + overlapW + 0.5; x += step) {
            CGContextMoveToPoint(ctx, x, CGRectGetMinY(overlap) - 5);
            CGContextAddLineToPoint(ctx, x, CGRectGetMaxY(overlap) + 5);
        }
        CGContextStrokePath(ctx);
    }

    self.accessibilityLabel = [NSString stringWithFormat:@"DJ overlap %.1f seconds, %.0f percent complete%@",
        self.plannedSeconds, self.progress * 100, self.beatSync ? @", beat synced" : @""];
}
@end

static UILabel *label(UIFont *font, UIColor *color) {
    UILabel *l = [UILabel new];
    l.font = font;
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UIView *card(void) {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.08];
    v.layer.cornerRadius = 18;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    return v;
}

@interface SGDJMonitorViewController : UIViewController
@end

@implementation SGDJMonitorViewController {
    UILabel *_status;
    UILabel *_style;
    UILabel *_aTitle, *_aArtist, *_aBPM;
    UILabel *_bTitle, *_bArtist, *_bBPM;
    UILabel *_overlapText, *_syncText, *_bufferText, *_underrunText;
    SGDJOverlapView *_timeline;
    NSTimer *_timer;
}

- (void)dealloc { [_timer invalidate]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DJ Mix";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(done)];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [scroll addSubview:stack];

    _status = label([UIFont systemFontOfSize:24 weight:UIFontWeightBold], UIColor.whiteColor);
    _style = label([UIFont systemFontOfSize:13 weight:UIFontWeightSemibold], UIColor.secondaryLabelColor);
    [stack addArrangedSubview:_status];
    [stack addArrangedSubview:_style];

    UIView *a = card();
    UIView *b = card();
    [stack addArrangedSubview:a];
    [stack addArrangedSubview:b];

    _aTitle = label([UIFont systemFontOfSize:18 weight:UIFontWeightBold], UIColor.whiteColor);
    _aArtist = label([UIFont systemFontOfSize:13 weight:UIFontWeightRegular], UIColor.secondaryLabelColor);
    _aBPM = label([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold], UIColor.systemBlueColor);
    _bTitle = label([UIFont systemFontOfSize:18 weight:UIFontWeightBold], UIColor.whiteColor);
    _bArtist = label([UIFont systemFontOfSize:13 weight:UIFontWeightRegular], UIColor.secondaryLabelColor);
    _bBPM = label([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold], UIColor.systemGreenColor);

    [self fillCard:a deck:@"DECK A · NOW" title:_aTitle artist:_aArtist bpm:_aBPM];
    [self fillCard:b deck:@"DECK B · NEXT" title:_bTitle artist:_bArtist bpm:_bBPM];

    _timeline = [[SGDJOverlapView alloc] initWithFrame:CGRectZero];
    _timeline.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:_timeline];
    [_timeline.heightAnchor constraintEqualToConstant:110].active = YES;

    UIView *metrics = card();
    [stack addArrangedSubview:metrics];
    UIStackView *metricsStack = [[UIStackView alloc] init];
    metricsStack.translatesAutoresizingMaskIntoConstraints = NO;
    metricsStack.axis = UILayoutConstraintAxisVertical;
    metricsStack.spacing = 9;
    [metrics addSubview:metricsStack];
    [NSLayoutConstraint activateConstraints:@[
        [metricsStack.leadingAnchor constraintEqualToAnchor:metrics.leadingAnchor constant:16],
        [metricsStack.trailingAnchor constraintEqualToAnchor:metrics.trailingAnchor constant:-16],
        [metricsStack.topAnchor constraintEqualToAnchor:metrics.topAnchor constant:15],
        [metricsStack.bottomAnchor constraintEqualToAnchor:metrics.bottomAnchor constant:-15],
    ]];

    _overlapText = label([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium], UIColor.whiteColor);
    _syncText = label([UIFont systemFontOfSize:13 weight:UIFontWeightMedium], UIColor.whiteColor);
    _bufferText = label([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium], UIColor.secondaryLabelColor);
    _underrunText = label([UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium], UIColor.secondaryLabelColor);
    for (UILabel *l in @[_overlapText, _syncText, _bufferText, _underrunText]) [metricsStack addArrangedSubview:l];

    UILabel *note = label([UIFont systemFontOfSize:12 weight:UIFontWeightRegular], UIColor.tertiaryLabelColor);
    note.text = @"This view is live. A transition is only called V2 when both local decks are buffered and the incoming song is armed on the planned beat.";
    [stack addArrangedSubview:note];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36],
    ]];

    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.10 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    _timer.tolerance = 0.02;
}

- (void)fillCard:(UIView *)card deck:(NSString *)deck title:(UILabel *)title artist:(UILabel *)artist bpm:(UILabel *)bpm {
    UILabel *deckLabel = label([UIFont systemFontOfSize:11 weight:UIFontWeightBold], UIColor.tertiaryLabelColor);
    deckLabel.text = deck;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[deckLabel, title, artist, bpm]];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 4;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refresh {
    NSDictionary *s = SGDJMonitorSnapshot();
    if (!s.count) return;

    NSString *engine = s[@"engine"] ?: @"V2";
    NSString *status = s[@"status"] ?: @"Ready";
    _status.text = [NSString stringWithFormat:@"%@ · %@", engine, status];
    _style.text = [NSString stringWithFormat:@"%@ transition", s[@"style"] ?: @"Auto"];

    _aTitle.text = s[@"currentTitle"] ?: @"Current song";
    _aArtist.text = s[@"currentArtist"] ?: @"";
    _bTitle.text = s[@"nextTitle"] ?: @"Next song";
    _bArtist.text = s[@"nextArtist"] ?: @"";

    double aBPM = [s[@"currentBPM"] doubleValue], bBPM = [s[@"nextBPM"] doubleValue];
    double aC = [s[@"currentConfidence"] doubleValue], bC = [s[@"nextConfidence"] doubleValue];
    _aBPM.text = aBPM > 0 ? [NSString stringWithFormat:@"%.1f BPM · %.0f%% confidence", aBPM, aC * 100] : @"BPM · analyzing";
    _bBPM.text = bBPM > 0 ? [NSString stringWithFormat:@"%.1f BPM · %.0f%% confidence", bBPM, bC * 100] : @"BPM · not cached yet";

    double planned = [s[@"plannedOverlap"] doubleValue];
    double actual = [s[@"actualOverlap"] doubleValue];
    double progress = [s[@"progress"] doubleValue];
    BOOL sync = [s[@"beatSync"] boolValue];
    double wait = [s[@"syncWait"] doubleValue];
    double deckA = [s[@"deckA"] doubleValue], deckB = [s[@"deckB"] doubleValue];
    unsigned long long underruns = [s[@"underruns"] unsignedLongLongValue];

    _timeline.progress = progress;
    _timeline.plannedSeconds = planned;
    _timeline.beatSync = sync;
    _timeline.deckASeconds = deckA;
    _timeline.deckBSeconds = deckB;

    _overlapText.text = [NSString stringWithFormat:@"Overlap   planned %.2fs · buffered %.2fs · %.0f%%", planned, actual, progress * 100];
    _syncText.text = sync
        ? (wait > 0.001 ? [NSString stringWithFormat:@"Beat sync  waiting %.3fs for A downbeat", wait] : @"Beat sync  downbeat → downbeat")
        : @"Beat sync  unavailable · safe transition";
    _bufferText.text = [NSString stringWithFormat:@"Buffers   A %.2fs · B %.2fs", deckA, deckB];
    _underrunText.text = [NSString stringWithFormat:@"Underruns %llu%@", underruns, underruns ? @" · fallback may be audible" : @" · clean"];
    _underrunText.textColor = underruns ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
}

@end

UIViewController *SGDJMonitorPage(void) {
    SGDJMonitorViewController *page = [SGDJMonitorViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 24;
    }
    return nav;
}
