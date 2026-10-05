// Coordination with EeveeSpotify in the personal combined build.
// spoti.pw owns UI/player/lyrics/flags; Eevee keeps Premium, ads and privacy.
#import <Foundation/Foundation.h>

BOOL SGEeveePresent(void);
void SGEeveeApplyIntegration(void);
BOOL SGEeveeIntegrationConfigured(void);
NSString *SGEeveeIntegrationSummary(void);
