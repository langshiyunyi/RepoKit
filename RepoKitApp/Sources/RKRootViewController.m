#import "RKRootViewController.h"
#import "RKHelperClient.h"
#import <roothide.h>

static NSString * const RKDataDidChangeNotification = @"RKDataDidChangeNotification";

static NSString *RKLoc(NSString *key) {
    NSString *value = NSLocalizedString(key, nil);
    return value.length ? value : key;
}

static NSString *RKStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return @"";
}

static NSString *RKTrimmedFormValue(id value) {
    return [RKStringValue(value) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void RKAddOptionIfNotEmpty(NSMutableArray<NSString *> *args, NSString *option, id value) {
    NSString *trimmed = RKTrimmedFormValue(value);
    if (!option.length || !trimmed.length) return;
    [args addObject:option];
    [args addObject:trimmed];
}

static UIImage *RKSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) return [UIImage systemImageNamed:name];
    return nil;
}

static UITableViewCell *RKCell(UITableView *tableView, NSString *title, NSString *detail, NSString *symbol, UITableViewCellAccessoryType accessory) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = symbol.length ? RKSymbol(symbol) : nil;
    cell.imageView.tintColor = UIColor.systemBlueColor;
    cell.imageView.alpha = 1.0;
    cell.accessoryView = nil;
    cell.accessoryType = accessory;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = YES;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;
    return cell;
}

static UITableViewCell *RKSetCellEnabled(UITableViewCell *cell, BOOL enabled) {
    cell.userInteractionEnabled = enabled;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    cell.imageView.alpha = enabled ? 1.0 : 0.35;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

static void RKSetCellLoading(UITableViewCell *cell, BOOL loading) {
    if (!loading) return;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    cell.accessoryView = spinner;
}

static NSDictionary *DFControlFieldsForPackage(NSDictionary *package);
static NSArray<NSString *> *DFControlOrderForPackage(NSDictionary *package);
static NSString *DFPackageFieldTitle(NSString *key);
static BOOL DFControlFieldIsMultiline(NSString *key);

@interface DFInstalledPackagePickerVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithRepoID:(NSString *)repoID;
@end

@interface RKFormViewController : UITableViewController <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *fields;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@property (nonatomic, copy) void (^saveHandler)(NSDictionary<NSString *, NSString *> *values);
- (instancetype)initWithTitle:(NSString *)title fields:(NSArray<NSDictionary *> *)fields values:(NSDictionary *)values save:(void (^)(NSDictionary<NSString *, NSString *> *values))saveHandler;
@end

@implementation RKFormViewController

- (instancetype)initWithTitle:(NSString *)title fields:(NSArray<NSDictionary *> *)fields values:(NSDictionary *)values save:(void (^)(NSDictionary<NSString *, NSString *> *values))saveHandler {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        self.fields = fields;
        self.values = [NSMutableDictionary dictionary];
        for (NSDictionary *field in fields) {
            NSString *key = field[@"key"];
            if (key.length) self.values[key] = RKStringValue(values[key]);
        }
        self.saveHandler = saveHandler;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:RKLoc(@"Cancel") style:UIBarButtonItemStylePlain target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:RKLoc(@"Save") style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.fields.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *field = self.fields[(NSUInteger)indexPath.row];
    return [field[@"multiline"] boolValue] ? 132.0 : 82.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSDictionary *field = self.fields[(NSUInteger)indexPath.row];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = field[@"title"];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    label.adjustsFontSizeToFitWidth = YES;
    [cell.contentView addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
        [label.heightAnchor constraintEqualToConstant:20.0]
    ]];

    if ([field[@"multiline"] boolValue]) {
        UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
        textView.translatesAutoresizingMaskIntoConstraints = NO;
        textView.text = self.values[field[@"key"]] ?: @"";
        textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        textView.autocorrectionType = UITextAutocorrectionTypeNo;
        textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textView.layer.cornerRadius = 8.0;
        textView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        textView.layer.borderColor = UIColor.separatorColor.CGColor;
        textView.delegate = self;
        textView.tag = indexPath.row;
        [cell.contentView addSubview:textView];
        [NSLayoutConstraint activateConstraints:@[
            [textView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [textView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [textView.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:4.0],
            [textView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12.0]
        ]];
    } else {
        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.placeholder = field[@"placeholder"];
        textField.text = self.values[field[@"key"]] ?: @"";
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.secureTextEntry = [field[@"secure"] boolValue];
        textField.delegate = self;
        textField.tag = indexPath.row;
        [textField addTarget:self action:@selector(textFieldChanged:) forControlEvents:UIControlEventEditingChanged];
        [cell.contentView addSubview:textField];
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [textField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [textField.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:6.0],
            [textField.heightAnchor constraintEqualToConstant:36.0]
        ]];
    }
    return cell;
}

- (void)textFieldChanged:(UITextField *)textField {
    if (textField.tag < 0 || textField.tag >= (NSInteger)self.fields.count) return;
    NSString *key = self.fields[(NSUInteger)textField.tag][@"key"];
    if (key.length) self.values[key] = textField.text ?: @"";
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView.tag < 0 || textView.tag >= (NSInteger)self.fields.count) return;
    NSString *key = self.fields[(NSUInteger)textView.tag][@"key"];
    if (key.length) self.values[key] = textView.text ?: @"";
}

- (void)saveTapped {
    NSMutableArray<NSString *> *missingFields = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSDictionary *field in self.fields) {
        if (![field[@"required"] boolValue]) continue;
        NSString *key = field[@"key"];
        NSString *value = [self.values[key] stringByTrimmingCharactersInSet:whitespace];
        if (!value.length) [missingFields addObject:field[@"title"] ?: key ?: @""];
    }
    if (missingFields.count) {
        NSString *message = [NSString stringWithFormat:RKLoc(@"Please fill in required fields"), [missingFields componentsJoinedByString:@", "]];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"Required Fields") message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.saveHandler) self.saveHandler([self.values copy]);
}

@end

@interface RKBaseTableViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary *> *repos;
@property (nonatomic, strong) NSDictionary *currentRepo;
@property (nonatomic, strong) NSArray<NSDictionary *> *packages;
@property (nonatomic, copy) NSString *currentRepoID;
@property (nonatomic, copy) NSString *lastOutput;
@property (nonatomic, assign, getter=isHelperRunning) BOOL helperRunning;
- (void)refreshData;
- (void)runHelper:(NSArray<NSString *> *)arguments refresh:(BOOL)refresh;
- (void)showMessage:(NSString *)message title:(NSString *)title;
- (void)showCreateRepoForm;
- (void)showImportSourceForm;
- (void)showImportDebForm;
- (void)showImportDebPathForm;
- (void)showRepoEditor;
- (void)showGithubEditor;
- (void)showPushForm;
- (void)showPackageEditor:(NSDictionary *)package;
- (void)confirmDeleteRepo:(NSString *)repoID;
@end

@implementation RKBaseTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAutomatic;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"arrow.clockwise") style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshData) name:RKDataDidChangeNotification object:nil];
    [self refreshData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setHelperRunning:(BOOL)helperRunning {
    _helperRunning = helperRunning;
    BOOL enabled = !helperRunning;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) item.enabled = enabled;
    self.navigationItem.rightBarButtonItem.enabled = enabled;
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshData];
}

- (void)refreshData {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *repos = [[RKHelperClient sharedClient] repos];
        NSString *repoID = [[NSUserDefaults standardUserDefaults] stringForKey:@"RepoKitCurrentRepoID"];
        if (!repoID.length && repos.count) repoID = repos.firstObject[@"id"];
        NSDictionary *repo = repoID.length ? [[RKHelperClient sharedClient] repoWithID:repoID] : nil;
        if (!repo && repos.count) {
            repoID = repos.firstObject[@"id"];
            repo = [[RKHelperClient sharedClient] repoWithID:repoID];
        }
        NSArray *packages = repoID.length ? [[RKHelperClient sharedClient] packagesForRepoID:repoID] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.repos = repos ?: @[];
            self.currentRepoID = repoID;
            self.currentRepo = repo;
            self.packages = packages ?: @[];
            if (repoID.length) [[NSUserDefaults standardUserDefaults] setObject:repoID forKey:@"RepoKitCurrentRepoID"];
            [self.tableView reloadData];
        });
    });
}

- (void)runHelper:(NSArray<NSString *> *)arguments refresh:(BOOL)refresh {
    if (self.helperRunning) {
        [self showMessage:RKLoc(@"Operation in progress") title:RKLoc(@"RepoKit")];
        return;
    }
    self.lastOutput = [arguments.firstObject isEqualToString:@"add-many"] ? RKLoc(@"Importing...") : RKLoc(@"Executing...");
    self.helperRunning = YES;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        RKHelperResult *result = [[RKHelperClient sharedClient] runArguments:arguments];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastOutput = result.output.length ? result.output : RKLoc(@"Done");
            self.helperRunning = NO;
            [self showMessage:self.lastOutput title:result.exitCode == 0 ? RKLoc(@"Done") : RKLoc(@"Failed")];
            if (refresh) {
                [[NSNotificationCenter defaultCenter] postNotificationName:RKDataDidChangeNotification object:nil];
                [self refreshData];
            } else {
                [self.tableView reloadData];
            }
        });
    });
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)repoFields {
    return @[
        @{@"key": @"name", @"title": RKLoc(@"Name"), @"placeholder": @"My Repo"},
        @{@"key": @"description", @"title": RKLoc(@"Description"), @"placeholder": RKLoc(@"Personal jailbreak repository")},
        @{@"key": @"author", @"title": RKLoc(@"Author"), @"placeholder": @"DaFei"},
        @{@"key": @"baseURL", @"title": @"Base URL", @"placeholder": @"https://user.github.io/repo"},
        @{@"key": @"scheme", @"title": RKLoc(@"Scheme"), @"placeholder": @"rootless"},
        @{@"key": @"architecture", @"title": RKLoc(@"Architecture"), @"placeholder": @"iphoneos-arm64"}
    ];
}

