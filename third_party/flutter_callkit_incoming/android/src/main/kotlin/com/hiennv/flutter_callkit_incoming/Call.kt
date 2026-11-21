package com.hiennv.flutter_callkit_incoming

import android.os.Bundle
import com.fasterxml.jackson.annotation.JsonProperty

@Suppress("UNCHECKED_CAST")
data class Data(val args: Map<String, Any?>) {

    constructor() : this(emptyMap())


    @JsonProperty("id")
    var id: String = (args["id"] as? String) ?: ""

    @JsonProperty("nameCaller")
    var nameCaller: String = (args["nameCaller"] as? String) ?: ""

    @JsonProperty("appName")
    var appName: String = (args["appName"] as? String) ?: ""

    @JsonProperty("avatar")
    var avatar: String = (args["avatar"] as? String) ?: ""

    @JsonProperty("handle")
    var handle: String = (args["handle"] as? String) ?: ""

    @JsonProperty("type")
    var type: Int = (args["type"] as? Int) ?: 0

    @JsonProperty("duration")
    var duration: Long =
        (args["duration"] as? Long) ?: ((args["duration"] as? Int)?.toLong() ?: 30000L)

    @JsonProperty("isAccepted")
    var isAccepted: Boolean = false

    @JsonProperty("textAccept")
    var textAccept: String = ""

    @JsonProperty("textDecline")
    var textDecline: String = ""

    // NotificationParams: missedCallNotification params

    @JsonProperty("missedNotificationId")
    var missedNotificationId: Int? = null

    @JsonProperty("isShowMissedCallNotification")
    var isShowMissedCallNotification: Boolean = true

    @JsonProperty("missedNotificationSubtitle")
    var missedNotificationSubtitle: String? = null

    @JsonProperty("missedNotificationCallbackText")
    var missedNotificationCallbackText: String? = null

    @JsonProperty("isShowCallback")
    var isShowCallback: Boolean = true

    @JsonProperty("missedNotificationCount")
    var missedNotificationCount: Int = 1

    // NotificationParams: callingNotification params

    @JsonProperty("callingNotificationId")
    var callingNotificationId: String? = null

    @JsonProperty("isShowCallingNotification")
    var isShowCallingNotification: Boolean = true

    @JsonProperty("callingNotificationSubtitle")
    var callingNotificationSubtitle: String? = null

    @JsonProperty("callingNotificationCallbackText")
    var callingNotificationHangupText: String? = null

    @JsonProperty("isShowHangup")
    var isShowHangup: Boolean = true

    // Extra params

    @JsonProperty("extra")
    var extra: HashMap<String, Any?> =
        (args["extra"] ?: HashMap<String, Any?>()) as HashMap<String, Any?>

    @JsonProperty("headers")
    var headers: HashMap<String, Any?> =
        (args["headers"] ?: HashMap<String, Any?>()) as HashMap<String, Any?>

    // Android params

    @JsonProperty("isCustomNotification")
    var isCustomNotification: Boolean = false

    @JsonProperty("isCustomSmallExNotification")
    var isCustomSmallExNotification: Boolean = false

    @JsonProperty("isShowLogo")
    var isShowLogo: Boolean = false

    @JsonProperty("logoUrl")
    var logoUrl: String

    @JsonProperty("isShowCallID")
    var isShowCallID: Boolean = false

    @JsonProperty("ringtonePath")
    var ringtonePath: String

    @JsonProperty("backgroundColor")
    var backgroundColor: String

    @JsonProperty("backgroundUrl")
    var backgroundUrl: String

    @JsonProperty("actionColor")
    var actionColor: String

    @JsonProperty("textColor")
    var textColor: String

    @JsonProperty("incomingCallNotificationChannelName")
    var incomingCallNotificationChannelName: String? = null

    @JsonProperty("missedCallNotificationChannelName")
    var missedCallNotificationChannelName: String? = null

    @JsonProperty("isShowFullLockedScreen")
    var isShowFullLockedScreen: Boolean = true

    @JsonProperty("isImportant")
    var isImportant: Boolean = false

    @JsonProperty("isBot")
    var isBot: Boolean = false

    @JsonProperty("isFullScreen")
    var isFullScreen: Boolean = false

    @JsonProperty("from")
    var from: String = ""

