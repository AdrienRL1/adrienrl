#import <UIKit/UIKit.h>

@interface CatalogViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
// v3.2 : si défini (ex. @"downloads"), force ce tri à l'ouverture SANS toucher au filtre sauvegardé.
// Utilisé par le raccourci d'accueil « Plus téléchargées ».
@property (nonatomic, copy) NSString *initialSort;
@end
