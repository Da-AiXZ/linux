#import "ProbeViewController.h"
#import "ProbeController.h"

@interface ProbeViewController ()

@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *runButton;
@property (nonatomic, strong) ProbeController *probe;
@property (nonatomic, strong) NSDateFormatter *formatter;

@end

@implementation ProbeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Linux Probe";
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

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run Probe" forState:UIControlStateNormal];
    self.runButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton addTarget:self
                       action:@selector(runProbe:)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.runButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.logView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:self.runButton.topAnchor
                                                  constant:-8],

        [self.runButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.runButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.runButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                    constant:-8],
        [self.runButton.heightAnchor constraintEqualToConstant:48],
    ]];

    [self appendLog:@"Tap Run Probe. Results are printed below."];
    [self appendLog:@"Target: iPad Pro 2021 (M1), iPadOS 16.6.1."];
}

- (void)runProbe:(UIButton *)sender
{
    self.runButton.enabled = NO;
    self.logView.text = @"";
    [self appendLog:@"Starting probe..."];

    self.probe = [ProbeController new];
    __weak typeof(self) weakSelf = self;
    self.probe.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    self.probe.completionHandler = ^{
        weakSelf.runButton.enabled = YES;
    };

    if (![self.probe start]) {
        self.runButton.enabled = YES;
        [self appendLog:@"Probe did not start. See the messages above."];
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
