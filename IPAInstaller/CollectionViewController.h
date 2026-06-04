#import <UIKit/UIKit.h>
#import "IOS6Theme.h"

// Shows the apps inside ONE collection (the built-in Favoris, or a folder in Phase 4):
//   • tap a row → app detail,
//   • "Sélectionner" → multi-select mode with a bottom toolbar: Tout sélectionner / Télécharger
//     (batch, via InstallManager) / Retirer,
//   • "Image" → pin one app as the tile's fixed preview image, or reset to the auto mosaic.
@interface CollectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, ADThemable>

- (instancetype)initWithCollectionId:(NSString *)collectionId;

@end