- (void)pushForm:(RKFormViewController *)form {
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:form];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)showCreateRepoForm {
    NSMutableArray *fields = [NSMutableArray arrayWithObject:@{@"key": @"repoID", @"title": @"Repo ID", @"placeholder": @"my-repo", @"required": @YES}];
    [fields addObjectsFromArray:[self repoFields]];
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Create Source") fields:fields values:@{} save:^(NSDictionary<NSString *,NSString *> *values) {
        NSString *repoID = RKTrimmedFormValue(values[@"repoID"]);
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"init", repoID, nil];
        RKAddOptionIfNotEmpty(args, @"--name", values[@"name"]);
        RKAddOptionIfNotEmpty(args, @"--description", values[@"description"]);
        RKAddOptionIfNotEmpty(args, @"--author", values[@"author"]);
        RKAddOptionIfNotEmpty(args, @"--base-url", values[@"baseURL"]);
        RKAddOptionIfNotEmpty(args, @"--scheme", values[@"scheme"]);
        RKAddOptionIfNotEmpty(args, @"--architecture", values[@"architecture"]);
        [[NSUserDefaults standardUserDefaults] setObject:repoID forKey:@"RepoKitCurrentRepoID"];
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showImportSourceForm {
    NSArray *fields = @[
        @{@"key": @"path", @"title": RKLoc(@"Path"), @"placeholder": @"/var/mobile/Documents/my-repo", @"required": @YES}
    ];
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Import Source") fields:fields values:@{} save:^(NSDictionary<NSString *,NSString *> *values) {
        NSString *path = RKTrimmedFormValue(values[@"path"]);
        NSString *repoID = path.stringByStandardizingPath.lastPathComponent;
        if (repoID.length) [[NSUserDefaults standardUserDefaults] setObject:repoID forKey:@"RepoKitCurrentRepoID"];
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:@[@"import-source", path] refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showImportDebForm {
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:RKLoc(@"Import Deb") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Import by Path") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self showImportDebPathForm];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Import Installed Package") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self showInstalledPackageImporter];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 1.0, 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showImportDebPathForm {
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    NSArray *fields = @[@{@"key": @"path", @"title": RKLoc(@"Deb Path"), @"placeholder": @"/var/mobile/package.deb", @"required": @YES}];
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Import Deb") fields:fields values:@{} save:^(NSDictionary<NSString *,NSString *> *values) {
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:@[@"add-many", weakSelf.currentRepoID ?: @"", values[@"path"] ?: @""] refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showInstalledPackageImporter {
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    DFInstalledPackagePickerVC *picker = [[DFInstalledPackagePickerVC alloc] initWithRepoID:self.currentRepoID ?: @""];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)showRepoEditor {
    if (!self.currentRepoID.length || !self.currentRepo) return;
    NSMutableArray *fields = [[self repoFields] mutableCopy];
    [fields addObject:@{@"key": @"iconPath", @"title": RKLoc(@"Source Icon Path"), @"placeholder": @"/var/mobile/CydiaIcon.png"}];
    NSMutableDictionary *values = [self.currentRepo mutableCopy];
    values[@"iconPath"] = @"";
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Edit Source") fields:fields values:values save:^(NSDictionary<NSString *,NSString *> *values) {
        NSMutableArray *args = [@[@"repo-edit", weakSelf.currentRepoID ?: @"", @"--name", values[@"name"] ?: @"", @"--description", values[@"description"] ?: @"", @"--author", values[@"author"] ?: @"", @"--base-url", values[@"baseURL"] ?: @"", @"--scheme", values[@"scheme"] ?: @"", @"--architecture", values[@"architecture"] ?: @""] mutableCopy];
        if ([values[@"iconPath"] length]) {
            [args addObject:@"--icon"];
            [args addObject:values[@"iconPath"] ?: @""];
        }
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showGithubEditor {
    NSDictionary *github = [self.currentRepo[@"github"] isKindOfClass:[NSDictionary class]] ? self.currentRepo[@"github"] : @{};
    NSArray *fields = @[
        @{@"key": @"remote", @"title": @"Remote", @"placeholder": @"git@github.com:user/repo.git", @"required": @YES},
        @{@"key": @"branch", @"title": RKLoc(@"Branch"), @"placeholder": @"main"},
        @{@"key": @"user", @"title": RKLoc(@"Username"), @"placeholder": @"github-user", @"required": @YES},
        @{@"key": @"email", @"title": RKLoc(@"Email"), @"placeholder": @"you@example.com", @"required": @YES}
    ];
    __weak typeof(self) weakSelf = self;
    NSDictionary *values = @{
        @"remote": RKStringValue(github[@"remote"]),
        @"branch": RKStringValue(github[@"branch"]),
        @"user": RKStringValue(github[@"user"]),
        @"email": RKStringValue(github[@"email"])
    };
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"GitHub Settings") fields:fields values:values save:^(NSDictionary<NSString *,NSString *> *values) {
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"github", weakSelf.currentRepoID ?: @"", nil];
        RKAddOptionIfNotEmpty(args, @"--remote", values[@"remote"]);
        RKAddOptionIfNotEmpty(args, @"--branch", values[@"branch"]);
        RKAddOptionIfNotEmpty(args, @"--user", values[@"user"]);
        RKAddOptionIfNotEmpty(args, @"--email", values[@"email"]);
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showPushForm {
    NSArray *fields = @[@{@"key": @"message", @"title": RKLoc(@"Message"), @"placeholder": @"Update RepoKit repository"}];
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Push GitHub") fields:fields values:@{} save:^(NSDictionary<NSString *,NSString *> *values) {
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"push", weakSelf.currentRepoID ?: @"", nil];
        RKAddOptionIfNotEmpty(args, @"--message", values[@"message"]);
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self pushForm:form];
}

- (void)showPackageEditor:(NSDictionary *)package {
    if (!self.currentRepoID.length || !package) return;
    NSDictionary *control = DFControlFieldsForPackage(package);
    NSMutableArray<NSString *> *controlKeys = [[DFControlOrderForPackage(package) mutableCopy] ?: [NSMutableArray array] mutableCopy];
    NSArray *commonKeys = @[@"Package", @"Name", @"Version", @"Architecture", @"Section", @"Maintainer", @"Author", @"Depends", @"Pre-Depends", @"Icon", @"Description"];
    for (NSString *key in commonKeys) {
        if (![controlKeys containsObject:key]) [controlKeys addObject:key];
    }
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in controlKeys) {
        if (!key.length) continue;
        NSMutableDictionary *field = [@{@"key": key, @"title": DFPackageFieldTitle(key), @"placeholder": key} mutableCopy];
        if (DFControlFieldIsMultiline(key)) field[@"multiline"] = @YES;
        [fields addObject:field];
        values[key] = RKStringValue(control[key]);
    }
    [fields addObject:@{@"key": @"__iconPath", @"title": RKLoc(@"Icon Path"), @"placeholder": @"/var/mobile/icon.png"}];
    values[@"__iconPath"] = @"";
    NSString *oldPackage = RKStringValue(package[@"package"] ?: control[@"Package"]);
    NSString *oldVersion = RKStringValue(package[@"version"] ?: control[@"Version"]);
    __weak typeof(self) weakSelf = self;
    RKFormViewController *form = [[RKFormViewController alloc] initWithTitle:RKLoc(@"Edit Control and Icon") fields:fields values:values save:^(NSDictionary<NSString *,NSString *> *values) {
        NSMutableArray *args = [@[@"edit-deb", weakSelf.currentRepoID ?: @"", oldPackage, oldVersion] mutableCopy];
        NSDictionary *optionMap = @{@"Package": @"--package", @"Name": @"--name", @"Version": @"--version", @"Architecture": @"--architecture", @"Section": @"--section", @"Maintainer": @"--maintainer", @"Author": @"--author", @"Depends": @"--depends", @"Pre-Depends": @"--pre-depends", @"Description": @"--description", @"Depiction": @"--depiction", @"Homepage": @"--homepage", @"Conflicts": @"--conflicts", @"Replaces": @"--replaces", @"Provides": @"--provides", @"Tag": @"--tag"};
        for (NSString *key in controlKeys) {
            NSString *value = values[key] ?: @"";
            NSString *option = optionMap[key];
            if (option.length) {
                [args addObject:option];
                [args addObject:value];
            } else {
                [args addObject:@"--control-field"];
                [args addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
            }
        }
        if ([values[@"__iconPath"] length]) {
            [args addObject:@"--icon"];
            [args addObject:values[@"__iconPath"] ?: @""];
        }
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self pushForm:form];
}

- (void)confirmDeleteRepo:(NSString *)repoID {
    if (!repoID.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"Delete Source") message:repoID preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"Delete") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        if ([repoID isEqualToString:weakSelf.currentRepoID]) [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RepoKitCurrentRepoID"];
        [weakSelf runHelper:@[@"delete-repo", repoID] refresh:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface RKReposViewController : RKBaseTableViewController
@end

@implementation RKReposViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Sources");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"square.and.arrow.down") style:UIBarButtonItemStylePlain target:self action:@selector(showImportSourceForm)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"arrow.clockwise") style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)],
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"plus") style:UIBarButtonItemStylePlain target:self action:@selector(showCreateRepoForm)]
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 6;
    if (section == 1) return 4;
    return MAX(self.repos.count, 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? RKLoc(@"Dashboard") : (section == 1 ? RKLoc(@"Manage") : RKLoc(@"Sources"));
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return RKLoc(@"Dashboard Footer");
    if (section == 1) return RKLoc(@"Source Actions Footer");
    return RKLoc(@"Sources Footer");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *titles = @[RKLoc(@"Active Source"), RKLoc(@"Packages"), RKLoc(@"Mode and Architecture"), @"Base URL", @"GitHub", RKLoc(@"Last Build")];
        NSArray *symbols = @[@"tray.full", @"shippingbox", @"cpu", @"globe", @"paperplane", @"clock"];
        NSString *detail = RKLoc(@"Choose or import a source first");
        if (self.currentRepo) {
            NSDictionary *github = [self.currentRepo[@"github"] isKindOfClass:[NSDictionary class]] ? self.currentRepo[@"github"] : @{};
            if (indexPath.row == 0) detail = [NSString stringWithFormat:@"%@ · %@", RKStringValue(self.currentRepo[@"name"]), RKStringValue(self.currentRepo[@"id"])] ;
            else if (indexPath.row == 1) detail = [NSString stringWithFormat:@"%@ %@", RKStringValue(self.currentRepo[@"packageCount"] ?: @0), RKLoc(@"Packages")];
            else if (indexPath.row == 2) detail = [NSString stringWithFormat:@"%@ · %@", RKStringValue(self.currentRepo[@"scheme"] ?: @"rootless"), RKStringValue(self.currentRepo[@"architecture"] ?: @"iphoneos-arm64")];
            else if (indexPath.row == 3) detail = RKStringValue(self.currentRepo[@"baseURL"] ?: RKLoc(@"Not Configured"));
            else if (indexPath.row == 4) detail = RKStringValue(github[@"remote"] ?: RKLoc(@"Not Configured"));
            else detail = RKStringValue(self.currentRepo[@"lastBuildAt"] ?: RKLoc(@"Not Built"));
        }
        UITableViewCell *cell = RKCell(tableView, titles[(NSUInteger)indexPath.row], detail, symbols[(NSUInteger)indexPath.row], UITableViewCellAccessoryNone);
        cell.detailTextLabel.numberOfLines = 3;
        return cell;
    }
    if (indexPath.section == 1) {
        NSArray *titles = @[RKLoc(@"Create Source"), RKLoc(@"Import Source"), RKLoc(@"Edit Source"), RKLoc(@"Delete Source")];
        NSArray *details = @[RKLoc(@"Create a new local repository"), RKLoc(@"Import an existing repository folder"), RKLoc(@"Edit metadata and architecture"), RKLoc(@"Move current source to trash")];
        NSArray *symbols = @[@"plus.circle", @"square.and.arrow.down", @"pencil.circle", @"trash"];
        return RKCell(tableView, titles[(NSUInteger)indexPath.row], details[(NSUInteger)indexPath.row], symbols[(NSUInteger)indexPath.row], UITableViewCellAccessoryDisclosureIndicator);
    }
    if (!self.repos.count) return RKCell(tableView, RKLoc(@"No Sources"), RKLoc(@"Create or import one first"), @"tray", UITableViewCellAccessoryNone);
    NSDictionary *repo = self.repos[(NSUInteger)indexPath.row];
    UITableViewCell *cell = RKCell(tableView, RKStringValue(repo[@"name"] ?: repo[@"id"]), [NSString stringWithFormat:@"%@ · %@ %@", RKStringValue(repo[@"id"]), RKStringValue(repo[@"packageCount"]), RKLoc(@"Packages")], @"tray.full", UITableViewCellAccessoryDisclosureIndicator);
    cell.accessoryType = [repo[@"id"] isEqualToString:self.currentRepoID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self showCreateRepoForm];
        else if (indexPath.row == 1) [self showImportSourceForm];
        else if (indexPath.row == 2) [self showRepoEditor];
        else if (indexPath.row == 3) [self confirmDeleteRepo:self.currentRepoID];
        return;
    }
    if (indexPath.section == 2 && self.repos.count) {
        NSDictionary *repo = self.repos[(NSUInteger)indexPath.row];
        NSString *repoID = RKStringValue(repo[@"id"]);
        [[NSUserDefaults standardUserDefaults] setObject:repoID forKey:@"RepoKitCurrentRepoID"];
        [[NSNotificationCenter defaultCenter] postNotificationName:RKDataDidChangeNotification object:nil];
    }
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 2 && self.repos.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 2 && self.repos.count) {
        [self confirmDeleteRepo:RKStringValue(self.repos[(NSUInteger)indexPath.row][@"id"])] ;
    }
}

