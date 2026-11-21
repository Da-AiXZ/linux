#import "ProbeViewController.h"
#import "ProbeController.h"
#import "GuestLauncher.h"

@interface ProbeViewController ()

@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIBarButtonItem *menuItem;
@property (nonatomic, strong) ProbeController *probe;
@property (nonatomic, strong) GuestLauncher *guestLauncher;
@property (nonatomic, strong) NSDateFormatter *formatter;
@property (nonatomic) BOOL running;

@end

@implementation ProbeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";

    self.title = [NSString stringWithFormat:@"Linux Probe %@ (%@)",
                  version, build];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.formatter = [NSDateFormatter new];
    self.formatter.dateFormat = @"HH:mm:ss";

    self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11.5
                                                   weight:UIFontWeightRegular];
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    self.menuItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                menu:[self buildActionsMenu]];
    self.menuItem.accessibilityLabel = @"Actions";
    self.navigationItem.rightBarButtonItem = self.menuItem;

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.logView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];

    [self appendLog:[NSString stringWithFormat:@"build %@ (%@)", version, build]];
    [self appendLog:@"Tap ... in the top-right corner to choose an action."];
    [self appendLog:@"Target: iPad Pro 2021 (M1), iPadOS 16.6.1."];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleProbeURL:)
                                                 name:@"ProbeURLNotification"
                                               object:nil];
}

- (UIMenu *)buildActionsMenu
{
    __weak typeof(self) weakSelf = self;

    UIAction *probe = [UIAction actionWithTitle:@"Run Probe"
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
        [weakSelf runProbe];
    }];
    UIAction *forkTest = [UIAction actionWithTitle:@"Run Fork Test"
                                             image:nil
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf runForkTest];
    }];
    UIAction *shell = [UIAction actionWithTitle:@"Run Shell"
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
        [weakSelf runShell];
    }];
    UIAction *list = [UIAction actionWithTitle:@"Run BusyBox ls -l /"
                                         image:nil
                                    identifier:nil
                                       handler:^(__kindof UIAction *action) {
        [weakSelf runList];
    }];
    UIAction *busybox = [UIAction actionWithTitle:@"Run BusyBox"
                                            image:nil
                                       identifier:nil
                                          handler:^(__kindof UIAction *action) {
        [weakSelf runBusyBox];
    }];
    UIAction *pie = [UIAction actionWithTitle:@"Run PIE Hello"
                                        image:nil
                                   identifier:nil
                                      handler:^(__kindof UIAction *action) {
        [weakSelf runPieHello];
    }];
    UIAction *alpineBusybox =
        [UIAction actionWithTitle:@"Alpine BusyBox (dynamic)"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runAlpineBusyBox];
    }];
    UIAction *apk = [UIAction actionWithTitle:@"Run APK --version"
                                        image:nil
                                   identifier:nil
                                      handler:^(__kindof UIAction *action) {
        [weakSelf runApk];
    }];
    UIAction *apkAdd = [UIAction actionWithTitle:@"Run APK Add Hello"
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *action) {
        [weakSelf runApkAdd];
    }];
    UIAction *installedHello =
        [UIAction actionWithTitle:@"Run Installed Hello"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runInstalledHello];
    }];
    UIAction *apkUpdate =
        [UIAction actionWithTitle:@"Run APK Update (network)"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runApkUpdate];
    }];
    UIAction *apkAddBash =
        [UIAction actionWithTitle:@"Install Bash (network)"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runApkAddBash];
    }];
    UIAction *bash = [UIAction actionWithTitle:@"Run Bash"
                                        image:nil
                                   identifier:nil
                                      handler:^(__kindof UIAction *action) {
        [weakSelf runBash];
    }];

    UIMenu *probeSection = [UIMenu menuWithTitle:@""
                                           image:nil
                                      identifier:nil
                                         options:UIMenuOptionsDisplayInline
                                        children:@[probe, forkTest]];
    UIMenu *staticSection = [UIMenu menuWithTitle:@""
                                            image:nil
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:@[shell, list, busybox, pie]];
    UIMenu *alpineSection = [UIMenu menuWithTitle:@""
                                            image:nil
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:@[alpineBusybox, apk, apkAdd,
                                                    installedHello, apkUpdate,
                                                    apkAddBash, bash]];

    return [UIMenu menuWithTitle:@"Linux Probe"
                       children:@[probeSection, staticSection, alpineSection]];
}

