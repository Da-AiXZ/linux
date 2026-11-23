/*
 * V2ViewController -- install it, open it, and it runs.
 *
 * The automatic path is the point: on first appearance it runs the bundled
 * guest, shows the log, uploads it and long-polls for the next command.  The
 * manual controls are still there, but folded into the "..." item at the top
 * right so the screen belongs to the log -- and so a wrong server address can
 * be fixed on the device instead of with another build.
 */
#import "V2ViewController.h"

#import "V2Remote.h"
#import "V2Runner.h"

@interface V2ViewController ()
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIBarButtonItem *menuButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) dispatch_queue_t work;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL busy;
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
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    self.menuButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showMenu:)];
    self.menuButton.accessibilityLabel = @"Actions";
    self.navigationItem.rightBarButtonItem = self.menuButton;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.logView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
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

#pragma mark - log

- (void)append:(NSString *)text
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.log appendString:text];
        self.logView.text = self.log;
        if (self.log.length > 0) {
            [self.logView scrollRangeToVisible:NSMakeRange(self.log.length - 1, 1)];
        }
    });
}

- (void)appendNow:(NSString *)text
{
    [self.log appendString:text];
    self.logView.text = self.log;
    if (self.log.length > 0) {
        [self.logView scrollRangeToVisible:NSMakeRange(self.log.length - 1, 1)];
    }
}

#pragma mark - menu

- (void)showMenu:(id)sender
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Run again"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self runTapped];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Set server address…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self askForServer];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy log"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = self.log;
        [self appendNow:@"[app] log copied\n"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share log…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self shareLog];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Clear log"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [self.log setString:@""];
        self.logView.text = @"";
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    sheet.popoverPresentationController.barButtonItem = self.menuButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)askForServer
{
    NSString *current = [V2Remote manualBaseURL] ?: [V2Remote baseURL] ?: @"";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Server address"
                         message:@"The workstation running Tools/v2_log_server.py, "
                                 @"for example 192.168.144.180:8765."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.placeholder = @"192.168.1.5:8765";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        [V2Remote setManualBaseURL:text];
        NSString *saved = [V2Remote manualBaseURL];
        [self appendNow:[NSString stringWithFormat:
            @"[app] server = %@\n", saved ?: @"automatic (discovery)"]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Use discovery"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [V2Remote setManualBaseURL:nil];
        [V2Remote reset];
        [self appendNow:@"[app] server = automatic (discovery)\n"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareLog
{
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.log ?: @""]
        applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width - 44, 44, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

#pragma mark - run

- (void)runTapped
{
    if (self.busy) {
        [self appendNow:@"[app] already running\n"];
        return;
    }
    self.busy = YES;
    [self append:@"\n=== run ===\n"];
    dispatch_async(self.work, ^{
        [self runOnce];
        self.busy = NO;
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
    [text appendFormat:@"[app] server=%@\n",
                       [V2Remote manualBaseURL] ?: [V2Remote baseURL] ?: @"(none)"];

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
    for (NSUInteger attempt = 0; attempt < delays.count; attempt++) {
        uploaded = [V2Remote upload:text build:build run:@"auto" timeout:10];
        if (uploaded != nil) {
            [self append:[NSString stringWithFormat:@"[app] uploaded id=%@\n", uploaded]];
            break;
        }
        NSString *why = [V2Remote lastFailure] ?: @"no address";
        [self append:[NSString stringWithFormat:
            @"[app] upload failed (%@)\n", why]];
        if (attempt + 1 < delays.count) {
            NSNumber *delay = delays[attempt];
            [self append:[NSString stringWithFormat:@"[app] retry in %@s\n", delay]];
            [NSThread sleepForTimeInterval:delay.doubleValue];
        }
    }
    if (uploaded == nil) {
        [self append:@"[app] gave up; log kept on device\n"];
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
