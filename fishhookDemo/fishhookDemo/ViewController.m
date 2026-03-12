//
//  ViewController.m
//  fishhookDemo
//
//  fishhook Demo 主界面：
//  以卡片列表展示三个 Hook 场景，每个场景可独立开启/关闭并触发测试，
//  底部日志控制台实时展示 Hook 捕获到的内容。
//

#import "ViewController.h"
#import "Demos/FHNSLogHook.h"
#import "Demos/FHMallocHook.h"
#import "Demos/FHFileHook.h"

// ─────────────────────────────────────────────────────────────
// MARK: - 数据模型
// ─────────────────────────────────────────────────────────────

typedef NS_ENUM(NSUInteger, FHDemoType) {
    FHDemoTypeNSLog = 0,
    FHDemoTypeMalloc,
    FHDemoTypeFile,
};

@interface FHDemoModel : NSObject
@property (nonatomic, assign) FHDemoType type;
@property (nonatomic, copy)   NSString  *icon;
@property (nonatomic, copy)   NSString  *title;
@property (nonatomic, copy)   NSString  *detail;
@property (nonatomic, copy)   NSString  *triggerButtonTitle;
@end

@implementation FHDemoModel
@end

// ─────────────────────────────────────────────────────────────
// MARK: - Demo 卡片 Cell
// ─────────────────────────────────────────────────────────────

@interface FHDemoCell : UITableViewCell
@property (nonatomic, strong) UILabel   *iconLabel;
@property (nonatomic, strong) UILabel   *titleLabel;
@property (nonatomic, strong) UILabel   *detailLabel;
@property (nonatomic, strong) UISwitch  *hookSwitch;
@property (nonatomic, strong) UIButton  *triggerButton;

@property (nonatomic, copy) void (^onSwitchChanged)(BOOL on);
@property (nonatomic, copy) void (^onTriggerTapped)(void);
@end

@implementation FHDemoCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.systemBackgroundColor;

    // 图标
    _iconLabel = [[UILabel alloc] init];
    _iconLabel.font = [UIFont systemFontOfSize:32];
    _iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_iconLabel];

    // 标题
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_titleLabel];

    // 描述
    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont systemFontOfSize:13];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 0;
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_detailLabel];

    // 开关
    _hookSwitch = [[UISwitch alloc] init];
    _hookSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [_hookSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_hookSwitch];

    // 触发按钮
    _triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _triggerButton.translatesAutoresizingMaskIntoConstraints = NO;
    _triggerButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _triggerButton.layer.cornerRadius = 8;
    _triggerButton.layer.borderWidth = 1;
    _triggerButton.layer.borderColor = [UIColor systemBlueColor].CGColor;
    _triggerButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    [_triggerButton addTarget:self action:@selector(triggerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_triggerButton];

    [self setupConstraints];
    return self;
}

- (void)setupConstraints {
    NSDictionary *views = @{
        @"icon":    _iconLabel,
        @"title":   _titleLabel,
        @"detail":  _detailLabel,
        @"sw":      _hookSwitch,
        @"btn":     _triggerButton,
    };

    // 图标：左边距 16，垂直居中
    [NSLayoutConstraint activateConstraints:@[
        [_iconLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_iconLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconLabel.widthAnchor constraintEqualToConstant:40],

        // 开关：右边距 16，顶部对齐
        [_hookSwitch.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_hookSwitch.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],

        // 标题：图标右侧，开关左侧
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconLabel.trailingAnchor constant:12],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_hookSwitch.leadingAnchor constant:-8],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],

        // 描述：标题下方
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],

        // 触发按钮：描述下方，左对齐
        [_triggerButton.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_triggerButton.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:10],
        [_triggerButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
    ]];
}

- (void)switchChanged:(UISwitch *)sw {
    if (self.onSwitchChanged) self.onSwitchChanged(sw.isOn);
}

- (void)triggerTapped {
    if (self.onTriggerTapped) self.onTriggerTapped();
}

@end

// ─────────────────────────────────────────────────────────────
// MARK: - ViewController
// ─────────────────────────────────────────────────────────────

@interface ViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView   *tableView;
@property (nonatomic, strong) UITextView    *logTextView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, strong) NSArray<FHDemoModel *> *demos;

@end

@implementation ViewController