@end

@interface RKPackagesViewController : RKBaseTableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *packageSearchQuery;
- (NSArray<NSDictionary *> *)visiblePackages;
@end

@implementation RKPackagesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Packages");
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"arrow.clockwise") style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)],
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"plus") style:UIBarButtonItemStylePlain target:self action:@selector(showImportDebForm)]
    ];
    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = RKLoc(@"Search Packages");
    self.navigationItem.searchController = searchController;
    self.definesPresentationContext = YES;
}

- (NSArray<NSDictionary *> *)visiblePackages {
    NSString *query = [self.packageSearchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return self.packages ?: @[];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *pkg in self.packages ?: @[]) {
        NSArray *parts = @[RKStringValue(pkg[@"name"]), RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), RKStringValue(pkg[@"section"]), RKStringValue(pkg[@"description"]), RKStringValue(pkg[@"author"]), RKStringValue(pkg[@"maintainer"]), RKStringValue(pkg[@"depends"])] ;
        NSString *haystack = [parts componentsJoinedByString:@"\n"];
        if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) [matches addObject:pkg];
    }
    return matches;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.packageSearchQuery = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 4;
    if (section == 2) return 1;
    return MAX([self visiblePackages].count, 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return RKLoc(@"Current Source");
    if (section == 1) return RKLoc(@"Actions");
    if (section == 2) return RKLoc(@"Output");
    return RKLoc(@"Packages");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return RKLoc(@"Package Actions Footer");
    if (section == 3) return RKLoc(@"Package Search Footer");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSUInteger visibleCount = [self visiblePackages].count;
        NSString *detail = self.currentRepo ? [NSString stringWithFormat:@"%@ · %lu/%lu %@", RKStringValue(self.currentRepo[@"name"]), (unsigned long)visibleCount, (unsigned long)self.packages.count, RKLoc(@"Packages")] : RKLoc(@"Choose or import a source first");
        return RKCell(tableView, RKLoc(@"Active Source"), detail, @"tray.full", UITableViewCellAccessoryNone);
    }
    if (indexPath.section == 1) {
        NSArray *titles = @[RKLoc(@"Import Deb"), RKLoc(@"Build Index"), RKLoc(@"Check Source"), RKLoc(@"Refresh List")];
        NSArray *details = @[RKLoc(@"Copy a .deb into public/debs and rebuild"), RKLoc(@"Generate Packages, Packages.gz and Release"), RKLoc(@"Find duplicates and missing files"), RKLoc(@"Reload packages from cache")];
        NSArray *symbols = @[@"plus.app", @"hammer", @"checkmark.seal", @"arrow.clockwise"];
        UITableViewCell *cell = RKCell(tableView, titles[(NSUInteger)indexPath.row], details[(NSUInteger)indexPath.row], symbols[(NSUInteger)indexPath.row], UITableViewCellAccessoryDisclosureIndicator);
        RKSetCellLoading(cell, self.helperRunning && indexPath.row != 3);
        return RKSetCellEnabled(cell, !self.helperRunning);
    }
    if (indexPath.section == 2) {
        UITableViewCell *cell = RKCell(tableView, self.helperRunning ? RKLoc(@"Executing...") : RKLoc(@"Last Output"), self.lastOutput.length ? self.lastOutput : RKLoc(@"No Output"), @"terminal", UITableViewCellAccessoryNone);
        cell.detailTextLabel.numberOfLines = 6;
        RKSetCellLoading(cell, self.helperRunning);
        return cell;
    }
    NSArray<NSDictionary *> *visiblePackages = [self visiblePackages];
    if (!visiblePackages.count) {
        NSString *detail = self.packageSearchQuery.length ? RKLoc(@"No Matching Packages") : RKLoc(@"Import or rescan debs first");
        return RKCell(tableView, self.packageSearchQuery.length ? RKLoc(@"No Results") : RKLoc(@"No Packages"), detail, @"shippingbox", UITableViewCellAccessoryNone);
    }
    NSDictionary *pkg = visiblePackages[(NSUInteger)indexPath.row];
    NSString *title = RKStringValue(pkg[@"name"] ?: pkg[@"package"]);
    NSString *detail = [NSString stringWithFormat:@"%@ %@ · %@ · %@", RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), RKStringValue(pkg[@"architecture"]), RKStringValue(pkg[@"section"] ?: @"-")] ;
    UITableViewCell *cell = RKCell(tableView, title, detail, @"shippingbox.fill", UITableViewCellAccessoryDisclosureIndicator);
    return RKSetCellEnabled(cell, !self.helperRunning);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (self.helperRunning) { [self showMessage:RKLoc(@"Operation in progress") title:RKLoc(@"RepoKit")]; return; }
        if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
        if (indexPath.row == 0) [self showImportDebForm];
        else if (indexPath.row == 1) [self runHelper:@[@"build", self.currentRepoID] refresh:YES];
        else if (indexPath.row == 2) [self runHelper:@[@"check", self.currentRepoID] refresh:NO];
        else if (indexPath.row == 3) [self refreshData];
        return;
    }
    NSArray<NSDictionary *> *visiblePackages = [self visiblePackages];
    if (indexPath.section == 3 && visiblePackages.count) {
        if (self.helperRunning) { [self showMessage:RKLoc(@"Operation in progress") title:RKLoc(@"RepoKit")]; return; }
        NSDictionary *pkg = visiblePackages[(NSUInteger)indexPath.row];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:RKStringValue(pkg[@"package"]) message:RKStringValue(pkg[@"description"]) preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"View JSON") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:pkg options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            [self showMessage:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"" title:RKLoc(@"Package JSON")];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Edit Control and Icon") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self showPackageEditor:pkg];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Delete Record and File") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self runHelper:@[@"remove", self.currentRepoID ?: @"", RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), @"--delete-file"] refresh:YES];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:RKLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 3 && [self visiblePackages].count > 0 && !self.helperRunning;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *visiblePackages = [self visiblePackages];
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 3 && visiblePackages.count) {
        if (self.helperRunning) { [self showMessage:RKLoc(@"Operation in progress") title:RKLoc(@"RepoKit")]; return; }
        NSDictionary *pkg = visiblePackages[(NSUInteger)indexPath.row];
        [self runHelper:@[@"remove", self.currentRepoID ?: @"", RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), @"--delete-file"] refresh:YES];
    }
}

@end

@interface RKPublishViewController : RKBaseTableViewController
@end

@implementation RKPublishViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Publish");
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 2;
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return RKLoc(@"Build and Verify");
    if (section == 1) return @"GitHub";
    return RKLoc(@"Output");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return RKLoc(@"Publish Check Footer");
    if (section == 1) return RKLoc(@"Publish GitHub Footer");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = RKCell(tableView, RKLoc(@"Check Source"), RKLoc(@"Run preflight checks before publishing"), @"checkmark.seal", UITableViewCellAccessoryDisclosureIndicator);
        RKSetCellLoading(cell, self.helperRunning);
        return RKSetCellEnabled(cell, !self.helperRunning);
    }
    if (indexPath.section == 1) {
        NSDictionary *github = [self.currentRepo[@"github"] isKindOfClass:[NSDictionary class]] ? self.currentRepo[@"github"] : @{};
        UITableViewCell *cell = nil;
        if (indexPath.row == 0) cell = RKCell(tableView, RKLoc(@"GitHub Settings"), RKStringValue(github[@"remote"] ?: RKLoc(@"Not Configured")), @"gearshape", UITableViewCellAccessoryDisclosureIndicator);
        else cell = RKCell(tableView, RKLoc(@"Push GitHub"), RKLoc(@"Auto build index, commit and push"), @"paperplane", UITableViewCellAccessoryDisclosureIndicator);
        RKSetCellLoading(cell, self.helperRunning && indexPath.row == 1);
        return RKSetCellEnabled(cell, !self.helperRunning);
    }
    UITableViewCell *cell = RKCell(tableView, self.helperRunning ? RKLoc(@"Executing...") : RKLoc(@"Last Output"), self.lastOutput.length ? self.lastOutput : RKLoc(@"No Output"), @"terminal", UITableViewCellAccessoryNone);
    RKSetCellLoading(cell, self.helperRunning);
    cell.detailTextLabel.numberOfLines = 8;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.helperRunning) { [self showMessage:RKLoc(@"Operation in progress") title:RKLoc(@"RepoKit")]; return; }
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    if (indexPath.section == 0 && indexPath.row == 0) [self runHelper:@[@"check", self.currentRepoID] refresh:NO];
    else if (indexPath.section == 1 && indexPath.row == 0) [self showGithubEditor];
    else if (indexPath.section == 1 && indexPath.row == 1) [self showPushForm];
}

