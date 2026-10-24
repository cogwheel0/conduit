package app.cogwheel.conduit

import android.service.voice.VoiceInteractionService

/**
 * The service Android binds while Conduit is the default digital assistant.
 * Its sessions come from [ConduitAssistSessionService].
 *
 * The name is historical: this class used to be the session service, and
 * Android remembers the chosen assistant by this class name, so renaming it
 * would unset Conduit as the assistant when the app updates.
 */
class ConduitVoiceInteractionSessionService : VoiceInteractionService()
