#import "JobCell.h"
#import "InstallManager.h"
#import "IOS6Theme.h"

@interface JobCell ()
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@end

@implementation JobCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleBlue;
        self.contentView.clipsToBounds = YES;

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont boldSystemFontOfSize:14];
        _nameLabel.textColor = [IOS6Theme titleColor];
        _nameLabel.numberOfLines = 1;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _nameLabel.backgroundColor = [UIColor clearColor];
        // iOS 6 etched text effect (1px light shadow below) — disabled on dark themes.
        _nameLabel.shadowColor = [IOS6Theme embossShadowColor];
        _nameLabel.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:_nameLabel];

        _messageLabel = [[UILabel alloc] init];
        _messageLabel.font = [UIFont systemFontOfSize:11];
        _messageLabel.textColor = [IOS6Theme labelGray];
        _messageLabel.numberOfLines = 2;
        _messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _messageLabel.backgroundColor = [UIColor clearColor];
        _messageLabel.shadowColor = [IOS6Theme embossShadowColor];
        _messageLabel.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:_messageLabel];

        _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        [self.contentView addSubview:_progressBar];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat pad = 12;
    CGFloat w = b.size.width - pad * 2;
    _nameLabel.frame = CGRectMake(pad, 6, w, 16);
    _messageLabel.frame = CGRectMake(pad, 24, w, 28);
    _progressBar.frame = CGRectMake(pad, b.size.height - 14, w, 9);
}

- (void)configureWithJob:(InstallJob *)job {
    self.backgroundColor = [IOS6Theme cellColor];   // white on default, raised dark on dark themes
    self.nameLabel.textColor = [IOS6Theme titleColor];
    self.nameLabel.shadowColor = [IOS6Theme embossShadowColor];
    self.messageLabel.shadowColor = [IOS6Theme embossShadowColor];
    self.nameLabel.text = job.name;
    BOOL dk = [IOS6Theme isDark];

    // "Queued" = waiting its turn (past the simultaneous-download limit). Make it OBVIOUS it's
    // waiting on purpose, not stalled: NO progress bar (a 0% bar reads as "stuck"), a muted grey
    // label, and no "%". Downloading jobs (below) keep the blue bar + live % + ETA.
    if ([job.state isEqualToString:@"queued"]) {
        self.messageLabel.text = job.message ?: @"";
        self.messageLabel.textColor = [IOS6Theme labelGray];
        self.progressBar.hidden = YES;
        return;
    }
    self.progressBar.hidden = NO;
    // Dark-aware track (the default groove is near-white → glares in dark mode).
    self.progressBar.trackTintColor = dk ? [UIColor colorWithWhite:0.30 alpha:1.0]
                                          : [UIColor colorWithWhite:0.82 alpha:1.0];

    NSString *etaStr = @"";
    if (job.bytesPerSec > 0 && job.totalBytes > 0 && job.currentBytes < job.totalBytes &&
        [job.state isEqualToString:@"downloading"]) {
        long long remaining = job.totalBytes - job.currentBytes;
        double secs = remaining / job.bytesPerSec;
        if (secs < 60) etaStr = [NSString stringWithFormat:@"  •  %.0fs", secs];
        else if (secs < 3600) etaStr = [NSString stringWithFormat:@"  •  %.0fm%02ds",
                                          floor(secs/60), (int)secs % 60];
        else etaStr = [NSString stringWithFormat:@"  •  %.1fh", secs/3600];

        double mbps = job.bytesPerSec / (1024.0 * 1024);
        etaStr = [etaStr stringByAppendingFormat:@" @ %.1f MB/s", mbps];
    }
    NSString *detail = [NSString stringWithFormat:@"%@  •  %ld%%%@",
                          job.message ?: job.state, (long)job.progress, etaStr];
    self.messageLabel.text = detail;
    self.progressBar.progress = MAX(0, MIN(1, job.progress / 100.0));

    if ([job.state isEqualToString:@"completed"]) {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.22 alpha:1.0];
        self.messageLabel.textColor = dk ? [UIColor colorWithRed:0.42 green:0.82 blue:0.48 alpha:1.0]
                                          : [UIColor colorWithRed:0.10 green:0.45 blue:0.10 alpha:1.0];
    } else if ([job.state isEqualToString:@"failed"]) {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0];
        self.messageLabel.textColor = dk ? [UIColor colorWithRed:0.96 green:0.46 blue:0.46 alpha:1.0]
                                          : [UIColor colorWithRed:0.65 green:0.10 blue:0.10 alpha:1.0];
    } else if ([job.state isEqualToString:@"cancelled"]) {
        // Orange: not an error, but the download isn't going to finish.
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.95 green:0.60 blue:0.10 alpha:1.0];
        self.messageLabel.textColor = dk ? [UIColor colorWithRed:0.98 green:0.72 blue:0.34 alpha:1.0]
                                          : [UIColor colorWithRed:0.65 green:0.40 blue:0.05 alpha:1.0];
    } else {
        self.progressBar.progressTintColor = [UIColor colorWithRed:0.22 green:0.47 blue:0.85 alpha:1.0];
        self.messageLabel.textColor = [IOS6Theme labelGray];
    }
}

@end