@end


@interface RKGuideViewController : UITableViewController
@end

@implementation RKGuideViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Guide");
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAutomatic;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 7; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray *headers = @[RKLoc(@"Quick Start"), RKLoc(@"Source Management"), RKLoc(@"Package Management"), RKLoc(@"GitHub Repository"), RKLoc(@"GitHub Pages"), RKLoc(@"More Settings"), RKLoc(@"Troubleshooting")];
    return headers[(NSUInteger)section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *texts = @[
        RKLoc(@"Guide Quick Start Text"),
        RKLoc(@"Guide Source Text"),
        RKLoc(@"Guide Package Text"),
        RKLoc(@"Guide GitHub Repo Text"),
        RKLoc(@"Guide GitHub Pages Text"),
        RKLoc(@"Guide More Settings Text"),
        RKLoc(@"Guide Troubleshooting Text")
    ];
    NSArray *symbols = @[@"1.circle", @"tray.full", @"shippingbox", @"folder.badge.plus", @"globe", @"slider.horizontal.3", @"wrench.and.screwdriver"];
    UITableViewCell *cell = RKCell(tableView, RKLoc(@"Guide Step"), texts[(NSUInteger)indexPath.section], symbols[(NSUInteger)indexPath.section], UITableViewCellAccessoryNone);
    cell.textLabel.text = nil;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end



typedef NS_ENUM(NSInteger, DFPackageStatus) {
    DFPackageStatusIndexed,
    DFPackageStatusMissingDeb,
    DFPackageStatusQueued,
    DFPackageStatusBuilding,
    DFPackageStatusError
};

static UIColor *DFPrimaryColor(void) { return [UIColor colorWithRed:0.0 green:122.0/255.0 blue:1.0 alpha:1.0]; }
static UIColor *DFDangerColor(void) { return [UIColor colorWithRed:1.0 green:59.0/255.0 blue:48.0/255.0 alpha:1.0]; }
static UIColor *DFSuccessColor(void) { return [UIColor colorWithRed:52.0/255.0 green:199.0/255.0 blue:89.0/255.0 alpha:1.0]; }
static UIColor *DFWarningColor(void) { return [UIColor colorWithRed:1.0 green:149.0/255.0 blue:0.0 alpha:1.0]; }

static UIColor *DFCardBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondarySystemGroupedBackgroundColor;
    return UIColor.whiteColor;
}

static UIColor *DFCardInsetBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.tertiarySystemGroupedBackgroundColor;
    return [UIColor colorWithWhite:0.94 alpha:1.0];
}

static void DFApplyCardStyle(UIView *view) {
    view.backgroundColor = DFCardBackgroundColor();
    view.layer.cornerRadius = 14.0;
    view.layer.shadowColor = UIColor.blackColor.CGColor;
    view.layer.shadowOpacity = 0.08;
    view.layer.shadowRadius = 6.0;
    view.layer.shadowOffset = CGSizeMake(0, 2);
}

static NSString *DFExistingPath(NSString *path) {
    if (!path.length) return @"";
    NSString *expanded = [path stringByExpandingTildeInPath];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if ([fileManager fileExistsAtPath:expanded]) return expanded.stringByStandardizingPath;
    NSString *converted = jbroot(expanded);
    if ([fileManager fileExistsAtPath:converted]) return converted.stringByStandardizingPath;
    if ([expanded hasPrefix:@"/var/mobile/"]) {
        NSString *jbVarPath = [@"/var/jb" stringByAppendingString:expanded];
        if ([fileManager fileExistsAtPath:jbVarPath]) return jbVarPath.stringByStandardizingPath;
    }
    if ([expanded hasPrefix:@"/private/preboot/"]) {
        NSRange procursusRange = [expanded rangeOfString:@"/procursus" options:NSBackwardsSearch];
        if (procursusRange.location != NSNotFound) {
            NSString *logicalPath = [expanded substringFromIndex:procursusRange.location + @"/procursus".length];
            NSString *convertedLogicalPath = jbroot(logicalPath);
            if ([fileManager fileExistsAtPath:convertedLogicalPath]) return convertedLogicalPath.stringByStandardizingPath;
        }
    }
    return expanded.stringByStandardizingPath;
}

static NSString *DFPublicPathForRepo(NSDictionary *repo) {
    NSString *path = RKStringValue(repo[@"publicPath"] ?: repo[@"sourcePath"]);
    return DFExistingPath(path);
}

static UIImage *DFImageAtPath(NSString *path) {
    NSString *existingPath = DFExistingPath(path);
    return existingPath.length ? [UIImage imageWithContentsOfFile:existingPath] : nil;
}

static UIImage *DFSourceIconImage(NSDictionary *repo) {
    if (!repo) return nil;
    NSString *publicPath = DFPublicPathForRepo(repo);
    NSString *iconName = RKStringValue(repo[@"icon"]);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (iconName.length) [candidates addObject:[iconName hasPrefix:@"/"] ? iconName : [publicPath stringByAppendingPathComponent:iconName]];
    if (publicPath.length) [candidates addObject:[publicPath stringByAppendingPathComponent:@"CydiaIcon.png"]];
    for (NSString *candidate in candidates) {
        UIImage *image = DFImageAtPath(candidate);
        if (image) return image;
    }
    return nil;
}

static UIImage *DFPackageIconImage(NSDictionary *package, NSDictionary *repo) {
    NSString *iconValue = RKStringValue(package[@"icon"]);
    if (!iconValue.length || [iconValue hasPrefix:@"http://"] || [iconValue hasPrefix:@"https://"]) return nil;
    NSString *publicPath = DFPublicPathForRepo(repo);
    NSArray<NSString *> *candidates = [iconValue hasPrefix:@"/"] ? @[iconValue] : @[[publicPath stringByAppendingPathComponent:iconValue], [publicPath stringByAppendingPathComponent:[@"icons" stringByAppendingPathComponent:iconValue.lastPathComponent]]];
    for (NSString *candidate in candidates) {
        UIImage *image = DFImageAtPath(candidate);
        if (image) return image;
    }
    return nil;
}

static NSDictionary *DFControlFieldsForPackage(NSDictionary *package) {
    NSDictionary *control = [package[@"control"] isKindOfClass:[NSDictionary class]] ? package[@"control"] : nil;
    if (control.count) return control;
    NSMutableDictionary *fallback = [NSMutableDictionary dictionary];
    NSDictionary *mapping = @{
        @"Package": @"package",
        @"Name": @"name",
        @"Version": @"version",
        @"Architecture": @"architecture",
        @"Section": @"section",
        @"Maintainer": @"maintainer",
        @"Author": @"author",
        @"Depends": @"depends",
        @"Pre-Depends": @"preDepends",
        @"Icon": @"icon",
        @"Description": @"description",
        @"Depiction": @"depiction",
        @"Homepage": @"homepage",
        @"Conflicts": @"conflicts",
        @"Replaces": @"replaces",
        @"Provides": @"provides",
        @"Tag": @"tag"
    };
    for (NSString *controlKey in mapping) {
        NSString *value = RKStringValue(package[mapping[controlKey]]);
        if (value.length) fallback[controlKey] = value;
    }
    return fallback;
}

static NSArray<NSString *> *DFControlOrderForPackage(NSDictionary *package) {
    NSDictionary *control = DFControlFieldsForPackage(package);
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSArray *order = [package[@"controlOrder"] isKindOfClass:[NSArray class]] ? package[@"controlOrder"] : @[];
    for (id item in order) {
        NSString *key = RKStringValue(item);
        if (key.length && control[key] && ![keys containsObject:key]) [keys addObject:key];
    }
    NSArray *preferred = @[@"Package", @"Name", @"Version", @"Architecture", @"Section", @"Maintainer", @"Author", @"Depends", @"Pre-Depends", @"Icon", @"Description"];
    for (NSString *key in preferred) {
        if (control[key] && ![keys containsObject:key]) [keys addObject:key];
    }
    NSArray *remaining = [[control allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *key in remaining) {
        if (![keys containsObject:key]) [keys addObject:key];
    }
    return keys;
}

static NSString *DFSectionForPackage(NSDictionary *package) {
    NSDictionary *control = DFControlFieldsForPackage(package);
    NSString *section = [RKStringValue(control[@"Section"] ?: package[@"section"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return section.length ? section : RKLoc(@"Uncategorized");
}

static BOOL DFControlFieldIsMultiline(NSString *key) {
    return [@[@"Description", @"Depends", @"Pre-Depends", @"Conflicts", @"Replaces", @"Provides", @"Tag", @"Icon", @"Depiction", @"Homepage"] containsObject:key];
}

static NSString *DFPackageFieldTitle(NSString *key) {
    NSDictionary *titles = @{
        @"Package": RKLoc(@"Package ID"),
        @"package": RKLoc(@"Package ID"),
        @"Name": RKLoc(@"Name"),
        @"name": RKLoc(@"Name"),
        @"Version": RKLoc(@"Version"),
        @"version": RKLoc(@"Version"),
        @"Architecture": RKLoc(@"Architecture"),
        @"architecture": RKLoc(@"Architecture"),
        @"Section": RKLoc(@"Section"),
        @"section": RKLoc(@"Section"),
        @"Filename": RKLoc(@"Deb File"),
        @"filename": RKLoc(@"Deb File"),
        @"sourcePath": RKLoc(@"Source Path"),
        @"Description": RKLoc(@"Description"),
        @"description": RKLoc(@"Description"),
        @"Depends": RKLoc(@"Depends"),
        @"depends": RKLoc(@"Depends"),
        @"Pre-Depends": RKLoc(@"Pre-Depends"),
        @"preDepends": RKLoc(@"Pre-Depends"),
        @"Author": RKLoc(@"Author"),
        @"author": RKLoc(@"Author"),
        @"Maintainer": RKLoc(@"Maintainer"),
        @"maintainer": RKLoc(@"Maintainer"),
        @"Icon": RKLoc(@"Icon"),
        @"icon": RKLoc(@"Icon"),
        @"Installed-Size": RKLoc(@"Installed Size")
    };
    return titles[key] ?: key;
}

static UILabel *DFLabel(UIFont *font, UIColor *color, NSInteger lines) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    return label;
}

static NSString *DFStatusTitle(DFPackageStatus status) {
    switch (status) {
        case DFPackageStatusIndexed: return RKLoc(@"Indexed");
        case DFPackageStatusMissingDeb: return RKLoc(@"Missing Deb");
        case DFPackageStatusQueued: return RKLoc(@"Queued");
        case DFPackageStatusBuilding: return RKLoc(@"Building");
        case DFPackageStatusError: return RKLoc(@"Error");
    }
}

static UIColor *DFStatusColor(DFPackageStatus status) {
    switch (status) {
        case DFPackageStatusIndexed: return DFSuccessColor();
        case DFPackageStatusMissingDeb: return DFWarningColor();
        case DFPackageStatusQueued: return UIColor.systemGrayColor;
        case DFPackageStatusBuilding: return DFPrimaryColor();
        case DFPackageStatusError: return DFDangerColor();
    }
}

static UIButton *DFActionButton(NSString *title, NSString *symbol, UIColor *color) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [color colorWithAlphaComponent:0.10];
    button.layer.cornerRadius = 12.0;
    button.tintColor = color;
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    [button setTitle:title forState:UIControlStateNormal];
    UIImage *image = RKSymbol(symbol);
    [button setImage:image forState:UIControlStateNormal];
    button.imageEdgeInsets = UIEdgeInsetsMake(-18, 20, 0, -20);
    button.titleEdgeInsets = UIEdgeInsetsMake(34, -32, 0, 0);
    return button;
}

@interface RKBaseTableViewController (DFLogging)
- (UITextView *)df_logTextView;
- (void)df_appendLog:(NSString *)line toTextView:(UITextView *)textView;
@end

@implementation RKBaseTableViewController (DFLogging)
- (UITextView *)df_logTextView { return nil; }
- (void)df_appendLog:(NSString *)line toTextView:(UITextView *)textView {
    if (!line.length || !textView) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *prefix = textView.text.length ? @"\n" : @"";
        textView.text = [textView.text stringByAppendingFormat:@"%@%@", prefix, line];
        NSRange bottom = NSMakeRange(textView.text.length, 0);
        [textView scrollRangeToVisible:bottom];
    });
}
@end