    init {
        var android: Map<String, Any?>? = args["android"] as? HashMap<String, Any?>?
        android = android ?: args
        isCustomNotification = android["isCustomNotification"] as? Boolean ?: false
        isCustomSmallExNotification = android["isCustomSmallExNotification"] as? Boolean ?: false
        isShowLogo = android["isShowLogo"] as? Boolean ?: false
        logoUrl = android["logoUrl"] as? String ?: ""
        isShowCallID = android["isShowCallID"] as? Boolean ?: false
        ringtonePath = android["ringtonePath"] as? String ?: ""
        backgroundColor = android["backgroundColor"] as? String ?: "#0955fa"
        backgroundUrl = android["backgroundUrl"] as? String ?: ""
        actionColor = android["actionColor"] as? String ?: "#4CAF50"
        textColor = android["textColor"] as? String ?: "#ffffff"
        incomingCallNotificationChannelName =
            android["incomingCallNotificationChannelName"] as? String
        missedCallNotificationChannelName = android["missedCallNotificationChannelName"] as? String
        isShowFullLockedScreen = android["isShowFullLockedScreen"] as? Boolean ?: true
        isImportant = android["isImportant"] as? Boolean ?: false
        isBot = android["isBot"] as? Boolean ?: false
        isFullScreen = android["isFullScreen"] as? Boolean ?: false
        from = android["from"] as? String ?: ""
        textAccept = android["textAccept"] as? String ?: ""
        textDecline = android["textDecline"] as? String ?: ""


        val missedNotification: Map<String, Any?>? =
            args["missedCallNotification"] as? Map<String, Any?>?


        if (missedNotification != null) {
            missedNotificationId = missedNotification["id"] as? Int?
            missedNotificationSubtitle = missedNotification["subtitle"] as? String?
            missedNotificationCount = missedNotification["count"] as? Int? ?: 1
            missedNotificationCallbackText = missedNotification["callbackText"] as? String?
            isShowCallback = missedNotification["isShowCallback"] as? Boolean ?: true
            isShowMissedCallNotification =
                missedNotification["showNotification"] as? Boolean ?: true
        } else {
            missedNotificationSubtitle = args["textMissedCall"] as? String ?: ""
            missedNotificationCallbackText = args["textCallback"] as? String ?: ""
            isShowCallback = android["isShowCallback"] as? Boolean ?: true
            isShowMissedCallNotification =
                android["isShowMissedCallNotification"] as? Boolean ?: true
        }

        val callingNotification: Map<String, Any?>? =
            args["callingNotification"] as? Map<String, Any?>?

        if (callingNotification != null) {
            callingNotificationId = callingNotification["id"] as? String?
            callingNotificationSubtitle = callingNotification["subtitle"] as? String?
            //callingNotificationCount = missedNotification["count"] as? Int? ?: 1
            callingNotificationHangupText = callingNotification["callbackText"] as? String?
            isShowHangup = callingNotification["isShowCallback"] as? Boolean ?: true
            isShowCallingNotification =
                callingNotification["showNotification"] as? Boolean ?: true
        }


    }

    override fun hashCode(): Int {
        return id.hashCode()
    }

    override fun equals(other: Any?): Boolean {
        if (other == null) return false
        val e: Data = other as Data
        return this.id == e.id
    }


