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

/*
 * The guest sees Documents/root as "/".
 *
 * The whole fixture tree ships in the bundle (Helpers/root) and is copied out
 * once: G3 only needed a few text files, but G4 needs the musl runtime and
 * apk's libraries at their real paths, and Documents is writable, which the
 * bundle is not -- apk will want that in G5.
 */
- (NSString *)prepareRoot:(NSString *)root
{
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *source = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Helpers/root"];
    NSMutableString *report = [NSMutableString string];
    NSError *error = nil;
    NSDirectoryEnumerator<NSString *> *walk;
    int copied = 0;
    int kept = 0;

    if (![files fileExistsAtPath:source]) {
        [self append:@"[app] no bundled rootfs; the guest gets an empty one\n"];
        return @"[app] no bundled rootfs; the guest gets an empty one\n";
    }

    walk = [files enumeratorAtPath:source];
    for (NSString *relative in walk) {
        NSString *from = [source stringByAppendingPathComponent:relative];
        NSString *to = [root stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        unsigned long long source_size;
        unsigned long long target_size = 0;
        BOOL exists;

        if (![files fileExistsAtPath:from isDirectory:&directory] || directory) {
            [files createDirectoryAtPath:to withIntermediateDirectories:YES
                              attributes:nil error:nil];
            continue;
        }
        /* -fileSize on NSDictionary returns unsigned long long, not an
         * NSNumber, so this compares numbers rather than objects. */
        source_size = [[files attributesOfItemAtPath:from error:nil] fileSize];
        exists = [files fileExistsAtPath:to];
        if (exists) {
            target_size = [[files attributesOfItemAtPath:to error:nil] fileSize];
        }
        if (exists && target_size == source_size) {
            kept++;
            continue;
        }
        [files createDirectoryAtPath:[to stringByDeletingLastPathComponent]
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:&error];
        if (![files copyItemAtPath:from toPath:to error:&error]) {
            /* Replacing an older, shorter copy is the normal case on an
             * upgrade, so remove and retry once before complaining. */
            [files removeItemAtPath:to error:nil];
            if (![files copyItemAtPath:from toPath:to error:&error]) {
                [report appendFormat:@"  %@: %@\n", relative,
                                     error.localizedDescription];
                continue;
            }
        }
        copied++;
    }
    /*
     * The report goes into the *uploaded* text as well as the screen.  0.1.5
     * printed it to the screen only, so a failed copy looked exactly like a
     * build with no G4 section -- and the log that arrived said nothing about
     * the reason.  A line that is not in the upload did not happen.
     */
    /*
     * %@ , not %s: `report` is an NSString, and %s prints the bytes of the
     * object header.  0.1.6's first device log said "18 copied, 5 already
     * present" followed by four bytes of binary rubbish -- that rubbish was
     * this, finally visible because the line reaches the upload now.
     */
    NSString *line = [NSString stringWithFormat:
        @"[app] rootfs %d copied, %d already present%@%@\n", copied, kept,
        report.length ? @"\n" : @"", report];
    [self append:line];
    return line;
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
    /*
     * The version string comes from Info.plist, the code comes from the
     * executable, and a release install replaces the first more reliably than
     * the second: 0.1.11.12 uploaded a log containing sections that only exist
     * in 0.1.10, because the plist was new and the binary was not.  A compile
     * stamp is inside the code, so the two can never disagree again.
     */
    [text appendFormat:@"[app] appbuilt=%s %s\n", __DATE__, __TIME__];
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

    [text appendString:[self prepareRoot:root]];

    NSDate *started = [NSDate date];
    int status = [V2Runner runGuest:elf root:root timeout:20 output:text];
    [text appendFormat:@"[app] elapsed=%.2fs status=%d\n",
                       -[started timeIntervalSinceNow], status];
    [self append:text];

    /*
     * G3: the same six applets CI runs, on the device.  Each one is its own
     * helper process -- the guest has no fork yet -- so the loop is six
     * spawns, each with the ptrace handshake.
     */
    NSString *busybox = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Helpers/busybox"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:busybox]) {
        NSArray<NSArray<NSString *> *> *commands = @[
            @[@"ls", @"/"],
            @[@"cat", @"/etc/motd"],
            @[@"uname", @"-a"],
            @[@"ls", @"-l", @"/hello.txt"],
            @[@"id"],
            @[@"pwd"],
        ];
        /*
         * Everything the applets print goes into the *uploaded* text as well
         * as the screen.  0.1.3 uploaded only the hello section, so the log
         * that arrived said nothing about the six commands that had just run.
         */
        [text appendString:@"\n=== busybox ===\n"];
        [self append:@"\n=== busybox ===\n"];
        for (NSArray<NSString *> *command in commands) {
            NSString *header = [NSString stringWithFormat:@"\n$ busybox %@\n",
                                [command componentsJoinedByString:@" "]];
            NSMutableString *piece = [NSMutableString string];
            int command_status;

            [text appendString:header];
            [self append:header];
            command_status = [V2Runner runGuest:busybox root:root args:command
                                        timeout:20 output:piece];
            [text appendString:piece];
            [text appendFormat:@"[app] busybox %@ status=%d\n",
                                command.firstObject, command_status];
            [self append:piece];
        }
    }

    /*
     * G4: the same two checks CI runs.  `busybox` here is the *dynamic*
     * build from the rootfs, so this only works if PT_INTERP was honoured,
     * ld.so found libc through our openat/mmap, and the interpreter
     * relocated it -- apk adds libapk, libcrypto, libssl and libz on top.
     */
    NSString *dynamicRoot = root;
    NSString *dynamicBusybox = [root stringByAppendingPathComponent:@"bin/busybox"];
    NSString *apk = [root stringByAppendingPathComponent:@"sbin/apk"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:apk]) {
        /*
         * 0.1.5 reached the device, ran all six applets and then skipped this
         * whole section without a word: the Documents copy was missing
         * sbin/apk, and the check was an `if` with no `else`.  The bundle root
         * is read-only, which `apk --version` does not mind, so it is a
         * perfectly good fallback -- and if that is missing too, say so in the
         * upload instead of disappearing.
         */
        NSString *bundleRoot = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@"Helpers/root"];
        dynamicRoot = bundleRoot;
        dynamicBusybox = [bundleRoot stringByAppendingPathComponent:@"bin/busybox"];
        apk = [bundleRoot stringByAppendingPathComponent:@"sbin/apk"];
        NSString *note = @"[app] Documents root has no sbin/apk; using the bundle root\n";
        [text appendString:note];
        [self append:note];
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:apk]) {
        NSArray<NSDictionary *> *dynamic = @[
            @{@"title": @"dynamic busybox echo",
              @"path": dynamicBusybox,
              @"args": @[@"echo", @"dynamic-busybox-ok"]},
            @{@"title": @"apk --version",
              @"path": apk,
              @"args": @[@"--version"]},
        ];

        [text appendString:@"\n=== dynamic ===\n"];
        [self append:@"\n=== dynamic ===\n"];
        for (NSDictionary *one in dynamic) {
            NSString *header = [NSString stringWithFormat:@"\n$ %@\n",
                                one[@"title"]];
            NSMutableString *piece = [NSMutableString string];
            int dynamic_status;

            [text appendString:header];
            [self append:header];
            dynamic_status = [V2Runner runGuest:one[@"path"] root:dynamicRoot
                                           args:one[@"args"] timeout:30
                                         output:piece];
            [text appendString:piece];
            [text appendFormat:@"[app] %@ status=%d\n", one[@"title"],
                                dynamic_status];
            [self append:piece];
        }

        /*
         * One launch, one comparison.  0.1.10 settled that the failure is
         * layout sensitive rather than a rate: with V2_VERIFY off it fails 197
         * of 200, with it on it fails 1 of 200 -- the check's 4 MB moves every
         * library, so it was hiding the bug rather than observing it.
         *
         * So the question is no longer "how often" but "which change to the
         * layout moves it".  Three groups, ten shots each, one variable apart:
         *
         *   baseline  no verify, no guard   expect ~10 of 10 to fail
         *   guard     no verify, V2_GUARD=1 the experiment: one empty page
         *             after every mapping.  If some code writes past the end
         *             of a mapping, that write now faults and the log says
         *             `GUARD PAGE` with the pc that did it.  If instead the
         *             failures vanish with no guard hit, nothing was written
         *             out of bounds and the trigger is the adjacency itself.
         *   control   verify on, no guard   the quiet configuration; ~0
         *             failures here means the build is sane.
         */
        NSString *apkPath = apk;
        NSString *apkRoot = dynamicRoot;
        __block int lastStatus = 0;
        NSString *(^oneShot)(void) = ^NSString *{
            NSMutableString *piece = [NSMutableString string];
            lastStatus = [V2Runner runGuest:apkPath root:apkRoot
                                       args:@[@"--version"] timeout:30
                                     output:piece];
            return piece;
        };
        struct {
            const char *name;
            int verify;
            int guard;
        } groups[3] = {
            {"baseline: no verify, no guard", 0, 0},
            {"guard: no verify, V2_GUARD=1", 0, 1},
            {"control: verify on", 1, 0},
        };

        for (int group = 0; group < 3; group++) {
            int passed = 0;
            int failed = 0;
            NSString *header = [NSString stringWithFormat:@"\n=== %s (x10) ===\n",
                                groups[group].name];

            if (groups[group].verify) {
                unsetenv("V2_NO_VERIFY");
            } else {
                setenv("V2_NO_VERIFY", "1", 1);
            }
            if (groups[group].guard) {
                setenv("V2_GUARD", "1", 1);
            } else {
                unsetenv("V2_GUARD");
            }
            [text appendString:header];
            [self append:header];
            for (int attempt = 0; attempt < 10; attempt++) {
                NSString *piece = oneShot();
                if (lastStatus == 0 &&
                    [piece rangeOfString:@"apk-tools"].location != NSNotFound) {
                    passed++;
                } else {
                    failed++;
                    [text appendFormat:@"\n--- %s shot %d status=%d ---\n%@",
                                        groups[group].name, attempt + 1,
                                        lastStatus, piece];
                }
            }
            {
                NSString *summary = [NSString stringWithFormat:
                    @"[app] %s passed=%d failed=%d\n", groups[group].name,
                    passed, failed];
                [text appendString:summary];
                [self append:summary];
            }
        }
        unsetenv("V2_GUARD");
        unsetenv("V2_NO_VERIFY");
    } else {
        NSString *note = [NSString stringWithFormat:
            @"[app] G4 skipped: no apk at %@\n", apk];
        [text appendString:note];
        [self append:note];
    }

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