@interface DFSourceEditVC : RKFormViewController
@end

@implementation DFSourceEditVC
- (void)cancelTapped {
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface DFSourceOverviewVC : RKBaseTableViewController
@property (nonatomic, assign) BOOL logExpanded;
@property (nonatomic, weak) UITextView *logTextView;
@end

@implementation DFSourceOverviewVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Sources");
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"square.and.arrow.down") style:UIBarButtonItemStylePlain target:self action:@selector(showImportSourceForm)],
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"gearshape") style:UIBarButtonItemStylePlain target:self action:@selector(showGithubEditor)]
    ];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:RKLoc(@"Edit") style:UIBarButtonItemStylePlain target:self action:@selector(showDFSourceEditor)],
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"plus") style:UIBarButtonItemStylePlain target:self action:@selector(showCreateRepoForm)]
    ];
}

- (UITextView *)df_logTextView { return self.logTextView; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 3) return 1;
    return MAX(self.repos.count, 1);
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 184.0;
    if (indexPath.section == 1) return 116.0;
    if (indexPath.section == 2) return self.logExpanded ? 226.0 : 64.0;
    return 82.0;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return RKLoc(@"Quick Actions");
    if (section == 3) return RKLoc(@"Sources");
    return nil;
}

- (UITableViewCell *)heroCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];

    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = [DFPrimaryColor() colorWithAlphaComponent:0.12];
    iconBox.layer.cornerRadius = 16.0;
    iconBox.clipsToBounds = YES;
    UIImage *sourceImage = DFSourceIconImage(self.currentRepo);
    UIImageView *icon = [[UIImageView alloc] initWithImage:sourceImage ?: RKSymbol(@"tray.full.fill")];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = sourceImage ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    icon.tintColor = DFPrimaryColor();
    icon.clipsToBounds = YES;
    [iconBox addSubview:icon];

    UILabel *title = DFLabel([UIFont systemFontOfSize:28 weight:UIFontWeightBold], UIColor.labelColor, 1);
    title.text = self.currentRepo ? RKStringValue(self.currentRepo[@"name"] ?: self.currentRepo[@"id"]) : RKLoc(@"Choose or import a source first");
    UILabel *base = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.secondaryLabelColor, 2);
    base.text = self.currentRepo ? RKStringValue(self.currentRepo[@"baseURL"] ?: RKLoc(@"Not Configured")) : RKLoc(@"No Sources");
    UILabel *mode = DFLabel([UIFont systemFontOfSize:13 weight:UIFontWeightSemibold], DFPrimaryColor(), 1);
    mode.text = self.currentRepo ? [NSString stringWithFormat:@"%@ · %@", RKStringValue(self.currentRepo[@"scheme"] ?: @"rootless"), RKStringValue(self.currentRepo[@"architecture"] ?: @"iphoneos-arm64")] : @"rootless · iphoneos-arm64";
    UILabel *count = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], UIColor.secondaryLabelColor, 1);
    count.text = [NSString stringWithFormat:@"%@ %@ · %@: %@", RKStringValue(self.currentRepo[@"packageCount"] ?: @(self.packages.count)), RKLoc(@"Packages"), RKLoc(@"Last Build"), RKStringValue(self.currentRepo[@"lastBuildAt"] ?: RKLoc(@"Not Built"))];
    for (UIView *view in @[iconBox, title, base, mode, count]) [card addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconBox.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [iconBox.widthAnchor constraintEqualToConstant:66],
        [iconBox.heightAnchor constraintEqualToConstant:66],
        [icon.leadingAnchor constraintEqualToAnchor:iconBox.leadingAnchor],
        [icon.trailingAnchor constraintEqualToAnchor:iconBox.trailingAnchor],
        [icon.topAnchor constraintEqualToAnchor:iconBox.topAnchor],
        [icon.bottomAnchor constraintEqualToAnchor:iconBox.bottomAnchor],
        [title.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [base.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [base.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [base.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [mode.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [mode.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [mode.topAnchor constraintEqualToAnchor:iconBox.bottomAnchor constant:18],
        [count.leadingAnchor constraintEqualToAnchor:mode.leadingAnchor],
        [count.trailingAnchor constraintEqualToAnchor:mode.trailingAnchor],
        [count.topAnchor constraintEqualToAnchor:mode.bottomAnchor constant:10]
    ]];
    return cell;
}

- (UITableViewCell *)actionsCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 10.0;
    [card addSubview:stack];
    NSArray *items = @[
        @[RKLoc(@"Import Deb"), @"plus.app", DFPrimaryColor()],
        @[RKLoc(@"Build Index"), @"hammer", DFPrimaryColor()],
        @[RKLoc(@"Check Source"), @"checkmark.seal", DFSuccessColor()],
        @[RKLoc(@"Push GitHub"), @"paperplane", DFPrimaryColor()]
    ];
    for (NSUInteger index = 0; index < items.count; index++) {
        UIButton *button = DFActionButton(items[index][0], items[index][1], items[index][2]);
        button.tag = (NSInteger)index;
        button.enabled = !self.helperRunning;
        button.alpha = self.helperRunning ? 0.45 : 1.0;
        [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    if (self.helperRunning) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner startAnimating];
        [card addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [spinner.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
    ]];
    return cell;
}

- (UITableViewCell *)logCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UILabel *title = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor, 1);
    title.text = RKLoc(@"Logs");
    UIImageView *arrow = [[UIImageView alloc] initWithImage:RKSymbol(self.logExpanded ? @"chevron.up" : @"chevron.down")];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.tintColor = UIColor.secondaryLabelColor;
    [card addSubview:title];
    [card addSubview:arrow];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [arrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [arrow.centerYAnchor constraintEqualToAnchor:title.centerYAnchor]
    ]];
    if (self.logExpanded) {
        UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
        textView.translatesAutoresizingMaskIntoConstraints = NO;
        textView.editable = NO;
        textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        textView.text = self.lastOutput.length ? self.lastOutput : RKLoc(@"No Output");
        textView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        textView.layer.cornerRadius = 10.0;
        self.logTextView = textView;
        [card addSubview:textView];
        [NSLayoutConstraint activateConstraints:@[
            [textView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [textView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
            [textView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
        ]];
    }
    return cell;
}

- (UITableViewCell *)repoCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
    if (!self.repos.count) return RKCell(tableView, RKLoc(@"No Sources"), RKLoc(@"Create or import one first"), @"tray", UITableViewCellAccessoryNone);
    NSDictionary *repo = self.repos[(NSUInteger)indexPath.row];
    UITableViewCell *cell = RKCell(tableView, RKStringValue(repo[@"name"] ?: repo[@"id"]), [NSString stringWithFormat:@"%@ · %@ %@", RKStringValue(repo[@"id"]), RKStringValue(repo[@"packageCount"]), RKLoc(@"Packages")], @"tray.full", UITableViewCellAccessoryDisclosureIndicator);
    cell.accessoryType = [repo[@"id"] isEqualToString:self.currentRepoID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self heroCellForTableView:tableView];
    if (indexPath.section == 1) return [self actionsCellForTableView:tableView];
    if (indexPath.section == 2) return [self logCellForTableView:tableView];
    return [self repoCellForTableView:tableView indexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        self.logExpanded = !self.logExpanded;
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    if (indexPath.section == 3 && self.repos.count) {
        NSDictionary *repo = self.repos[(NSUInteger)indexPath.row];
        NSString *repoID = RKStringValue(repo[@"id"]);
        [[NSUserDefaults standardUserDefaults] setObject:repoID forKey:@"RepoKitCurrentRepoID"];
        [[NSNotificationCenter defaultCenter] postNotificationName:RKDataDidChangeNotification object:nil];
    }
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 3 && self.repos.count > 0;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 3 && self.repos.count) {
        [self confirmDeleteRepo:RKStringValue(self.repos[(NSUInteger)indexPath.row][@"id"])] ;
    }
}

- (void)actionTapped:(UIButton *)sender {
    if (self.helperRunning) return;
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    self.logExpanded = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self df_appendLog:RKLoc(@"Executing...") toTextView:self.logTextView];
    if (sender.tag == 0) [self showImportDebForm];
    else if (sender.tag == 1) [self runHelper:@[@"build", self.currentRepoID] refresh:YES];
    else if (sender.tag == 2) [self runHelper:@[@"check", self.currentRepoID] refresh:NO];
    else if (sender.tag == 3) [self showPushForm];
}

- (void)showDFSourceEditor {
    if (!self.currentRepoID.length || !self.currentRepo) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    NSMutableArray *fields = [[self repoFields] mutableCopy];
    [fields addObject:@{@"key": @"iconPath", @"title": RKLoc(@"Source Icon Path"), @"placeholder": @"/var/mobile/CydiaIcon.png"}];
    NSMutableDictionary *values = [self.currentRepo mutableCopy];
    values[@"iconPath"] = @"";
    __weak typeof(self) weakSelf = self;
    DFSourceEditVC *form = [[DFSourceEditVC alloc] initWithTitle:RKLoc(@"Edit Source") fields:fields values:values save:^(NSDictionary<NSString *,NSString *> *values) {
        NSMutableArray *args = [@[@"repo-edit", weakSelf.currentRepoID ?: @"", @"--name", values[@"name"] ?: @"", @"--description", values[@"description"] ?: @"", @"--author", values[@"author"] ?: @"", @"--base-url", values[@"baseURL"] ?: @"", @"--scheme", values[@"scheme"] ?: @"", @"--architecture", values[@"architecture"] ?: @""] mutableCopy];
        if ([values[@"iconPath"] length]) {
            [args addObject:@"--icon"];
            [args addObject:values[@"iconPath"] ?: @""];
        }
        [weakSelf.navigationController popViewControllerAnimated:YES];
        [weakSelf runHelper:args refresh:YES];
    }];
    [self.navigationController pushViewController:form animated:YES];
}

@end

@interface DFPackageDetailVC : RKBaseTableViewController
@property (nonatomic, strong) NSDictionary *package;
- (instancetype)initWithPackage:(NSDictionary *)package repoID:(NSString *)repoID;
@end

@implementation DFPackageDetailVC
- (instancetype)initWithPackage:(NSDictionary *)package repoID:(NSString *)repoID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.package = package;
        self.currentRepoID = repoID;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKStringValue(self.package[@"name"] ?: self.package[@"package"]);
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:RKLoc(@"Edit") style:UIBarButtonItemStylePlain target:self action:@selector(editPackage)];
}
- (NSArray<NSString *> *)controlFieldKeys {
    return DFControlOrderForPackage(self.package);
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return [self controlFieldKeys].count;
    NSDictionary *control = DFControlFieldsForPackage(self.package);
    NSString *depends = RKStringValue(control[@"Depends"] ?: self.package[@"depends"]);
    return depends.length ? [depends componentsSeparatedByString:@","].count : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return RKLoc(@"Actions");
    if (section == 1) return RKLoc(@"Control Fields");
    return RKLoc(@"Dependencies");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSArray *titles = @[RKLoc(@"Repack"), RKLoc(@"Reindex")];
        NSArray *details = @[RKLoc(@"Edit control fields and rebuild deb"), RKLoc(@"Rebuild Packages and Release")];
        NSArray *symbols = @[@"shippingbox.and.arrow.backward", @"arrow.triangle.2.circlepath"];
        UITableViewCell *cell = RKCell(tableView, titles[(NSUInteger)indexPath.row], details[(NSUInteger)indexPath.row], symbols[(NSUInteger)indexPath.row], UITableViewCellAccessoryDisclosureIndicator);
        RKSetCellLoading(cell, self.helperRunning);
        return RKSetCellEnabled(cell, !self.helperRunning);
    }
    if (indexPath.section == 1) {
        NSDictionary *control = DFControlFieldsForPackage(self.package);
        NSArray *keys = [self controlFieldKeys];
        NSString *key = keys[(NSUInteger)indexPath.row];
        NSString *value = RKStringValue(control[key]);
        UITableViewCell *cell = RKCell(tableView, DFPackageFieldTitle(key), value.length ? value : @"-", @"doc.text", UITableViewCellAccessoryNone);
        cell.detailTextLabel.numberOfLines = 4;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *control = DFControlFieldsForPackage(self.package);
    NSString *depends = RKStringValue(control[@"Depends"] ?: self.package[@"depends"]);
    if (!depends.length) return RKCell(tableView, RKLoc(@"No Dependencies"), @"", @"checkmark.circle", UITableViewCellAccessoryNone);
    NSArray *items = [depends componentsSeparatedByString:@","];
    NSString *item = [items[(NSUInteger)indexPath.row] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return RKCell(tableView, item, @"", @"link", UITableViewCellAccessoryNone);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || self.helperRunning) return;
    if (indexPath.row == 0) [self editPackage];
    else [self runHelper:@[@"build", self.currentRepoID ?: @""] refresh:YES];
}
- (void)editPackage {
    [self showPackageEditor:self.package];
}
@end