    fun toBundle(): Bundle {
        val bundle = Bundle()
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_ID, id)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, nameCaller)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_APP_NAME, appName)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_HANDLE, handle)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_AVATAR, avatar)
        bundle.putInt(CallkitConstants.EXTRA_CALLKIT_TYPE, type)
        bundle.putLong(CallkitConstants.EXTRA_CALLKIT_DURATION, duration)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_TEXT_ACCEPT, textAccept)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_TEXT_DECLINE, textDecline)

        missedNotificationId?.let {
            bundle.putInt(
                CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_ID,
                it
            )
        }
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SHOW,
            isShowMissedCallNotification
        )
        bundle.putInt(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_COUNT,
            missedNotificationCount
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SUBTITLE,
            missedNotificationSubtitle
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_SHOW,
            isShowCallback
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_TEXT,
            missedNotificationCallbackText
        )

        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_CALLING_ID,
            callingNotificationId
        )

        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_CALLING_SHOW,
            isShowCallingNotification
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_CALLING_SUBTITLE,
            callingNotificationSubtitle
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_SHOW,
            isShowHangup
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_TEXT,
            callingNotificationHangupText
        )


        bundle.putSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA, extra)
        bundle.putSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS, headers)

        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_NOTIFICATION,
            isCustomNotification
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_SMALL_EX_NOTIFICATION,
            isCustomSmallExNotification
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_SHOW_LOGO,
            isShowLogo
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_LOGO_URL,
            logoUrl
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID,
            isShowCallID
        )
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_RINGTONE_PATH, ringtonePath)
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_BACKGROUND_COLOR,
            backgroundColor
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_BACKGROUND_URL,
            backgroundUrl
        )
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_TEXT_COLOR, textColor)
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_ACTION_COLOR, actionColor)
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_INCOMING_CALL_NOTIFICATION_CHANNEL_NAME,
            incomingCallNotificationChannelName
        )
        bundle.putString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_NOTIFICATION_CHANNEL_NAME,
            missedCallNotificationChannelName
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_SHOW_FULL_LOCKED_SCREEN,
            isShowFullLockedScreen
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_IMPORTANT,
            isImportant,
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_BOT,
            isBot,
        )
        bundle.putBoolean(
            CallkitConstants.EXTRA_CALLKIT_IS_FULL_SCREEN,
            isFullScreen,
        )
        bundle.putString(CallkitConstants.EXTRA_CALLKIT_ACTION_FROM, from)
        return bundle
    }

    companion object {

        fun fromBundle(bundle: Bundle): Data {
            val data = Data(emptyMap())
            data.id = bundle.getString(CallkitConstants.EXTRA_CALLKIT_ID, "")
            data.nameCaller =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
            data.appName =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_APP_NAME, "")
            data.handle =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
            data.avatar =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
            data.type = bundle.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, 0)
            data.duration =
                bundle.getLong(CallkitConstants.EXTRA_CALLKIT_DURATION, 30000L)
            data.textAccept =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_ACCEPT, "")
            data.textDecline =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_DECLINE, "")
            data.isImportant =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_IMPORTANT, false)
            data.isBot =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_BOT, false)
            data.isFullScreen =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_FULL_SCREEN, false)

            data.missedNotificationId =
                bundle.getInt(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_ID)
            data.isShowMissedCallNotification =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SHOW, true)
            data.missedNotificationCount =
                bundle.getInt(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_COUNT, 1)
            data.missedNotificationSubtitle =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SUBTITLE, "")
            data.isShowCallback =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_SHOW, false)
            data.missedNotificationCallbackText =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_TEXT, "")


            data.callingNotificationId = bundle.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_ID)
            data.isShowCallingNotification =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_CALLING_SHOW, true)
            data.callingNotificationSubtitle =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_SUBTITLE, "")
            data.isShowHangup =
                bundle.getBoolean(CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_SHOW, false)
            data.callingNotificationHangupText =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_TEXT, "")


            data.extra =
                bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as HashMap<String, Any?>
            data.headers =
                bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>

            data.isCustomNotification = bundle.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_NOTIFICATION,
                false
            )
            data.isCustomSmallExNotification = bundle.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_SMALL_EX_NOTIFICATION,
                false
            )
            data.isShowLogo = bundle.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_IS_SHOW_LOGO,
                false
            )
            data.logoUrl =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_LOGO_URL, "")
            data.isShowCallID = bundle.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID,
                false
            )
            data.ringtonePath = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_RINGTONE_PATH,
                ""
            )
            data.backgroundColor = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_BACKGROUND_COLOR,
                "#0955fa"
            )
            data.backgroundUrl =
                bundle.getString(CallkitConstants.EXTRA_CALLKIT_BACKGROUND_URL, "")
            data.actionColor = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_ACTION_COLOR,
                "#4CAF50"
            )
            data.textColor = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_TEXT_COLOR,
                "#FFFFFF"
            )

            data.incomingCallNotificationChannelName = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_INCOMING_CALL_NOTIFICATION_CHANNEL_NAME
            )
            data.missedCallNotificationChannelName = bundle.getString(
                CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_NOTIFICATION_CHANNEL_NAME
            )
            data.isShowFullLockedScreen = bundle.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_IS_SHOW_FULL_LOCKED_SCREEN,
                true
            )
            data.from = bundle.getString(CallkitConstants.EXTRA_CALLKIT_ACTION_FROM, "")
            return data
        }
    }

}