// ─────────────────────────────────────────────────────────────
// MARK: - 生命周期
// ─────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"fishhook Demo";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    _logBuffer = [NSMutableString string];
    [self buildDemoModels];
    [self setupUI];
    [self setupHookCallbacks];

    [self appendLog:@"🚀 fishhook Demo 已启动，请开启上方 Hook 开关后点击「触发测试」"];
}

// ─────────────────────────────────────────────────────────────
// MARK: - 数据
// ─────────────────────────────────────────────────────────────

- (void)buildDemoModels {
    FHDemoModel *nslog = [[FHDemoModel alloc] init];
    nslog.type = FHDemoTypeNSLog;
    nslog.icon = @"🪝";
    nslog.title = @"NSLog 拦截";
    nslog.detail = @"Hook NSLogv，在每条日志前追加 [🪝 HOOK] 前缀和时间戳，\n展示 fishhook 对 ObjC 运行时日志函数的拦截能力。";
    nslog.triggerButtonTitle = @"触发 4 条测试日志";

    FHDemoModel *malloc = [[FHDemoModel alloc] init];
    malloc.type = FHDemoTypeMalloc;
    malloc.icon = @"📊";
    malloc.title = @"malloc 计数";
    malloc.detail = @"Hook malloc/free，使用原子计数器统计调用次数，\n可用于内存分配分析和泄漏检测。";
    malloc.triggerButtonTitle = @"查询当前统计";

    FHDemoModel *file = [[FHDemoModel alloc] init];
    file.type = FHDemoTypeFile;
    file.icon = @"📁";
    file.title = @"文件操作追踪";
    file.detail = @"Hook POSIX open/close 系统调用，\n实时捕获 App 沙盒内的文件打开记录（含路径和 fd）。";
    file.triggerButtonTitle = @"触发测试文件读写";

    self.demos = @[nslog, malloc, file];
}

// ─────────────────────────────────────────────────────────────
// MARK: - UI 搭建
// ─────────────────────────────────────────────────────────────

- (void)setupUI {
    // TableView：顶部 60% 区域
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.scrollEnabled = NO;
    _tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [_tableView registerClass:[FHDemoCell class] forCellReuseIdentifier:@"FHDemoCell"];
    [self.view addSubview:_tableView];

    // 日志区域标题 + 清空按钮
    UIView *logHeader = [[UIView alloc] init];
    logHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:logHeader];

    UILabel *logTitle = [[UILabel alloc] init];
    logTitle.text = @"📋  运行日志";
    logTitle.font = [UIFont boldSystemFontOfSize:14];
    logTitle.textColor = UIColor.secondaryLabelColor;
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [logHeader addSubview:logTitle];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    clearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];
    [logHeader addSubview:clearBtn];

    [NSLayoutConstraint activateConstraints:@[
        [logTitle.leadingAnchor constraintEqualToAnchor:logHeader.leadingAnchor constant:16],
        [logTitle.centerYAnchor constraintEqualToAnchor:logHeader.centerYAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:logHeader.trailingAnchor constant:-16],
        [clearBtn.centerYAnchor constraintEqualToAnchor:logHeader.centerYAnchor],
        [logHeader.heightAnchor constraintEqualToConstant:36],
    ]];

    // 日志 TextView
    _logTextView = [[UITextView alloc] init];
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _logTextView.editable = NO;
    _logTextView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _logTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    _logTextView.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    _logTextView.layer.cornerRadius = 10;
    _logTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:_logTextView];

    // Auto Layout
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // TableView：顶部到安全区域
        [_tableView.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        // 日志标题：TableView 下方
        [logHeader.topAnchor constraintEqualToAnchor:_tableView.bottomAnchor constant:4],
        [logHeader.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [logHeader.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        // 日志 TextView：标题下方，撑满剩余空间
        [_logTextView.topAnchor constraintEqualToAnchor:logHeader.bottomAnchor],
        [_logTextView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_logTextView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_logTextView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-12],
    ]];
}

// ─────────────────────────────────────────────────────────────
// MARK: - Hook 回调绑定
// ─────────────────────────────────────────────────────────────

- (void)setupHookCallbacks {
    __weak typeof(self) weak = self;

    [FHNSLogHook setLogHandler:^(NSString *log) {
        [weak appendLog:log];
    }];

    [FHMallocHook setLogHandler:^(NSString *snapshot) {
        [weak appendLog:snapshot];
    }];

    [FHFileHook setLogHandler:^(NSString *log) {
        [weak appendLog:log];
    }];
}