@interface DFPackageListVC : RKBaseTableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *packageSearchQuery;
@property (nonatomic, copy) NSString *selectedPackageSection;
@property (nonatomic, copy) NSArray<NSDictionary *> *categoryItems;
- (NSArray<NSDictionary *> *)visiblePackages;
@end

@implementation DFPackageListVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Packages");
    self.selectedPackageSection = @"__all__";
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"plus") style:UIBarButtonItemStylePlain target:self action:@selector(showImportDebForm)],
        [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"arrow.clockwise") style:UIBarButtonItemStylePlain target:self action:@selector(refreshData)]
    ];
    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = RKLoc(@"Search Packages");
    self.navigationItem.searchController = searchController;
    self.definesPresentationContext = YES;
    [self refreshCategoryHeader];
}
- (void)setPackages:(NSArray<NSDictionary *> *)packages {
    [super setPackages:packages];
    [self refreshCategoryHeader];
}
- (NSArray<NSDictionary *> *)buildCategoryItems {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *package in self.packages ?: @[]) {
        NSString *section = DFSectionForPackage(package);
        counts[section] = @([counts[section] integerValue] + 1);
    }
    NSArray *sortedSections = [[counts allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *items = [NSMutableArray arrayWithObject:@{@"key": @"__all__", @"title": RKLoc(@"All"), @"count": @(self.packages.count)}];
    for (NSString *section in sortedSections) [items addObject:@{@"key": section, @"title": section, @"count": counts[section] ?: @0}];
    return items;
}
- (void)refreshCategoryHeader {
    if (!self.isViewLoaded) return;
    self.categoryItems = [self buildCategoryItems];
    BOOL selectedExists = NO;
    for (NSDictionary *item in self.categoryItems) {
        if ([RKStringValue(item[@"key"]) isEqualToString:self.selectedPackageSection ?: @"__all__"]) selectedExists = YES;
    }
    if (!selectedExists) self.selectedPackageSection = @"__all__";

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0.0) width = CGRectGetWidth(UIScreen.mainScreen.bounds);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 126.0)];
    header.backgroundColor = UIColor.clearColor;
    UILabel *title = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor, 1);
    title.text = RKLoc(@"Categories");
    [header addSubview:title];
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    [header addSubview:scrollView];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 12.0;
    [scrollView addSubview:stack];
    for (NSUInteger index = 0; index < self.categoryItems.count; index++) {
        NSDictionary *item = self.categoryItems[index];
        BOOL selected = [RKStringValue(item[@"key"]) isEqualToString:self.selectedPackageSection ?: @"__all__"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.tag = (NSInteger)index;
        button.layer.cornerRadius = 14.0;
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = selected ? 0.10 : 0.06;
        button.layer.shadowRadius = 5.0;
        button.layer.shadowOffset = CGSizeMake(0, 2);
        button.backgroundColor = selected ? DFPrimaryColor() : DFCardBackgroundColor();
        button.tintColor = selected ? UIColor.whiteColor : DFPrimaryColor();
        button.titleLabel.numberOfLines = 2;
        button.titleLabel.textAlignment = NSTextAlignmentLeft;
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        NSString *buttonText = [NSString stringWithFormat:@"%@\n%@ %@", RKStringValue(item[@"title"]), RKStringValue(item[@"count"]), RKLoc(@"Packages")];
        [button setTitle:buttonText forState:UIControlStateNormal];
        [button setTitleColor:selected ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
        [button setImage:RKSymbol([RKStringValue(item[@"key"]) isEqualToString:@"__all__"] ? @"square.grid.2x2.fill" : @"folder.fill") forState:UIControlStateNormal];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
        button.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 28, -18);
        button.titleEdgeInsets = UIEdgeInsetsMake(12, 8, 0, -8);
        [button addTarget:self action:@selector(categoryTapped:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintEqualToConstant:142.0],
            [button.heightAnchor constraintEqualToConstant:78.0]
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:10],
        [scrollView.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [scrollView.heightAnchor constraintEqualToConstant:84.0],
        [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:3],
        [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-3],
        [stack.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor constant:-6]
    ]];
    self.tableView.tableHeaderView = header;
}
- (void)categoryTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.categoryItems.count) return;
    NSDictionary *item = self.categoryItems[(NSUInteger)sender.tag];
    self.selectedPackageSection = RKStringValue(item[@"key"]);
    [self refreshCategoryHeader];
    [self.tableView reloadData];
}
- (NSArray<NSDictionary *> *)visiblePackages {
    NSString *query = [self.packageSearchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *candidates = [NSMutableArray array];
    BOOL allSections = !self.selectedPackageSection.length || [self.selectedPackageSection isEqualToString:@"__all__"];
    for (NSDictionary *pkg in self.packages ?: @[]) {
        if (!allSections && ![DFSectionForPackage(pkg) isEqualToString:self.selectedPackageSection]) continue;
        if (!query.length) { [candidates addObject:pkg]; continue; }
        NSArray *fields = @[RKStringValue(pkg[@"name"]), RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), RKStringValue(pkg[@"architecture"]), RKStringValue(pkg[@"section"]), RKStringValue(pkg[@"description"]), RKStringValue(pkg[@"depends"]), RKStringValue(pkg[@"maintainer"]), RKStringValue(pkg[@"author"])] ;
        NSString *haystack = [[fields componentsJoinedByString:@"\n"] lowercaseString];
        if ([haystack containsString:query.lowercaseString]) [candidates addObject:pkg];
    }
    return candidates;
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.packageSearchQuery = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MAX([self visiblePackages].count, 1); }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 104.0; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return RKLoc(@"Packages use UITableView for fast search, swipe actions and stable large-list performance.");
}
- (DFPackageStatus)statusForPackage:(NSDictionary *)package {
    if (self.helperRunning) return DFPackageStatusBuilding;
    if (!RKStringValue(package[@"package"]).length || !RKStringValue(package[@"version"]).length) return DFPackageStatusError;
    if (!RKStringValue(package[@"filename"]).length) return DFPackageStatusMissingDeb;
    return DFPackageStatusIndexed;
}
- (UITableViewCell *)emptyCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = RKCell(tableView, self.packageSearchQuery.length ? RKLoc(@"No Results") : RKLoc(@"No Packages"), self.packageSearchQuery.length ? RKLoc(@"No Matching Packages") : RKLoc(@"Import or rescan debs first"), @"shippingbox", UITableViewCellAccessoryNone);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (UITableViewCell *)packageCardCellForTableView:(UITableView *)tableView package:(NSDictionary *)package {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = [DFPrimaryColor() colorWithAlphaComponent:0.12];
    iconBox.layer.cornerRadius = 14.0;
    iconBox.clipsToBounds = YES;
    UIImage *packageImage = DFPackageIconImage(package, self.currentRepo);
    UIImageView *icon = [[UIImageView alloc] initWithImage:packageImage ?: RKSymbol(@"shippingbox.fill")];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = packageImage ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    icon.tintColor = DFPrimaryColor();
    icon.clipsToBounds = YES;
    [iconBox addSubview:icon];
    UILabel *title = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor, 1);
    title.text = RKStringValue(package[@"name"] ?: package[@"package"]);
    UILabel *subtitle = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.secondaryLabelColor, 1);
    subtitle.text = [NSString stringWithFormat:@"%@ · %@ · %@", RKStringValue(package[@"version"]), RKStringValue(package[@"architecture"] ?: @"-"), DFSectionForPackage(package)];
    DFPackageStatus status = [self statusForPackage:package];
    UILabel *badge = DFLabel([UIFont systemFontOfSize:11 weight:UIFontWeightBold], UIColor.whiteColor, 1);
    badge.text = DFStatusTitle(status);
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = DFStatusColor(status);
    badge.layer.cornerRadius = 9.0;
    badge.layer.masksToBounds = YES;
    [card addSubview:iconBox];
    [card addSubview:title];
    [card addSubview:subtitle];
    [card addSubview:badge];
    if (status == DFPackageStatusBuilding) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        spinner.color = DFPrimaryColor();
        [spinner startAnimating];
        [card addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
            [spinner.centerYAnchor constraintEqualToAnchor:subtitle.centerYAnchor]
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconBox.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconBox.widthAnchor constraintEqualToConstant:56],
        [iconBox.heightAnchor constraintEqualToConstant:56],
        [icon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToConstant:28],
        [title.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:14],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-10],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [badge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [badge.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [badge.widthAnchor constraintGreaterThanOrEqualToConstant:72],
        [badge.heightAnchor constraintEqualToConstant:22]
    ]];
    return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *visible = [self visiblePackages];
    if (!visible.count) return [self emptyCellForTableView:tableView];
    return [self packageCardCellForTableView:tableView package:visible[(NSUInteger)indexPath.row]];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *visible = [self visiblePackages];
    if (!visible.count) return;
    DFPackageDetailVC *detail = [[DFPackageDetailVC alloc] initWithPackage:visible[(NSUInteger)indexPath.row] repoID:self.currentRepoID ?: @""];
    [self.navigationController pushViewController:detail animated:YES];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self visiblePackages].count > 0 && !self.helperRunning;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *visible = [self visiblePackages];
    if (editingStyle == UITableViewCellEditingStyleDelete && visible.count) {
        NSDictionary *pkg = visible[(NSUInteger)indexPath.row];
        [self runHelper:@[@"remove", self.currentRepoID ?: @"", RKStringValue(pkg[@"package"]), RKStringValue(pkg[@"version"]), @"--delete-file"] refresh:YES];
    }
}
@end


