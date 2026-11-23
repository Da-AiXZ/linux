#import "ProbeViewController.h"
#import "ProbeController.h"
#import "GuestLauncher.h"
#import "ProbeRemote.h"

@interface ProbeViewController ()

@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIBarButtonItem *menuItem;
@property (nonatomic, strong) ProbeController *probe;
@property (nonatomic, strong) GuestLauncher *guestLauncher;
@property (nonatomic, strong) NSDateFormatter *formatter;
@property (nonatomic) BOOL running;
@property (nonatomic, strong) NSTimer *remoteTimer;
@property (nonatomic) BOOL pollingRemote;

/*
 * Log handling.  appendLog: used to rebuild the whole attributed string on
 * every line, which is O(n^2) and makes a 20-run self test unusable (tens of
 * thousands of lines).  Keep the text in a plain buffer and paint it at most
 * a few times per second.
 */
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic) BOOL renderScheduled;

/* Self test: run the same action N times and report a tally. */
@property (nonatomic) BOOL repeating;
@property (nonatomic) NSInteger repeatTotal;
@property (nonatomic) NSInteger repeatIndex;
@property (nonatomic) NSInteger repeatFailures;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *repeatFailedRuns;
@property (nonatomic) BOOL currentRunFailed;

/* Experiment knobs, persisted so the next build starts where we left off. */
@property (nonatomic, copy) NSString *zlibVariant;   /* stock | zspy | nil */
@property (nonatomic) BOOL watchState;

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

    self.logBuffer = [NSMutableString string];
    self.repeatFailedRuns = [NSMutableArray array];
    self.zlibVariant = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"zlibVariant"];
    if (self.zlibVariant.length == 0) {
        self.zlibVariant = nil;
    }

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
    [self appendLog:[NSString stringWithFormat:@"zlib variant: %@",
                                               self.zlibVariant ?: @"bundle default"]];
    [self appendLog:@"Tap ... in the top-right corner to choose an action."];
    [self appendLog:@"Target: iPad Pro 2021 (M1), iPadOS 16.6.1."];
    [self appendLog:[NSString stringWithFormat:@"remote log server: %@",
                                               [ProbeRemote baseURL]]];

    self.remoteTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                        target:self
                                                      selector:@selector(pollRemote)
                                                      userInfo:nil
                                                       repeats:YES];

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
    UIAction *apkUpdateLocal =
        [UIAction actionWithTitle:@"Run APK Update (local index)"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runApkUpdateLocal];
    }];
    UIAction *gzipCheck =
        [UIAction actionWithTitle:@"Run Gzip Check (main index)"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf runGzipCheck];
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
    UIAction *setRemote =
        [UIAction actionWithTitle:@"Set Remote URL..."
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf promptForRemoteURL];
    }];
    UIAction *uploadLog =
        [UIAction actionWithTitle:@"Upload Log Now"
                            image:nil
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
        [weakSelf uploadLogNow];
    }];

    /*
     * Experiment section.  The question these answer is binary: does the
     * failure survive when the instrumented libz is replaced by Alpine's
     * original?  One install can test both, because the runner copies the
     * selected file over <rootfs>/lib/libz.so.1 at every bootstrap.
     */
    NSString *stockTitle = [self.zlibVariant isEqualToString:@"stock"]
        ? @"zlib: stock (active)" : @"zlib: stock (baseline)";
    NSString *spyTitle = [self.zlibVariant isEqualToString:@"zspy"]
        ? @"zlib: instrumented (active)" : @"zlib: instrumented (zspy)";
    UIAction *zlibStock = [UIAction actionWithTitle:stockTitle
                                              image:nil
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        [weakSelf setZlibVariant:@"stock"];
    }];
    UIAction *zlibSpy = [UIAction actionWithTitle:spyTitle
                                            image:nil
                                       identifier:nil
                                          handler:^(__kindof UIAction *action) {
        [weakSelf setZlibVariant:@"zspy"];
    }];
    UIAction *selfTest20 = [UIAction actionWithTitle:@"Self-test: apk update x20"
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        [weakSelf startSelfTest:20];
    }];
    UIAction *selfTest10 = [UIAction actionWithTitle:@"Self-test: apk update x10"
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        [weakSelf startSelfTest:10];
    }];
    UIAction *watchRun = [UIAction actionWithTitle:@"APK Update (watch state)"
                                             image:nil
                                        identifier:nil
                                           handler:^(__kindof UIAction *action) {
        [weakSelf runApkUpdateWatched];
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
                                                    apkUpdateLocal, gzipCheck,
                                                    apkAddBash, bash]];
    UIMenu *remoteSection = [UIMenu menuWithTitle:@""
                                            image:nil
                                       identifier:nil
                                          options:UIMenuOptionsDisplayInline
                                         children:@[setRemote, uploadLog]];
    UIMenu *experimentSection = [UIMenu menuWithTitle:@"zlib experiment"
                                                image:nil
                                           identifier:nil
                                              options:0
                                             children:@[zlibStock, zlibSpy,
                                                        selfTest20, selfTest10,
                                                        watchRun]];

    return [UIMenu menuWithTitle:@"Linux Probe"
                       children:@[probeSection, staticSection, alpineSection,
                                  experimentSection, remoteSection]];
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
    [self.logBuffer setString:@""];
    self.logView.text = @"";
    [self appendLog:label];
}

