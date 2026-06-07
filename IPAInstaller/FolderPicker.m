#import "FolderPicker.h"
#import "CollectionStore.h"
#import "Localization.h"

@interface FolderPicker () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) NSArray *folderIds;     // parallel to the action-sheet folder buttons
@property (nonatomic, assign) NSInteger newFolderIndex;
@property (nonatomic, strong) FolderPicker *selfRef;  // keep alive across the async sheet/alert
@end

@implementation FolderPicker {
    // iOS 3: blocks aren't ObjC objects, so a synthesized @property(copy) block
    // setter calls objc_setProperty(copy=YES) → -copyWithZone: on the block →
    // Bus error (signal 10). Back the block manually through the C blocks runtime
    // (_Block_copy/_Block_release) — see AppDropBlocks.h (AD_BLOCK_ACCESSORS).
    void (^_completionBlock)(NSString *);
}
@dynamic completion;
AD_BLOCK_ACCESSORS(completion, setCompletion, _completionBlock, void(^)(NSString *))

- (void)dealloc {
    if (_completionBlock) _Block_release((const void *)_completionBlock);
    [super dealloc];
}

+ (void)presentAddToFolderFrom:(UIViewController *)vc completion:(void (^)(NSString *))completion {
    FolderPicker *p = [[FolderPicker alloc] init];
    p.completion = completion;
    p.selfRef = p;                       // retain until we finish

    NSArray *folders = [[CollectionStore shared] folders];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:T(@"folder.add_title")
        delegate:p cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *f in folders) {
        [sheet addButtonWithTitle:([f[@"name"] length] ? f[@"name"] : T(@"folder.untitled"))];
        [ids addObject:f[@"id"]];
    }
    p.folderIds = ids;
    p.newFolderIndex = [sheet addButtonWithTitle:T(@"folder.new")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:T(@"common.cancel")];
    [sheet showInView:vc.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == sheet.cancelButtonIndex) { [self finish:nil]; return; }
    if (index == self.newFolderIndex) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:T(@"folder.new") message:nil
            delegate:self cancelButtonTitle:T(@"common.cancel") otherButtonTitles:T(@"folder.create"), nil];
        if ([a respondsToSelector:@selector(setAlertViewStyle:)]) a.alertViewStyle = UIAlertViewStylePlainTextInput;
        [a show];
        return;
    }
    if (index >= 0 && index < (NSInteger)self.folderIds.count) [self finish:self.folderIds[index]];
    else [self finish:nil];
}

- (void)alertView:(UIAlertView *)av clickedButtonAtIndex:(NSInteger)index {
    if (index == av.cancelButtonIndex) { [self finish:nil]; return; }
    NSString *name = [[av textFieldAtIndex:0] text];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) { [self finish:nil]; return; }
    [self finish:[[CollectionStore shared] createFolderNamed:name]];
}

- (void)finish:(NSString *)cid {
    if (self.completion) self.completion(cid);
    self.completion = nil;
    self.selfRef = nil;   // release
}

@end