@implementation DFInstalledPackagePickerVC {
    NSString *_repoID;
    NSArray<NSDictionary *> *_installedPackages;
    NSString *_searchQuery;
    BOOL _loading;
    NSMutableSet<NSString *> *_selectedPackageIDs;
    UIBarButtonItem *_importButton;
    UIBarButtonItem *_refreshButton;
}

- (instancetype)initWithRepoID:(NSString *)repoID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _repoID = [repoID copy];
        _selectedPackageIDs = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Installed Packages");
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _importButton = [[UIBarButtonItem alloc] initWithTitle:RKLoc(@"Import") style:UIBarButtonItemStyleDone target:self action:@selector(confirmImportSelectedPackages)];
    _refreshButton = [[UIBarButtonItem alloc] initWithImage:RKSymbol(@"arrow.clockwise") style:UIBarButtonItemStylePlain target:self action:@selector(loadInstalledPackages)];
    self.navigationItem.rightBarButtonItems = @[_importButton, _refreshButton];
    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    searchController.searchResultsUpdater = self;
    searchController.obscuresBackgroundDuringPresentation = NO;
    searchController.searchBar.placeholder = RKLoc(@"Search Installed Packages");
    self.navigationItem.searchController = searchController;
    self.definesPresentationContext = YES;
    [self updateSelectionUI];
    [self loadInstalledPackages];
}

- (void)updateSelectionUI {
    NSUInteger count = _selectedPackageIDs.count;
    _importButton.title = count ? [NSString stringWithFormat:@"%@ (%lu)", RKLoc(@"Import"), (unsigned long)count] : RKLoc(@"Import");
    _importButton.enabled = !_loading && count > 0;
    _refreshButton.enabled = !_loading;
}

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    [self updateSelectionUI];
    [self.tableView reloadData];
}

- (void)loadInstalledPackages {
    if (_loading) return;
    [_selectedPackageIDs removeAllObjects];
    [self setLoading:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        RKHelperResult *result = [[RKHelperClient sharedClient] runArguments:@[@"installed"]];
        NSArray *items = @[];
        if (result.exitCode == 0 && result.output.length) {
            NSData *data = [result.output dataUsingEncoding:NSUTF8StringEncoding];
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([object isKindOfClass:[NSArray class]]) items = object;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_installedPackages = items ?: @[];
            [self setLoading:NO];
            if (result.exitCode != 0) [self showMessage:result.output.length ? result.output : RKLoc(@"Failed") title:RKLoc(@"Failed")];
        });
    });
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)visiblePackages {
    NSString *query = [_searchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return _installedPackages ?: @[];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *item in _installedPackages ?: @[]) {
        NSArray *fields = @[RKStringValue(item[@"package"]), RKStringValue(item[@"version"]), RKStringValue(item[@"architecture"]), RKStringValue(item[@"section"]), RKStringValue(item[@"summary"])] ;
        NSString *haystack = [[fields componentsJoinedByString:@"\n"] lowercaseString];
        if ([haystack containsString:query.lowercaseString]) [matches addObject:item];
    }
    return matches;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _searchQuery = searchController.searchBar.text ?: @"";
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_loading) return 1;
    return MAX([self visiblePackages].count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_loading) {
        UITableViewCell *cell = RKCell(tableView, RKLoc(@"Loading"), RKLoc(@"Reading installed packages"), @"hourglass", UITableViewCellAccessoryNone);
        RKSetCellLoading(cell, YES);
        return cell;
    }
    NSArray *visible = [self visiblePackages];
    if (!visible.count) {
        UITableViewCell *cell = RKCell(tableView, RKLoc(@"No Results"), RKLoc(@"No Matching Packages"), @"shippingbox", UITableViewCellAccessoryNone);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *item = visible[(NSUInteger)indexPath.row];
    NSString *packageID = RKStringValue(item[@"package"]);
    NSString *detail = [NSString stringWithFormat:@"%@ · %@ · %@", RKStringValue(item[@"version"]), RKStringValue(item[@"architecture"]), RKStringValue(item[@"section"] ?: RKLoc(@"Uncategorized"))];
    UITableViewCell *cell = RKCell(tableView, packageID, detail, @"shippingbox.fill", [_selectedPackageIDs containsObject:packageID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone);
    cell.detailTextLabel.numberOfLines = 3;
    if (RKStringValue(item[@"summary"]).length) cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", detail, RKStringValue(item[@"summary"])] ;
    return RKSetCellEnabled(cell, !_loading);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *visible = [self visiblePackages];
    if (_loading || !visible.count) return;
    NSString *packageID = RKStringValue(visible[(NSUInteger)indexPath.row][@"package"]);
    if (!packageID.length) return;
    if ([_selectedPackageIDs containsObject:packageID]) [_selectedPackageIDs removeObject:packageID];
    else [_selectedPackageIDs addObject:packageID];
    [self updateSelectionUI];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSArray<NSString *> *)selectedPackageIDs {
    return [[_selectedPackageIDs allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)confirmImportSelectedPackages {
    NSArray<NSString *> *packageIDs = [self selectedPackageIDs];
    if (!packageIDs.count || _loading) {
        [self showMessage:RKLoc(@"No Packages Selected") title:RKLoc(@"Import Installed Package")];
        return;
    }
    NSString *message = [NSString stringWithFormat:RKLoc(@"Repack Installed Packages Message"), (unsigned long)packageIDs.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"Import Installed Package") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"Import") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self importInstalledPackages:packageIDs];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importInstalledPackages:(NSArray<NSString *> *)packageIDs {
    if (!packageIDs.count || _loading) return;
    [self setLoading:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"repack-installed", self->_repoID ?: @"", nil];
        [arguments addObjectsFromArray:packageIDs];
        RKHelperResult *result = [[RKHelperClient sharedClient] runArguments:arguments];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            BOOL ok = result.exitCode == 0;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:ok ? RKLoc(@"Done") : RKLoc(@"Failed") message:result.output.length ? result.output : (ok ? RKLoc(@"Done") : RKLoc(@"Failed")) preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"OK") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if (ok) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:RKDataDidChangeNotification object:nil];
                    [self.navigationController popViewControllerAnimated:YES];
                }
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

@interface DFPublishVC : RKBaseTableViewController
@property (nonatomic, assign) BOOL logExpanded;
@property (nonatomic, weak) UITextView *logTextView;
@end