- (void)setZlibVariant:(NSString *)variant
{
    _zlibVariant = [variant copy];
    [[NSUserDefaults standardUserDefaults] setObject:variant
                                              forKey:@"zlibVariant"];
    self.menuItem.menu = [self buildActionsMenu];
    [self appendLog:[NSString stringWithFormat:
        @"zlib variant -> %@ (takes effect on the next run)", variant]];
}

- (void)endRun
{
    self.running = NO;
    self.menuItem.enabled = YES;

    /*
     * Every action ends here, so this is the single place where the full log
     * is pushed to the workstation.  Nothing is written to disk: the log only
     * exists in the text view, and the server keeps the copy.
     */
    NSString *log = [self logPayload];
    if (log.length == 0 || ![ProbeRemote configured]) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [ProbeRemote uploadLog:log completion:^(NSString *status) {
        if (status.length > 0) {
            [weakSelf appendLog:status];
        }
    }];
}

- (void)promptForRemoteURL
{
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Remote log server"
                         message:@"http://<host>:8765 (IP literal, same Wi-Fi)"
                  preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [ProbeRemote baseURL];
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [ProbeRemote setBaseURL:alert.textFields.firstObject.text ?: @""];
        [weakSelf appendLog:[NSString stringWithFormat:@"remote set to %@",
                                                       [ProbeRemote baseURL]]];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/*
 * Every upload starts with the build that produced it.  beginRunWithLabel clears
 * the text view, so without this header the received log cannot be attributed
 * to a version -- which already caused one test to be run against the previous
 * build.
 */
- (NSString *)logPayload
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *header = [NSString stringWithFormat:@"===== build %@ (%@) =====\n",
                        info[@"CFBundleShortVersionString"] ?: @"?",
                        info[@"CFBundleVersion"] ?: @"?"];
    NSString *body = self.logBuffer.length != 0
        ? self.logBuffer : (self.logView.text ?: @"");
    return [header stringByAppendingString:body];
}

- (void)uploadLogNow
{
    NSString *log = [self logPayload];
    __weak typeof(self) weakSelf = self;
    [ProbeRemote uploadLog:log completion:^(NSString *status) {
        if (status.length > 0) {
            [weakSelf appendLog:status];
        }
    }];
}

/*
 * Polling keeps the loop closed: the workstation drops a command line into
 * its queue and the app runs the corresponding menu action by itself.  It is
 * paused while an action runs and while no server is configured.
 */
