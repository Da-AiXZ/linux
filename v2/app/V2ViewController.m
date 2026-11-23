/*
 * V2ViewController -- install it, open it, and it runs.
 *
 * No menu, no "tap here first": on first appearance the app runs the bundled
 * guest, shows the log, uploads it, and then long-polls for the next command.
 * That is the loop in v2/docs/DEVICE-LOOP.md; anything manual defeats it.
 */
#import "V2ViewController.h"

#import "V2Remote.h"
#import "V2Runner.h"

@interface V2ViewController ()
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic) dispatch_queue_t work;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong) NSMutableString *log;
@end

@implementation V2ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"v2 probe";

    self.log = [NSMutableString string];
    self.work = dispatch_queue_create("v2.work", DISPATCH_QUEUE_SERIAL);

    self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run again" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runTapped)
             forControlEvents:UIControlEventTouchUpInside];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.runButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.logView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:self.runButton.topAnchor],
        [self.runButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.runButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.runButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.runButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.started) {
        return;
    }
    self.started = YES;
    [self runTapped];
}

- (void)append:(NSString *)text
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.log appendString:text];
        self.logView.text = self.log;
        if (self.log.length > 0) {
            NSRange end = NSMakeRange(self.log.length - 1, 1);
            [self.logView scrollRangeToVisible:end];
        }
    });
}

- (void)runTapped
{
    [self append:@"\n=== run ===\n"];
    dispatch_async(self.work, ^{
        [self runOnce];
    });
}

- (void)runOnce
{
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *build = [NSString stringWithFormat:@"%@.%@",
                       info[@"CFBundleShortVersionString"] ?: @"0",
                       info[@"CFBundleVersion"] ?: @"0"];
    NSMutableString *text = [NSMutableString string];

    [text appendFormat:@"[app] build=%@ device=%@\n", build,
                       [[UIDevice currentDevice] name]];
    [text appendFormat:@"[app] model=%@ system=%@\n",
                       [[UIDevice currentDevice] model],
                       [[UIDevice currentDevice] systemVersion]];

    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask, YES) firstObject];
    NSString *root = [documents stringByAppendingPathComponent:@"root"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *elf = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Helpers/hello"];
    [text appendFormat:@"[app] guest=%@\n", elf];

    NSDate *started = [NSDate date];
    int status = [V2Runner runGuest:elf root:root timeout:20 output:text];
    [text appendFormat:@"[app] elapsed=%.2fs status=%d\n",
                       -[started timeIntervalSinceNow], status];
    [self append:text];

    // Upload with the retry ladder from the doc: 2s, 5s, 10s.
    NSArray<NSNumber *> *delays = @[@2, @5, @10];
    NSString *uploaded = nil;
    for (NSNumber *delay in delays) {
        uploaded = [V2Remote upload:text build:build run:@"auto" timeout:15];
        if (uploaded != nil) {
            [self append:[NSString stringWithFormat:@"[app] uploaded id=%@\n", uploaded]];
            break;
        }
        [self append:[NSString stringWithFormat:@"[app] upload failed, retry in %@s\n", delay]];
        [NSThread sleepForTimeInterval:delay.doubleValue];
    }
    if (uploaded == nil) {
        [self append:@"[app] upload gave up; log kept on device\n"];
        return;
    }

    // Command loop: three rounds, ~25s each, then stop.  A new command can be
    // queued on the workstation at any time; the app picks it up here.
    for (int round = 0; round < 3; round++) {
        NSDictionary *command = [V2Remote nextCommandWithWait:25];
        NSString *action = command[@"action"];
        if (![action isKindOfClass:[NSString class]]) {
            continue;
        }
        [self append:[NSString stringWithFormat:@"[app] command=%@\n", command]];
        if ([action isEqualToString:@"run"]) {
            NSMutableString *again = [NSMutableString string];
            [V2Runner runGuest:elf root:root timeout:20 output:again];
            [self append:again];
            [V2Remote upload:again build:build run:@"cmd" timeout:15];
        }
        [V2Remote ack:@{@"id": @(round), @"status": @(0)}];
    }
    [self append:@"[app] loop idle\n"];
}

@end
