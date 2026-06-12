#import <Foundation/Foundation.h>

// v3.2 — Client des statistiques (HORS serveur Unraid : Cloudflare Worker + D1).
// Centralise : identifiant anonyme local, battement « utilisateurs actifs », table des
// nombres de téléchargements par app, et enregistrement d'un téléchargement.
// L'URL et le D1 sont gérés par le Worker `appdrop-stats` ; ici on ne fait que des appels HTTPS.

// Posté sur la file principale quand le nombre d'utilisateurs actifs change. userInfo @{ @"active": NSNumber }.
extern NSString *const StatsActiveUsersChangedNotification;
// Posté sur la file principale quand la table des téléchargements vient d'être rafraîchie.
extern NSString *const StatsDownloadsChangedNotification;

@interface StatsClient : NSObject

+ (instancetype)shared;

// Identifiant anonyme, stable, purement local (aucune donnée perso). Sert au heartbeat + anti-double.
- (NSString *)deviceID;

// Envoie un battement anonyme → renvoie le nombre d'utilisateurs actifs (completion sur la file principale,
// active = -1 en cas d'échec). Met aussi à jour le cache + poste StatsActiveUsersChangedNotification.
- (void)sendHeartbeatWithCompletion:(void (^)(NSInteger active))completion;
// Dernier nombre d'utilisateurs actifs connu (-1 si jamais reçu).
- (NSInteger)cachedActiveUsers;

// Récupère {bid:count} depuis le Worker, met en cache (plist), fusionne dans la base du
// catalogue (pour le tri SQL + les icônes du top) et poste StatsDownloadsChangedNotification.
- (void)refreshDownloads;

// Nombre de téléchargements connu pour un bundle id (-1 si inconnu). Lecture mémoire instantanée.
- (NSInteger)downloadsForBundleId:(NSString *)bid;

// Enregistre un téléchargement (anti-double côté serveur). +1 optimiste local + notification.
- (void)recordDownloadForBundleId:(NSString *)bid;

@end