- (void)pollRemote
{
    if (self.running || self.repeating || self.pollingRemote ||
        ![ProbeRemote configured]) {
        return;
    }
    self.pollingRemote = YES;
    __weak typeof(self) weakSelf = self;
    [ProbeRemote pollAction:^(NSString *action) {
        weakSelf.pollingRemote = NO;
        if (action.length == 0) {
            return;
        }
        [weakSelf performRemoteAction:action];
    }];
}

- (void)performRemoteAction:(NSString *)action
{
    if (self.running || self.repeating) {
        return;
    }
    [self appendLog:[NSString stringWithFormat:@"remote command: %@", action]];

    if ([action isEqualToString:@"probe"]) {
        [self runProbe];
    } else if ([action isEqualToString:@"forkTest"]) {
        [self runForkTest];
    } else if ([action isEqualToString:@"shell"]) {
        [self runShell];
    } else if ([action isEqualToString:@"list"]) {
        [self runList];
    } else if ([action isEqualToString:@"busybox"]) {
        [self runBusyBox];
    } else if ([action isEqualToString:@"pieHello"]) {
        [self runPieHello];
    } else if ([action isEqualToString:@"alpineBusybox"]) {
        [self runAlpineBusyBox];
    } else if ([action isEqualToString:@"apkVersion"]) {
        [self runApk];
    } else if ([action isEqualToString:@"apkAddHello"]) {
        [self runApkAdd];
    } else if ([action isEqualToString:@"installedHello"]) {
        [self runInstalledHello];
    } else if ([action isEqualToString:@"apkUpdate"]) {
        [self runApkUpdate];
    } else if ([action isEqualToString:@"apkUpdateLocal"]) {
        [self runApkUpdateLocal];
    } else if ([action isEqualToString:@"gzipCheck"]) {
        [self runGzipCheck];
    } else if ([action isEqualToString:@"installBash"]) {
        [self runApkAddBash];
    } else if ([action isEqualToString:@"bash"]) {
        [self runBash];
    } else if ([action isEqualToString:@"uploadLog"]) {
        [self uploadLogNow];
    } else if ([action isEqualToString:@"selftest"]) {
        [self startSelfTest:20];
    } else if ([action isEqualToString:@"selftest10"]) {
        [self startSelfTest:10];
    } else if ([action isEqualToString:@"zlibstock"]) {
        [self setZlibVariant:@"stock"];
    } else if ([action isEqualToString:@"zlibzspy"]) {
        [self setZlibVariant:@"zspy"];
    } else if ([action isEqualToString:@"watch"]) {
        [self runApkUpdateWatched];
    } else {
        [self appendLog:@"remote command not recognised"];
    }
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
    /*
     * Keep apk's normal cache path: apk_cache_download() streams the index
     * through gunzip + tar + RSA verification before renaming it into
     * var/cache/apk, and load_index() then parses that cached file.  If the
     * signature verifies, the network delivered byte-perfect data, which
     * separates a transport problem from an index-parser problem.
     */
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--allow-untrusted", @"update" ]
                    label:@"Starting apk update (cached)..."];
}

- (NSArray<NSString *> *)localUpdateArguments
{
    return @[ @"apk", @"--allow-untrusted", @"--repositories-file",
              @"/var/localrepo/repositories", @"update" ];
}

- (GuestLauncher *)launcherForLocalUpdateWithCompletion:(void (^)(int))completion
{
    GuestLauncher *launcher = [GuestLauncher new];
    launcher.zlibVariant = self.zlibVariant;
    launcher.watchState = self.watchState;
    __weak typeof(self) weakSelf = self;
    launcher.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    launcher.completionHandler = completion;
    [launcher prepareLocalIndexRepositoryAtRoot:[self guestRootPath]];
    return launcher;
}

