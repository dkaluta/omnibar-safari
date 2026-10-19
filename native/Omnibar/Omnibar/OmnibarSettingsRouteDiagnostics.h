#ifndef OMNIBAR_SETTINGS_ROUTE_DIAGNOSTICS
#define OMNIBAR_SETTINGS_ROUTE_DIAGNOSTICS 0
#endif

// Local diagnostic builds only. Values identify fixed code stages, never user
// input, settings, URLs, bundle identifiers, or system error descriptions.
#if OMNIBAR_SETTINGS_ROUTE_DIAGNOSTICS
#import <os/log.h>
#import <dispatch/dispatch.h>

static inline void OmnibarTraceSettingsRoute(unsigned int stage) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.dkaluta.omnibar.settings-route", "stages");
    });
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "stage=%{public}u", stage);
}
#else
#define OmnibarTraceSettingsRoute(stage) ((void)0)
#endif