@implementation DFPublishVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Publish");
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
- (UITextView *)df_logTextView { return self.logTextView; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 188.0;
    if (indexPath.section == 1) return 190.0;
    return self.logExpanded ? 226.0 : 64.0;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return RKLoc(@"Publish Workflow");
    return nil;
}
- (UITableViewCell *)statusCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];

    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = [DFPrimaryColor() colorWithAlphaComponent:0.12];
    iconBox.layer.cornerRadius = 16.0;
    iconBox.clipsToBounds = YES;
    UIImage *sourceImage = DFSourceIconImage(self.currentRepo);
    UIImageView *icon = [[UIImageView alloc] initWithImage:sourceImage ?: RKSymbol(@"paperplane.fill")];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = sourceImage ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    icon.tintColor = DFPrimaryColor();
    icon.clipsToBounds = YES;
    [iconBox addSubview:icon];

    NSDictionary *github = [self.currentRepo[@"github"] isKindOfClass:[NSDictionary class]] ? self.currentRepo[@"github"] : @{};
    UILabel *title = DFLabel([UIFont systemFontOfSize:26 weight:UIFontWeightBold], UIColor.labelColor, 1);
    title.text = self.currentRepo ? RKStringValue(self.currentRepo[@"name"] ?: self.currentRepo[@"id"]) : RKLoc(@"Choose or import a source first");
    UILabel *base = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.secondaryLabelColor, 2);
    base.text = self.currentRepo ? RKStringValue(self.currentRepo[@"baseURL"] ?: RKLoc(@"Not Configured")) : RKLoc(@"No Sources");
    UILabel *remote = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], UIColor.secondaryLabelColor, 2);
    remote.text = [NSString stringWithFormat:@"GitHub: %@", RKStringValue(github[@"remote"] ?: RKLoc(@"Not Configured"))];
    UILabel *meta = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], UIColor.secondaryLabelColor, 1);
    meta.text = [NSString stringWithFormat:@"%@: %@ · %@: %@", RKLoc(@"Branch"), RKStringValue(github[@"branch"] ?: @"main"), RKLoc(@"Last Build"), RKStringValue(self.currentRepo[@"lastBuildAt"] ?: RKLoc(@"Not Built"))];
    for (UIView *view in @[iconBox, title, base, remote, meta]) [card addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [iconBox.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [iconBox.widthAnchor constraintEqualToConstant:62],
        [iconBox.heightAnchor constraintEqualToConstant:62],
        [icon.leadingAnchor constraintEqualToAnchor:iconBox.leadingAnchor],
        [icon.trailingAnchor constraintEqualToAnchor:iconBox.trailingAnchor],
        [icon.topAnchor constraintEqualToAnchor:iconBox.topAnchor],
        [icon.bottomAnchor constraintEqualToAnchor:iconBox.bottomAnchor],
        [title.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [base.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [base.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [base.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [remote.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [remote.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [remote.topAnchor constraintEqualToAnchor:iconBox.bottomAnchor constant:18],
        [meta.leadingAnchor constraintEqualToAnchor:remote.leadingAnchor],
        [meta.trailingAnchor constraintEqualToAnchor:remote.trailingAnchor],
        [meta.topAnchor constraintEqualToAnchor:remote.bottomAnchor constant:8]
    ]];
    return cell;
}
- (UITableViewCell *)workflowCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UIStackView *outer = [[UIStackView alloc] initWithFrame:CGRectZero];
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    outer.axis = UILayoutConstraintAxisVertical;
    outer.spacing = 10.0;
    outer.distribution = UIStackViewDistributionFillEqually;
    [card addSubview:outer];
    NSArray *items = @[
        @[RKLoc(@"Check Source"), @"checkmark.seal", DFSuccessColor()],
        @[RKLoc(@"Build Index"), @"hammer", DFPrimaryColor()],
        @[RKLoc(@"GitHub Settings"), @"gearshape", DFPrimaryColor()],
        @[RKLoc(@"Push GitHub"), @"paperplane", DFPrimaryColor()]
    ];
    for (NSUInteger row = 0; row < 2; row++) {
        UIStackView *inner = [[UIStackView alloc] initWithFrame:CGRectZero];
        inner.axis = UILayoutConstraintAxisHorizontal;
        inner.spacing = 10.0;
        inner.distribution = UIStackViewDistributionFillEqually;
        [outer addArrangedSubview:inner];
        for (NSUInteger col = 0; col < 2; col++) {
            NSUInteger index = row * 2 + col;
            UIButton *button = DFActionButton(items[index][0], items[index][1], items[index][2]);
            button.tag = (NSInteger)index;
            button.enabled = !self.helperRunning;
            button.alpha = self.helperRunning ? 0.45 : 1.0;
            [button addTarget:self action:@selector(publishActionTapped:) forControlEvents:UIControlEventTouchUpInside];
            [inner addArrangedSubview:button];
        }
    }
    if (self.helperRunning) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [spinner startAnimating];
        [card addSubview:spinner];
        [NSLayoutConstraint activateConstraints:@[
            [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [spinner.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [outer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [outer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [outer.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [outer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
    ]];
    return cell;
}
- (UITableViewCell *)publishLogCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UILabel *title = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor, 1);
    title.text = RKLoc(@"Logs");
    UIImageView *arrow = [[UIImageView alloc] initWithImage:RKSymbol(self.logExpanded ? @"chevron.up" : @"chevron.down")];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.tintColor = UIColor.secondaryLabelColor;
    [card addSubview:title];
    [card addSubview:arrow];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [arrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [arrow.centerYAnchor constraintEqualToAnchor:title.centerYAnchor]
    ]];
    if (self.logExpanded) {
        UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
        textView.translatesAutoresizingMaskIntoConstraints = NO;
        textView.editable = NO;
        textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        textView.text = self.lastOutput.length ? self.lastOutput : RKLoc(@"No Output");
        textView.backgroundColor = DFCardInsetBackgroundColor();
        textView.layer.cornerRadius = 10.0;
        self.logTextView = textView;
        [card addSubview:textView];
        [NSLayoutConstraint activateConstraints:@[
            [textView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [textView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
            [textView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
        ]];
    }
    return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self statusCellForTableView:tableView];
    if (indexPath.section == 1) return [self workflowCellForTableView:tableView];
    return [self publishLogCellForTableView:tableView];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        self.logExpanded = !self.logExpanded;
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}
- (void)publishActionTapped:(UIButton *)sender {
    if (self.helperRunning) return;
    if (!self.currentRepoID.length) { [self showMessage:RKLoc(@"Choose or import a source first") title:RKLoc(@"RepoKit")]; return; }
    self.logExpanded = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self df_appendLog:RKLoc(@"Executing...") toTextView:self.logTextView];
    if (sender.tag == 0) [self runHelper:@[@"check", self.currentRepoID] refresh:NO];
    else if (sender.tag == 1) [self runHelper:@[@"build", self.currentRepoID] refresh:YES];
    else if (sender.tag == 2) [self showGithubEditor];
    else if (sender.tag == 3) [self showPushForm];
}
@end

@interface DFTutorialVC : UITableViewController
@end

@implementation DFTutorialVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"Tutorial");
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 132.0;
}
- (NSArray<NSDictionary *> *)items {
    return @[
        @{@"title": RKLoc(@"Tutorial RepoKit Logic"), @"text": RKLoc(@"Tutorial RepoKit Logic Text"), @"symbol": @"gearshape.2"},
        @{@"title": RKLoc(@"Tutorial Jailbreak Compatibility"), @"text": RKLoc(@"Tutorial Jailbreak Compatibility Text"), @"symbol": @"iphone.and.arrow.forward"},
        @{@"title": RKLoc(@"Tutorial Project Structure"), @"text": RKLoc(@"Tutorial Project Structure Text"), @"symbol": @"folder"},
        @{@"title": RKLoc(@"Tutorial Repository Structure"), @"text": RKLoc(@"Tutorial Repository Structure Text"), @"symbol": @"externaldrive"},
        @{@"title": RKLoc(@"Create Source"), @"text": RKLoc(@"Tutorial Create Source Text"), @"symbol": @"tray.full"},
        @{@"title": RKLoc(@"Import Existing Source"), @"text": RKLoc(@"Tutorial Import Source Text"), @"symbol": @"square.and.arrow.down"},
        @{@"title": RKLoc(@"Manage Sources"), @"text": RKLoc(@"Tutorial Manage Sources Text"), @"symbol": @"tray.2"},
        @{@"title": RKLoc(@"Manage Deb Packages"), @"text": RKLoc(@"Tutorial Manage Deb Packages Text"), @"symbol": @"shippingbox"},
        @{@"title": RKLoc(@"Build Index"), @"text": RKLoc(@"Tutorial Build Index Text"), @"symbol": @"hammer"},
        @{@"title": RKLoc(@"Tutorial Install Dependencies"), @"text": RKLoc(@"Tutorial Install Dependencies Text"), @"symbol": @"shippingbox.and.arrow.backward"},
        @{@"title": RKLoc(@"Tutorial SSH Key"), @"text": RKLoc(@"Tutorial SSH Key Text"), @"symbol": @"key"},
        @{@"title": RKLoc(@"Tutorial GitHub Setup"), @"text": RKLoc(@"Tutorial GitHub Setup Text"), @"symbol": @"globe"},
        @{@"title": RKLoc(@"Publish with GitHub"), @"text": RKLoc(@"Tutorial Publish GitHub Text"), @"symbol": @"paperplane"},
        @{@"title": RKLoc(@"Tutorial Roothide Check"), @"text": RKLoc(@"Tutorial Roothide Check Text"), @"symbol": @"checkmark.shield"},
        @{@"title": RKLoc(@"Add Source to Sileo"), @"text": RKLoc(@"Tutorial Sileo Text"), @"symbol": @"safari"},
        @{@"title": RKLoc(@"Troubleshooting"), @"text": RKLoc(@"Tutorial Troubleshooting Text"), @"symbol": @"wrench.and.screwdriver"}
    ];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self items].count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewAutomaticDimension; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *item = [self items][(NSUInteger)indexPath.row];
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    DFApplyCardStyle(card);
    [cell.contentView addSubview:card];
    UIView *iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = [DFPrimaryColor() colorWithAlphaComponent:0.12];
    iconBox.layer.cornerRadius = 12.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:RKSymbol(item[@"symbol"] ?: @"book")];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = DFPrimaryColor();
    [iconBox addSubview:icon];
    UILabel *title = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleHeadline], UIColor.labelColor, 1);
    title.text = RKStringValue(item[@"title"]);
    UILabel *body = DFLabel([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], UIColor.secondaryLabelColor, 0);
    body.text = RKStringValue(item[@"text"]);
    [card addSubview:iconBox];
    [card addSubview:title];
    [card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconBox.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [iconBox.widthAnchor constraintEqualToConstant:44],
        [iconBox.heightAnchor constraintEqualToConstant:44],
        [icon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22],
        [icon.heightAnchor constraintEqualToConstant:22],
        [title.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:14],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [body.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];
    return cell;
}
@end

@implementation RKRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tabBar.tintColor = DFPrimaryColor();
    if (@available(iOS 13.0, *)) {
        self.tabBar.backgroundColor = UIColor.systemBackgroundColor;
        self.tabBar.unselectedItemTintColor = UIColor.secondaryLabelColor;
    }

    DFSourceOverviewVC *sources = [[DFSourceOverviewVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    DFPackageListVC *packages = [[DFPackageListVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    DFPublishVC *publish = [[DFPublishVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    DFTutorialVC *tutorial = [[DFTutorialVC alloc] initWithStyle:UITableViewStyleInsetGrouped];

    UINavigationController *sourcesNav = [[UINavigationController alloc] initWithRootViewController:sources];
    UINavigationController *packagesNav = [[UINavigationController alloc] initWithRootViewController:packages];
    UINavigationController *publishNav = [[UINavigationController alloc] initWithRootViewController:publish];
    UINavigationController *tutorialNav = [[UINavigationController alloc] initWithRootViewController:tutorial];

    sourcesNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:RKLoc(@"Sources") image:RKSymbol(@"tray.full") selectedImage:RKSymbol(@"tray.full.fill")];
    packagesNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:RKLoc(@"Packages") image:RKSymbol(@"shippingbox") selectedImage:RKSymbol(@"shippingbox.fill")];
    publishNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:RKLoc(@"Publish") image:RKSymbol(@"paperplane") selectedImage:RKSymbol(@"paperplane.fill")];
    tutorialNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:RKLoc(@"Tutorial") image:RKSymbol(@"questionmark.circle") selectedImage:RKSymbol(@"questionmark.circle.fill")];
    self.viewControllers = @[sourcesNav, packagesNav, publishNav, tutorialNav];
}

@end