/* Did this run's log contain the failure we are measuring? */
- (BOOL)bufferMarksFailure
{
    NSString *text = self.logBuffer;
    if (text.length == 0) {
        return NO;
    }
    return [text containsString:@"IO ERROR"] ||
           [text containsString:@"incorrect data check"] ||
           [text containsString:@"database file format error"] ||
           [text containsString:@"[guest] signal"] ||
           [text containsString:@"out of memory"];
}

- (void)runApkUpdateLocal
{
    if (self.running) {
        [self appendLog:@"another action is still running"];
        return;
    }
    self.watchState = NO;
    [self beginRunWithLabel:@"Starting apk update (local index)..."];
    self.currentRunFailed = NO;
    __weak typeof(self) weakSelf = self;
    self.guestLauncher = [self launcherForLocalUpdateWithCompletion:^(int status) {
        [weakSelf endRun];
    }];
    if (![self.guestLauncher runGuestNamed:@"Helpers/alpine-apk"
                                 arguments:[self localUpdateArguments]]) {
        [self endRun];
    }
}

- (void)runApkUpdateWatched
{
    if (self.running) {
        [self appendLog:@"another action is still running"];
        return;
    }
    /*
     * The watchpoint needs the address of inflate_state, and only the
     * instrumented libz prints it ("[zspy] init2 ... state=0x...").  The
     * runner arms it from that line, so stock zlib cannot be watched.
     */
    if (![self.zlibVariant isEqualToString:@"zspy"]) {
        [self appendLog:@"watch needs the instrumented zlib; switching to zspy"];
        [self setZlibVariant:@"zspy"];
    }
    self.watchState = YES;
    [self beginRunWithLabel:@"Starting apk update (watching inflate_state)..."];
    self.currentRunFailed = NO;
    __weak typeof(self) weakSelf = self;
    self.guestLauncher = [self launcherForLocalUpdateWithCompletion:^(int status) {
        [weakSelf endRun];
    }];
    if (![self.guestLauncher runGuestNamed:@"Helpers/alpine-apk"
                                 arguments:[self localUpdateArguments]]) {
        [self endRun];
    }
}

- (void)startSelfTest:(NSInteger)count
{
    if (self.running) {
        [self appendLog:@"another action is still running"];
        return;
    }
    self.repeating = YES;
    self.watchState = NO;
    self.repeatTotal = count;
    self.repeatIndex = 0;
    self.repeatFailures = 0;
    [self.repeatFailedRuns removeAllObjects];
    [self appendLog:[NSString stringWithFormat:
        @"##### SELF-TEST start runs=%ld libz=%@",
        (long)count, self.zlibVariant ?: @"bundle default"]];
    [self runSelfTestIteration];
}

- (void)runSelfTestIteration
{
    if (self.repeatIndex >= self.repeatTotal) {
        NSString *failed = self.repeatFailedRuns.count != 0
            ? [self.repeatFailedRuns componentsJoinedByString:@","]
            : @"none";
        [self appendLogNow:[NSString stringWithFormat:
            @"##### SELF-TEST DONE total=%ld failed=%ld failed_runs=%@ libz=%@",
            (long)self.repeatTotal, (long)self.repeatFailures, failed,
            self.zlibVariant ?: @"bundle default"]];
        self.repeating = NO;
        [self endRun];
        return;
    }
    self.repeatIndex++;
    self.currentRunFailed = NO;
    [self beginRunWithLabel:[NSString stringWithFormat:
        @"##### RUN %ld/%ld libz=%@",
        (long)self.repeatIndex, (long)self.repeatTotal,
        self.zlibVariant ?: @"bundle default"]];
    __weak typeof(self) weakSelf = self;
    self.guestLauncher = [self launcherForLocalUpdateWithCompletion:^(int status) {
        [weakSelf finishSelfTestIterationWithStatus:status];
    }];
    if (![self.guestLauncher runGuestNamed:@"Helpers/alpine-apk"
                                 arguments:[self localUpdateArguments]]) {
        [self finishSelfTestIterationWithStatus:-1];
    }
}

