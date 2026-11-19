// The app's side of the App Intents bridge, as Swift sees it
// (`-import-objc-header`). Defined in Rust: crates/app/src/intents.rs.
#ifndef CONDUIT_INTENTS_BRIDGE_H
#define CONDUIT_INTENTS_BRIDGE_H

/// Called once, on any thread, with the JSON response and the `context`
/// the request carried.
typedef void (*ConduitIntentsReply)(void *_Nullable context,
                                    const char *_Nullable response);

/// Hands the app one JSON request (`IntentRequest`); `reply` comes back
/// once, whatever happens, even when the app quits first.
void conduit_intents_request(const char *_Nonnull request,
                             void *_Nullable context,
                             ConduitIntentsReply _Nonnull reply);

#endif