// ─────────────────────────────────────────────────────────────
// MARK: - 日志操作
// ─────────────────────────────────────────────────────────────

- (void)appendLog:(NSString *)message {
    NSAssert(NSThread.isMainThread, @"appendLog 必须在主线程调用");
    [_logBuffer appendFormat:@"%@\n", message];

    // 保留最近 200 行，避免 TextView 内容过大
    NSArray<NSString *> *lines = [_logBuffer componentsSeparatedByString:@"\n"];
    if (lines.count > 200) {
        NSArray *recent = [lines subarrayWithRange:NSMakeRange(lines.count - 200, 200)];
        [_logBuffer setString:[recent componentsJoinedByString:@"\n"]];
    }

    _logTextView.text = _logBuffer;
    // 自动滚动到末尾
    if (_logBuffer.length > 0) {
        NSRange end = NSMakeRange(_logTextView.text.length - 1, 1);
        [_logTextView scrollRangeToVisible:end];
    }
}

- (void)clearLog {
    [_logBuffer setString:@""];
    _logTextView.text = @"";
    [self appendLog:@"🗑  日志已清空"];
}

// ─────────────────────────────────────────────────────────────
// MARK: - UITableViewDataSource
// ─────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.demos.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FHDemoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FHDemoCell" forIndexPath:indexPath];
    FHDemoModel *model = self.demos[indexPath.row];

    cell.iconLabel.text  = model.icon;
    cell.titleLabel.text = model.title;
    cell.detailLabel.text = model.detail;
    [cell.triggerButton setTitle:model.triggerButtonTitle forState:UIControlStateNormal];

    // 同步开关状态
    BOOL isOn = [self isHookEnabledForType:model.type];
    [cell.hookSwitch setOn:isOn animated:NO];
    cell.triggerButton.enabled = isOn;
    cell.triggerButton.alpha = isOn ? 1.0 : 0.4;

    __weak typeof(self) weak = self;
    FHDemoType type = model.type;

    cell.onSwitchChanged = ^(BOOL on) {
        [weak handleSwitchChanged:on forType:type cell:cell];
    };

    cell.onTriggerTapped = ^{
        [weak handleTriggerForType:type];
    };

    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"Hook 演示场景";
}

// ─────────────────────────────────────────────────────────────
// MARK: - 交互逻辑
// ─────────────────────────────────────────────────────────────

- (BOOL)isHookEnabledForType:(FHDemoType)type {
    switch (type) {
        case FHDemoTypeNSLog:   return FHNSLogHook.isEnabled;
        case FHDemoTypeMalloc:  return FHMallocHook.isEnabled;
        case FHDemoTypeFile:    return FHFileHook.isEnabled;
    }
}

- (void)handleSwitchChanged:(BOOL)on forType:(FHDemoType)type cell:(FHDemoCell *)cell {
    switch (type) {
        case FHDemoTypeNSLog:
            on ? [FHNSLogHook enable] : [FHNSLogHook disable];
            break;
        case FHDemoTypeMalloc:
            on ? [FHMallocHook enable] : [FHMallocHook disable];
            break;
        case FHDemoTypeFile:
            on ? [FHFileHook enable] : [FHFileHook disable];
            break;
    }

    // 更新触发按钮可用状态
    cell.triggerButton.enabled = on;
    [UIView animateWithDuration:0.2 animations:^{
        cell.triggerButton.alpha = on ? 1.0 : 0.4;
    }];

    NSString *action = on ? @"已开启 ✅" : @"已关闭 ❌";
    NSString *name = self.demos[type].title;
    [self appendLog:[NSString stringWithFormat:@"⚙️  [%@] %@", name, action]];
}

- (void)handleTriggerForType:(FHDemoType)type {
    switch (type) {
        case FHDemoTypeNSLog:
            [self appendLog:@"▶️  触发 NSLog 测试..."];
            [FHNSLogHook triggerTestLogs];
            break;
        case FHDemoTypeMalloc:
            [self appendLog:@"▶️  查询 malloc 统计..."];
            [FHMallocHook triggerSnapshot];
            break;
        case FHDemoTypeFile:
            [self appendLog:@"▶️  触发文件读写测试..."];
            [FHFileHook triggerTestFileOperation];
            break;
    }
}

@end