- (void)finishSelfTestIterationWithStatus:(int)status
{
    /*
     * Log lines reach the buffer through dispatch_async(main); give the
     * already-queued appends a moment so the verdict sees the whole run.
     * 0.4 s is far below the ~10 s a run takes, so the cost is noise.
     */
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ProbeViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        BOOL failed = strongSelf.currentRunFailed ||
                      status != 0 ||
                      [strongSelf bufferMarksFailure];
        if (failed) {
            strongSelf.repeatFailures++;
            [strongSelf.repeatFailedRuns addObject:@(strongSelf.repeatIndex)];
        }
        [strongSelf appendLogNow:[NSString stringWithFormat:
            @"##### RUN %ld/%ld status=%d %@",
            (long)strongSelf.repeatIndex, (long)strongSelf.repeatTotal, status,
            failed ? @"FAIL" : @"PASS"]];
        [strongSelf endRun];
        if (!strongSelf.repeating) {
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [strongSelf runSelfTestIteration];
        });
    });
}

- (void)runGzipCheck
{
    /*
     * Alpine's busybox has its own inflate implementation, so this test
     * exercises the guest read path and heap on the same 8MB of index data
     * without any of apk's or zlib's buffering.  The community index is the
     * one the parser always fails on, so it is the interesting one.
     */
    [self startGuestNamed:@"Helpers/alpine-busybox"
                arguments:@[ @"busybox", @"gzip", @"-t",
                             @"/var/cache/apk/APKINDEX.7db31bb6.tar.gz" ]
                    label:@"Starting busybox gzip -t (community index)..."];
}

- (void)runApkAddBash
{
    [self startGuestNamed:@"Helpers/alpine-apk"
                arguments:@[ @"apk", @"--allow-untrusted", @"add", @"bash" ]
                    label:@"Starting apk add bash (cached)..."];
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

/*
 * Prefixes that carry no information for the "which zlib" question but
 * dominate the volume (the zspy literal/window traces).  Dropped only while
 * the self test runs, so a single manual run still has everything.
 */
- (BOOL)isNoiseLine:(NSString *)line
{
    return [line hasPrefix:@"[zl]"] || [line hasPrefix:@"[zf]"] ||
           [line hasPrefix:@"[zu]"] || [line hasPrefix:@"[zc]"] ||
           [line hasPrefix:@"[zc4]"] ||
           [line hasPrefix:@"[zmd] old="] ||
           [line hasPrefix:@"[zmd] new="];
}

- (void)appendLog:(NSString *)line
{
    if (self.repeating && [self isNoiseLine:line]) {
        return;
    }
    NSString *stamp = [self.formatter stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line ?: @""];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendString:entry];
        [self scheduleLogRender];
    });
}

/*
 * Append and paint right now, on the caller's (main) thread.  The verdict
 * lines need this: endRun uploads logPayload synchronously, so a line queued
 * with dispatch_async would be missing from the upload that is supposed to
 * carry it.
 */
- (void)appendLogNow:(NSString *)line
{
    if (self.repeating && [self isNoiseLine:line]) {
        return;
    }
    NSString *stamp = [self.formatter stringFromDate:[NSDate date]];
    [self.logBuffer appendString:
        [NSString stringWithFormat:@"[%@] %@\n", stamp, line ?: @""]];
    [self renderLog];
}

- (void)scheduleLogRender
{
    if (self.renderScheduled) {
        return;
    }
    self.renderScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf renderLog];
    });
}

- (void)renderLog
{
    self.renderScheduled = NO;
    NSString *text = self.logBuffer;
    if (text.length > 400000) {
        text = [text substringFromIndex:text.length - 400000];
    }
    if (![self.logView.text isEqualToString:text]) {
        self.logView.text = text;
        [self.logView scrollRangeToVisible:NSMakeRange(text.length, 0)];
    }
}

@end