- (void)handleProbeURL:(NSNotification *)notification
{
    NSURL *url = notification.userInfo[@"url"];
    if (self.probe != nil && url != nil) {
        [self.probe handleURL:url];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)beginRunWithLabel:(NSString *)label
{
    self.running = YES;
    self.menuItem.enabled = NO;
    self.logView.text = @"";
    [self appendLog:label];
}

- (void)endRun
{
    self.running = NO;
    self.menuItem.enabled = YES;
}

- (void)runProbe
{
    if (self.running) {
        [self appendLog:@"another action is still running"];
        return;
    }
    [self beginRunWithLabel:@"Starting probe..."];

    self.probe = [ProbeController new];
    __weak typeof(self) weakSelf = self;
    self.probe.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    self.probe.completionHandler = ^{
        [weakSelf endRun];
    };

    if (![self.probe start]) {
        [self appendLog:@"Probe did not start. See the messages above."];
        [self endRun];
    }
}

- (void)runForkTest
{
    [self startGuestNamed:@"fork-test.elf"
                arguments:@[]
                    label:@"Starting fork test..."];
}

- (void)runShell
{
    NSString *command =
        @"echo '--- ls /'; ls /; "
         "echo '--- cat /etc/motd'; cat /etc/motd; "
         "echo '--- uname'; uname -a; "
         "echo '--- ls -l /'; ls -l /; "
         "echo '--- id'; id; "
         "echo '--- pwd'; pwd; "
         "echo '--- done'";
    [self startGuestNamed:@"Helpers/busybox"
                arguments:@[ @"busybox", @"sh", @"-c", command ]
                    label:@"Starting shell..."];
}

- (void)runList
{
    [self startGuestNamed:@"Helpers/busybox"
                arguments:@[ @"busybox", @"ls", @"-l", @"/" ]
                    label:@"Starting ls -l /..."];
}

- (void)runBusyBox
{
    [self startGuestNamed:@"Helpers/busybox"
                arguments:@[ @"busybox", @"uname", @"-a" ]
                    label:@"Starting BusyBox..."];
}

- (void)runPieHello
{
    [self startGuestNamed:@"Helpers/pie-hello"
                arguments:@[ @"pie-hello" ]
                    label:@"Starting PIE hello..."];
}

- (void)runAlpineBusyBox
{
    [self startGuestNamed:@"Helpers/alpine-busybox"
                arguments:@[ @"busybox", @"uname", @"-a" ]
                    label:@"Starting dynamic Alpine BusyBox..."];
}

- (void)runApk
{
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--version" ]
                    label:@"Starting apk --version..."];
}

- (void)runApkAdd
{
    /*
     * Run apk directly instead of through a guest shell.  A fork from a
     * restored child is still fragile (dynamic fork is unsupported and the
     * base scan can collide with the restored heap), and apk only needs to
     * install the local package here.
     */
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--initdb", @"add", @"--allow-untrusted",
                             @"/tmp/hello.apk" ]
                    label:@"Starting apk add --allow-untrusted /tmp/hello.apk..."];
}

- (void)runApkUpdate
{
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--allow-untrusted", @"update" ]
                    label:@"Starting apk --allow-untrusted update..."];
}

- (void)runApkAddBash
{
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--allow-untrusted", @"add", @"bash" ]
                    label:@"Starting apk --allow-untrusted add bash..."];
}

- (void)runBash
{
    NSString *bash = [[self guestRootPath]
        stringByAppendingPathComponent:@"bin/bash"];
    [self startGuestNamed:bash
                arguments:@[ @"bash", @"-c", @"echo bash ok; uname -a; id" ]
                    label:@"Starting installed /bin/bash -c ..."];
}

- (NSString *)guestRootPath
{
    NSString *temporary = NSTemporaryDirectory();
    NSString *documents = nil;
    if ([temporary containsString:@"/Containers/Data/Application/"]) {
        documents = [[temporary stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Documents"];
    }
    if (documents.length == 0) {
        documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    return [documents stringByAppendingPathComponent:@"rootfs"];
}

- (void)runInstalledHello
{
    NSString *hello = [[self guestRootPath]
        stringByAppendingPathComponent:@"usr/bin/hello"];
    [self startGuestNamed:hello
                arguments:@[ @"hello" ]
                    label:@"Starting installed /usr/bin/hello..."];
}

- (void)startGuestNamed:(NSString *)relativePath
              arguments:(NSArray<NSString *> *)arguments
                  label:(NSString *)label
{
    if (self.running) {
        [self appendLog:@"another action is still running"];
        return;
    }
    [self beginRunWithLabel:label];

    self.guestLauncher = [GuestLauncher new];
    __weak typeof(self) weakSelf = self;
    self.guestLauncher.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    self.guestLauncher.completionHandler = ^(int status) {
        [weakSelf endRun];
    };

    if (![self.guestLauncher runGuestNamed:relativePath arguments:arguments]) {
        [self endRun];
    }
}

- (void)appendLog:(NSString *)line
{
    NSString *stamp = [self.formatter stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line ?: @""];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableAttributedString *text =
            [[NSMutableAttributedString alloc] initWithAttributedString:self.logView.attributedText ?: [[NSAttributedString alloc] initWithString:@""]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:entry
                                                                     attributes:@{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5
                                                             weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: UIColor.labelColor,
        }]];
        self.logView.attributedText = text;
        [self.logView scrollRangeToVisible:NSMakeRange(text.length, 0)];
    });
}

@end
