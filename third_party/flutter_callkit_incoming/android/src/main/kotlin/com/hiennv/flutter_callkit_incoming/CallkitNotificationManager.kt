//  Modification by Signify in this file are under the following license:
//
//  Copyright 2024, Signify Holding
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

package com.hiennv.flutter_callkit_incoming

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.TextUtils
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import androidx.appcompat.app.AlertDialog
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import java.util.Date


class CallkitNotificationManager(
    private val context: Context,
    private val callkitSoundPlayerManager: CallkitSoundPlayerManager?
) {

    companion object {
        const val PERMISSION_NOTIFICATION_REQUEST_CODE = 6969

        const val EXTRA_TIME_START_CALL = "EXTRA_TIME_START_CALL"

        const val NOTIFICATION_CHANNEL_ID_INCOMING = "callkit_incoming_channel_id_v2"
        private const val LEGACY_NOTIFICATION_CHANNEL_ID_INCOMING = "callkit_incoming_channel_id"
        const val NOTIFICATION_CHANNEL_ID_ONGOING = "callkit_ongoing_channel_id"
        const val NOTIFICATION_CHANNEL_ID_MISSED = "callkit_missed_channel_id"

        private const val ACTION_VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION"
        private const val EXTRA_VOLUME_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
    }

    private var dataNotificationPermission: Map<String, Any> = HashMap()

    // Start Signify modification
    private var volumeKeyReceiver: VolumeKeyBroadcastReceiver? = null
    // End Signify modification

    private var notificationBuilder: NotificationCompat.Builder? = null
    private var notificationViews: RemoteViews? = null
    private var notificationSmallViews: RemoteViews? = null

    private var notificationMissingBuilder: NotificationCompat.Builder? = null
    private var notificationMissingViews: RemoteViews? = null
    private var notificationMissingSmallViews: RemoteViews? = null

    private var notificationOngoingBuilder: NotificationCompat.Builder? = null
    private var notificationOngoingViews: RemoteViews? = null
    private var notificationOngoingSmallViews: RemoteViews? = null


    private var targetInComingAvatarDefault: SafeTarget? = null
    private var targetInComingAvatarCustom: SafeTarget? = null

    private var targetMissingAvatarDefault: SafeTarget? = null
    private var targetMissingAvatarCustom: SafeTarget? = null

    private var targetOnGoingAvatarDefault: SafeTarget? = null
    private var targetOnGoingAvatarCustom: SafeTarget? = null


    @SuppressLint("MissingPermission")
    private fun createInComingAvatarTargetDefault(notificationId: Int): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationBuilder?.setLargeIcon(bitmap)
            notificationBuilder?.let { getNotificationManager().notify(notificationId, it.build()) }
        }) {}
    }

    @SuppressLint("MissingPermission")
    private fun createInComingAvatarTargetCustom(
        notificationId: Int,
        isCallStyle: Boolean = false
    ): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            notificationSmallViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationSmallViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            if (isCallStyle) notificationBuilder?.setLargeIcon(bitmap)
            notificationBuilder?.let { getNotificationManager().notify(notificationId, it.build()) }
        }) {}
    }

    @SuppressLint("MissingPermission")
    private fun createMissingAvatarTargetDefault(notificationId: Int): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationMissingBuilder?.setLargeIcon(bitmap)
            notificationMissingBuilder?.priority =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    NotificationManager.IMPORTANCE_LOW
                } else {
                    Notification.PRIORITY_LOW
                }
            notificationMissingBuilder?.let {
                getNotificationManager().notify(
                    notificationId, it.build()
                )
            }
        }) {}
    }

    @SuppressLint("MissingPermission")
    private fun createMissingAvatarTargetCustom(notificationId: Int): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationMissingViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationMissingViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            notificationMissingSmallViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationMissingSmallViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            notificationMissingBuilder?.priority =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    NotificationManager.IMPORTANCE_LOW
                } else {
                    Notification.PRIORITY_LOW
                }
            notificationMissingBuilder?.let {
                getNotificationManager().notify(
                    notificationId, it.build()
                )
            }
        }) {}
    }

    @SuppressLint("MissingPermission")
    private fun createOnGoingAvatarTargetDefault(notificationId: Int): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationOngoingBuilder?.setLargeIcon(bitmap)
            notificationOngoingBuilder?.let {
                getNotificationManager().notify(
                    notificationId, it.build()
                )
            }
        }) {}
    }

    @SuppressLint("MissingPermission")
    private fun createOnGoingAvatarTargetCustom(
        notificationId: Int,
        isCallStyle: Boolean = false
    ): SafeTarget {
        return object : SafeTarget(notificationId, onLoaded = { bitmap ->
            notificationOngoingViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationOngoingViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            notificationOngoingSmallViews?.setImageViewBitmap(R.id.ivAvatar, bitmap)
            notificationOngoingSmallViews?.setViewVisibility(R.id.ivAvatar, View.VISIBLE)
            if (isCallStyle) notificationOngoingBuilder?.setLargeIcon(bitmap)
            notificationOngoingBuilder?.let {
                getNotificationManager().notify(
                    notificationId, it.build()
                )
            }
        }) {}
    }

    @SuppressLint("MissingPermission")
    fun getIncomingNotification(data: Bundle): CallkitNotification? {
        data.putLong(EXTRA_TIME_START_CALL, System.currentTimeMillis())

        val notificationId =
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming").hashCode()
        createNotificationChanel(data)

        notificationBuilder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID_INCOMING)
        notificationBuilder?.setChannelId(NOTIFICATION_CHANNEL_ID_INCOMING)
        notificationBuilder?.setDefaults(NotificationCompat.DEFAULT_VIBRATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            notificationBuilder?.setCategory(NotificationCompat.CATEGORY_CALL)
            notificationBuilder?.priority = NotificationCompat.PRIORITY_MAX
        }
        notificationBuilder?.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        notificationBuilder?.setOngoing(true)
        notificationBuilder?.setAutoCancel(false)
        notificationBuilder?.setWhen(System.currentTimeMillis())
        notificationBuilder?.setTimeoutAfter(
            data.getLong(
                CallkitConstants.EXTRA_CALLKIT_DURATION, 0L
            )
        )
        notificationBuilder?.setOnlyAlertOnce(true)
        notificationBuilder?.setSound(null)
        notificationBuilder?.setFullScreenIntent(
            getActivityPendingIntent(notificationId, data), true
        )
        notificationBuilder?.setContentIntent(getActivityPendingIntent(notificationId, data))
        notificationBuilder?.setDeleteIntent(getTimeOutPendingIntent(notificationId, data))
        val typeCall = data.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, -1)
        var smallIcon = context.applicationInfo.icon
        if (typeCall > 0) {
            smallIcon = R.drawable.ic_video
        }
        notificationBuilder?.setSmallIcon(smallIcon)
        val actionColor = data.getString(CallkitConstants.EXTRA_CALLKIT_ACTION_COLOR, "#4CAF50")
        try {
            notificationBuilder?.color = Color.parseColor(actionColor)
        } catch (_: Exception) {
        }
        notificationBuilder?.setChannelId(NOTIFICATION_CHANNEL_ID_INCOMING)
        notificationBuilder?.priority = NotificationCompat.PRIORITY_MAX
        val isCustomNotification =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_NOTIFICATION, false)
        val isCustomSmallExNotification =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_SMALL_EX_NOTIFICATION, false)
        if (isCustomNotification) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {

                val caller = data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
                val person = Person.Builder().setName(caller).setImportant(
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_IMPORTANT, true)
                ).setBot(data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_BOT, false)).build()
                notificationBuilder?.setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        person,
                        getDeclinePendingIntent(notificationId, data),
                        getAcceptPendingIntent(notificationId, data),
                    ).setIsVideo(typeCall > 0)
                )
                val isShowCallID =
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
                if (isShowCallID) {
                    notificationBuilder?.setContentText(
                        data.getString(
                            CallkitConstants.EXTRA_CALLKIT_HANDLE, ""
                        )
                    )
                }
                var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
                if (!avatarUrl.isNullOrEmpty()) {
                    if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                            "https://",
                            true
                        )
                    ) {
                        avatarUrl =
                            String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                    }
                    val headers =
                        data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
                    if (targetInComingAvatarCustom == null) targetInComingAvatarCustom =
                        createInComingAvatarTargetCustom(notificationId, true)

                    ImageLoaderProvider.loadImage(
                        context,
                        avatarUrl,
                        headers,
                        targetInComingAvatarCustom
                    )

                }
            } else {
                notificationViews =
                    RemoteViews(context.packageName, R.layout.layout_custom_notification)
                initInComingNotificationViews(notificationId, notificationViews!!, data)

                if ((Build.MANUFACTURER.equals(
                        "Samsung", ignoreCase = true
                    ) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) || isCustomSmallExNotification
                ) {
                    notificationSmallViews = RemoteViews(
                        context.packageName, R.layout.layout_custom_small_ex_notification
                    )
                    initInComingNotificationViews(notificationId, notificationSmallViews!!, data)
                } else {
                    notificationSmallViews =
                        RemoteViews(context.packageName, R.layout.layout_custom_small_notification)
                    initInComingNotificationViews(notificationId, notificationSmallViews!!, data)
                }

                notificationBuilder?.setStyle(NotificationCompat.DecoratedCustomViewStyle())
                notificationBuilder?.setCustomContentView(notificationSmallViews)
                notificationBuilder?.setCustomBigContentView(notificationViews)
                notificationBuilder?.setCustomHeadsUpContentView(notificationSmallViews)
            }
        } else {
            notificationBuilder?.setContentText(
                data.getString(
                    CallkitConstants.EXTRA_CALLKIT_HANDLE, ""
                )
            )
            var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
            if (!avatarUrl.isNullOrEmpty()) {
                if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                        "https://",
                        true
                    )
                ) {
                    avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                }
                val headers =
                    data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
                if (targetInComingAvatarDefault == null) targetInComingAvatarDefault =
                    createInComingAvatarTargetDefault(notificationId)
                ImageLoaderProvider.loadImage(
                    context,
                    avatarUrl,
                    headers,
                    targetInComingAvatarDefault
                )
            }
            val caller = data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val person = Person.Builder().setName(caller).setImportant(
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_IMPORTANT, true)
                ).setBot(data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_BOT, false)).build()
                notificationBuilder?.setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        person,
                        getDeclinePendingIntent(notificationId, data),
                        getAcceptPendingIntent(notificationId, data),
                    ).setIsVideo(typeCall > 0)
                )
            } else {
                notificationBuilder?.setContentTitle(caller)
                val textDecline = data.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_DECLINE, "")
                val declineAction: NotificationCompat.Action = NotificationCompat.Action.Builder(
                    R.drawable.ic_decline,
                    if (TextUtils.isEmpty(textDecline)) context.getString(R.string.text_decline) else textDecline,
                    getDeclinePendingIntent(notificationId, data)
                ).build()
                notificationBuilder?.addAction(declineAction)
                val textAccept = data.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_ACCEPT, "")
                val acceptAction: NotificationCompat.Action = NotificationCompat.Action.Builder(
                    R.drawable.ic_accept,
                    if (TextUtils.isEmpty(textAccept)) context.getString(R.string.text_accept) else textAccept,
                    getAcceptPendingIntent(notificationId, data)
                ).build()
                notificationBuilder?.addAction(acceptAction)
            }
        }
        notificationBuilder?.setOngoing(true)
        val notification = notificationBuilder?.build()

        return notification?.let { CallkitNotification(notificationId, it) }
    }

    private fun initInComingNotificationViews(
        notificationId: Int, remoteViews: RemoteViews, data: Bundle
    ) {
        remoteViews.setTextViewText(
            R.id.tvNameCaller, data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
        )
        val isShowCallID = data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
        if (isShowCallID) {
            remoteViews.setTextViewText(
                R.id.tvNumber, data.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
            )
        }
        remoteViews.setOnClickPendingIntent(
            R.id.llDecline, getDeclinePendingIntent(notificationId, data)
        )
        val textDecline = data.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_DECLINE, "")
        remoteViews.setTextViewText(
            R.id.tvDecline,
            if (TextUtils.isEmpty(textDecline)) context.getString(R.string.text_decline) else textDecline
        )
        remoteViews.setOnClickPendingIntent(
            R.id.llAccept, getAcceptPendingIntent(notificationId, data)
        )
        val textAccept = data.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_ACCEPT, "")
        remoteViews.setTextViewText(
            R.id.tvAccept,
            if (TextUtils.isEmpty(textAccept)) context.getString(R.string.text_accept) else textAccept
        )
        var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
        if (!avatarUrl.isNullOrEmpty()) {
            if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith("https://", true)) {
                avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
            }
            val headers =
                data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>

            if (targetInComingAvatarCustom == null) targetInComingAvatarCustom =
                createInComingAvatarTargetCustom(notificationId, false)
            ImageLoaderProvider.loadImage(context, avatarUrl, headers, targetInComingAvatarCustom)
        }
    }

    private fun getSystemFormattedTime(context: Context): String {
        val currentTimeMillis = System.currentTimeMillis()
        val date = Date(currentTimeMillis)

        val timeFormatter = DateFormat.getTimeFormat(context)
        return timeFormatter.format(date)
    }

    @SuppressLint("MissingPermission")
    fun showMissCallNotification(data: Bundle) {

        val isMissedCallShow =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SHOW, true)
        if (!isMissedCallShow) return


        val missingId = data.getString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_ID,
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming")
        )
        val missedNotificationId = ("missing_$missingId").hashCode()

        createNotificationChanel(data);
        val missedCallSound: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val typeCall = data.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, -1)
        // A missed call always uses a missed-call glyph; the old `smallIcon >= 0`
        // guard was dead (resource ids are never negative) and only obscured that.
        val smallIcon =
            if (typeCall > 0) R.drawable.ic_video_missed else R.drawable.ic_call_missed
        notificationMissingBuilder =
            NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID_MISSED)
        notificationMissingBuilder?.setChannelId(NOTIFICATION_CHANNEL_ID_MISSED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                notificationMissingBuilder?.setCategory(Notification.CATEGORY_MISSED_CALL)
            }
        }
        notificationMissingBuilder?.setWhen(System.currentTimeMillis())
        val textMissedCall = data.getString(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_SUBTITLE, "")
        notificationMissingBuilder?.setSubText(
            if (TextUtils.isEmpty(textMissedCall)) context.getString(
                R.string.text_missed_call
            ) else textMissedCall
        )
        notificationMissingBuilder?.setSmallIcon(smallIcon)
        notificationMissingBuilder?.setOnlyAlertOnce(true)

        val isCustomNotification =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_NOTIFICATION, false)
        val count = data.getInt(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_COUNT, 1)
        if (count > 1) {
            notificationMissingBuilder?.setNumber(count)
        }
        if (isCustomNotification) {
            notificationMissingViews =
                RemoteViews(context.packageName, R.layout.layout_custom_miss_notification)
            notificationMissingSmallViews =
                RemoteViews(context.packageName, R.layout.layout_custom_miss_small_notification)
            notificationMissingViews?.setTextViewText(
                R.id.tvNameCaller, data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
            )
            notificationMissingSmallViews?.setTextViewText(
                R.id.tvNameCaller, data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
            )
            notificationMissingSmallViews?.setTextViewText(
                R.id.tvTime, getSystemFormattedTime(context)
            )
            val isShowCallID =
                data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
            if (isShowCallID) {
                notificationMissingViews?.setTextViewText(
                    R.id.tvNumber, data.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
                )
                notificationMissingSmallViews?.setTextViewText(
                    R.id.tvNumber, data.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
                )
            }
            notificationMissingViews?.setOnClickPendingIntent(
                R.id.llCallback, getCallbackPendingIntent(missedNotificationId, data)
            )
            val isShowCallback = data.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_SHOW, true
            )
            notificationMissingViews?.setViewVisibility(
                R.id.llCallback, if (isShowCallback) View.VISIBLE else View.GONE
            )
            val textCallback =
                data.getString(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_TEXT, "")
            notificationMissingViews?.setTextViewText(
                R.id.tvCallback,
                if (TextUtils.isEmpty(textCallback)) context.getString(R.string.text_call_back) else textCallback
            )

            var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
            if (!avatarUrl.isNullOrEmpty()) {
                if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                        "https://",
                        true
                    )
                ) {
                    avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                }
                val headers =
                    data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>

                if (targetMissingAvatarCustom == null) targetMissingAvatarCustom =
                    createMissingAvatarTargetCustom(missedNotificationId)
                ImageLoaderProvider.loadImage(
                    context,
                    avatarUrl,
                    headers,
                    targetMissingAvatarCustom
                )
            }
            notificationMissingBuilder?.setStyle(NotificationCompat.DecoratedCustomViewStyle())
            notificationMissingBuilder?.setCustomContentView(notificationMissingSmallViews)
            notificationMissingBuilder?.setCustomBigContentView(notificationMissingViews)
        } else {
            notificationMissingBuilder?.setContentTitle(
                data.getString(
                    CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, ""
                )
            )
            notificationMissingBuilder?.setContentText(
                data.getString(
                    CallkitConstants.EXTRA_CALLKIT_HANDLE, ""
                )
            )
            var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
            if (!avatarUrl.isNullOrEmpty()) {
                if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                        "https://",
                        true
                    )
                ) {
                    avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                }
                val headers =
                    data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>

                if (targetMissingAvatarDefault == null) targetMissingAvatarDefault =
                    createMissingAvatarTargetDefault(missedNotificationId)
                ImageLoaderProvider.loadImage(
                    context,
                    avatarUrl,
                    headers,
                    targetMissingAvatarDefault
                )
            }
            val isShowCallback = data.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_SHOW, true
            )
            if (isShowCallback) {
                val textCallback =
                    data.getString(CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_CALLBACK_TEXT, "")
                val callbackAction: NotificationCompat.Action = NotificationCompat.Action.Builder(
                    R.drawable.ic_accept,
                    if (TextUtils.isEmpty(textCallback)) context.getString(R.string.text_call_back) else textCallback,
                    getCallbackPendingIntent(missedNotificationId, data)
                ).build()
                notificationMissingBuilder?.addAction(callbackAction)
            }
        }
        notificationMissingBuilder?.priority = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            NotificationManager.IMPORTANCE_HIGH
        } else {
            Notification.PRIORITY_HIGH
        }
        notificationMissingBuilder?.setSound(missedCallSound)
        notificationMissingBuilder?.setContentIntent(
            getAppPendingIntent(
                missedNotificationId, data
            )
        )
        val actionColor = data.getString(CallkitConstants.EXTRA_CALLKIT_ACTION_COLOR, "#4CAF50")
        try {
            notificationMissingBuilder?.color = Color.parseColor(actionColor)
        } catch (_: Exception) {
        }
        val notification = notificationMissingBuilder?.build()
        if (notification != null) {
            getNotificationManager().notify(missedNotificationId, notification)
        }
    }


    @SuppressLint("MissingPermission")
    fun getOnGoingCallNotification(
        data: Bundle, isConnected: Boolean? = false
    ): CallkitNotification? {

        val isCallingNotificationShow =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_CALLING_SHOW, true)
        if (!isCallingNotificationShow) return null

        val onGoingNotificationId = data.getString(
            CallkitConstants.EXTRA_CALLKIT_CALLING_ID,
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming")
        ).hashCode()

        notificationOngoingBuilder = NotificationCompat.Builder(
            context, NOTIFICATION_CHANNEL_ID_ONGOING
        )
        notificationOngoingBuilder?.setChannelId(NOTIFICATION_CHANNEL_ID_ONGOING)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                notificationOngoingBuilder?.setCategory(Notification.CATEGORY_CALL)
            }
        }
        val textCalling = data.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_SUBTITLE, "")
        notificationOngoingBuilder?.setSubText(
            if (TextUtils.isEmpty(textCalling)) context.getString(
                R.string.text_calling
            ) else textCalling
        )
        notificationOngoingBuilder?.setOngoing(true)
        notificationOngoingBuilder?.setAutoCancel(false)
        notificationOngoingBuilder?.setSound(null)

        val typeCall = data.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, -1)
        var smallIcon = context.applicationInfo.icon
        if (typeCall > 0) {
            smallIcon = R.drawable.ic_video
        }
        notificationOngoingBuilder?.setSmallIcon(smallIcon)

        val isCustomNotification =
            data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_CUSTOM_NOTIFICATION, false)
        if (isCustomNotification) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {

                val caller = data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
                val person = Person.Builder().setName(caller).setImportant(
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_IMPORTANT, true)
                ).setBot(data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_BOT, false)).build()
                val callStyle = NotificationCompat.CallStyle.forOngoingCall(
                    person, getHangupPendingIntent(onGoingNotificationId, data)
                )
                callStyle.setVerificationText(
                    if (TextUtils.isEmpty(textCalling)) context.getString(
                        R.string.text_calling
                    ) else textCalling
                )
                notificationOngoingBuilder?.setStyle(callStyle)


                val isShowCallID =
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
                if (isShowCallID) {
                    notificationOngoingBuilder?.setContentText(
                        data.getString(
                            CallkitConstants.EXTRA_CALLKIT_HANDLE, ""
                        )
                    )
                }
                var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
                if (!avatarUrl.isNullOrEmpty()) {
                    if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                            "https://",
                            true
                        )
                    ) {
                        avatarUrl =
                            String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                    }
                    val headers =
                        data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
                    if (targetOnGoingAvatarCustom == null) targetOnGoingAvatarCustom =
                        createOnGoingAvatarTargetCustom(onGoingNotificationId, true)

                    ImageLoaderProvider.loadImage(
                        context,
                        avatarUrl,
                        headers,
                        targetOnGoingAvatarCustom
                    )
                }
            } else {
                notificationOngoingViews =
                    RemoteViews(context.packageName, R.layout.layout_custom_ongoing_notification)
                notificationOngoingSmallViews = RemoteViews(
                    context.packageName, R.layout.layout_custom_small_ongoing_notification
                )

                notificationOngoingViews?.setTextViewText(
                    R.id.tvNameCaller,
                    data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
                )
                notificationOngoingSmallViews?.setTextViewText(
                    R.id.tvNameCaller,
                    data.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
                )
                val isShowCallID =
                    data.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
                if (isShowCallID) {
                    notificationOngoingViews?.setTextViewText(
                        R.id.tvNumber, data.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
                    )
                    notificationOngoingSmallViews?.setTextViewText(
                        R.id.tvNumber, data.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
                    )
                }
                notificationOngoingViews?.setOnClickPendingIntent(
                    R.id.llHangup, getHangupPendingIntent(onGoingNotificationId, data)
                )
                val isShowHangup = data.getBoolean(
                    CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_SHOW, true
                )
                notificationOngoingViews?.setViewVisibility(
                    R.id.llHangup, if (isShowHangup) View.VISIBLE else View.GONE
                )


                val textHangup =
                    data.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_TEXT, "")
                notificationOngoingViews?.setTextViewText(
                    R.id.tvHangUp,
                    if (TextUtils.isEmpty(textHangup)) context.getString(R.string.text_hang_up) else textHangup
                )

                var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
                if (!avatarUrl.isNullOrEmpty()) {
                    if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                            "https://",
                            true
                        )
                    ) {
                        avatarUrl =
                            String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                    }
                    val headers =
                        data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>

                    if (targetOnGoingAvatarCustom == null) targetOnGoingAvatarCustom =
                        createOnGoingAvatarTargetCustom(onGoingNotificationId, false)

                    ImageLoaderProvider.loadImage(
                        context,
                        avatarUrl,
                        headers,
                        targetOnGoingAvatarCustom
                    )

                }
                notificationOngoingBuilder?.setStyle(NotificationCompat.DecoratedCustomViewStyle())
                notificationOngoingBuilder?.setCustomContentView(notificationOngoingSmallViews)
                notificationOngoingBuilder?.setCustomBigContentView(notificationOngoingViews)
            }
        } else {
            notificationOngoingBuilder?.setContentTitle(
                data.getString(
                    CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, ""
                )
            )
            notificationOngoingBuilder?.setContentText(
                data.getString(
                    CallkitConstants.EXTRA_CALLKIT_HANDLE, ""
                )
            )
            var avatarUrl = data.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
            if (!avatarUrl.isNullOrEmpty()) {
                if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith(
                        "https://",
                        true
                    )
                ) {
                    avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
                }
                val headers =
                    data.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>


                if (targetOnGoingAvatarDefault == null) targetOnGoingAvatarDefault =
                    createOnGoingAvatarTargetDefault(onGoingNotificationId)

                ImageLoaderProvider.loadImage(
                    context,
                    avatarUrl,
                    headers,
                    targetOnGoingAvatarDefault
                )
            }
            val isShowHangup = data.getBoolean(
                CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_SHOW, true
            )
            if (isShowHangup) {
                val textHangup =
                    data.getString(CallkitConstants.EXTRA_CALLKIT_CALLING_HANG_UP_TEXT, "")
                val hangUpAction: NotificationCompat.Action = NotificationCompat.Action.Builder(
                    R.drawable.transparent,
                    if (TextUtils.isEmpty(textHangup)) context.getString(R.string.text_hang_up) else textHangup,
                    getHangupPendingIntent(onGoingNotificationId, data)
                ).build()
                notificationOngoingBuilder?.addAction(hangUpAction)
            }
        }
        notificationOngoingBuilder?.priority = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            NotificationManager.IMPORTANCE_HIGH
        } else {
            Notification.PRIORITY_HIGH
        }
        if (isConnected == true) {
            notificationOngoingBuilder?.setWhen(System.currentTimeMillis())
            notificationOngoingBuilder?.setUsesChronometer(true)
        } else {
            notificationOngoingBuilder?.setUsesChronometer(false)
        }
        notificationOngoingBuilder?.setSound(null)
        notificationOngoingBuilder?.setContentIntent(
            getAppPendingIntent(
                onGoingNotificationId, data
            )
        )
        val actionColor = data.getString(CallkitConstants.EXTRA_CALLKIT_ACTION_COLOR, "#4CAF50")
        try {
            notificationOngoingBuilder?.color = Color.parseColor(actionColor)
        } catch (_: Exception) {
        }
        notificationOngoingBuilder?.setOngoing(true)
        val notification = notificationOngoingBuilder?.build()

        return notification?.let { CallkitNotification(onGoingNotificationId, it) }
    }

    fun clearIncomingNotification(data: Bundle, isAccepted: Boolean) {
        // Start Signify modification
        // Unregister volume key receiver
        volumeKeyReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: Exception) {
                // Ignore Receiver may not be registered
            }
            volumeKeyReceiver = null
        }
        // End Signify modification

        callkitSoundPlayerManager?.stop()

        context.sendBroadcast(CallkitIncomingActivity.getIntentEnded(context, isAccepted))
        val notificationId =
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming").hashCode()
        getNotificationManager().cancel(notificationId)
        targetInComingAvatarDefault?.let {
            targetInComingAvatarDefault?.isCancelled = true
            targetInComingAvatarDefault = null
        }
        targetInComingAvatarCustom?.let {
            targetInComingAvatarCustom?.isCancelled = true
            targetInComingAvatarCustom = null
        }

        targetOnGoingAvatarDefault?.let {
            targetOnGoingAvatarDefault?.isCancelled = true
            targetOnGoingAvatarDefault = null
        }
        targetOnGoingAvatarCustom?.let {
            targetOnGoingAvatarCustom?.isCancelled = true
            targetOnGoingAvatarCustom = null
        }
    }

    fun clearMissCallNotification(data: Bundle) {
        val missingId = data.getString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_ID,
            data.getString(CallkitConstants.EXTRA_CALLKIT_ID, "callkit_incoming")
        )
        val missedNotificationId = ("missing_$missingId").hashCode()

        getNotificationManager().cancel(missedNotificationId)
        targetMissingAvatarDefault?.let {
            targetMissingAvatarDefault?.isCancelled = true
            targetMissingAvatarDefault = null
        }
        targetMissingAvatarCustom?.let {
            targetMissingAvatarCustom?.isCancelled = true
            targetMissingAvatarCustom = null
        }
    }

    private fun incomingChannelEnabled(): Boolean = getNotificationManager().run {
        val channel = getNotificationChannel(NOTIFICATION_CHANNEL_ID_INCOMING)

        return areNotificationsEnabled() &&
            ((Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                channel != null &&
                channel.importance > NotificationManagerCompat.IMPORTANCE_NONE) ||
                Build.VERSION.SDK_INT < Build.VERSION_CODES.O)
    }

    fun createNotificationChanel(data: Bundle) {
        val incomingCallChannelName = data.getString(
            CallkitConstants.EXTRA_CALLKIT_INCOMING_CALL_NOTIFICATION_CHANNEL_NAME, "Incoming Call"
        )
        val missedCallChannelName = data.getString(
            CallkitConstants.EXTRA_CALLKIT_MISSED_CALL_NOTIFICATION_CHANNEL_NAME, "Missed Call"
        )
        val ongoingCallChannelName = data.getString(
            CallkitConstants.EXTRA_CALLKIT_ONGOING_CALL_NOTIFICATION_CHANNEL_NAME, "Ongoing Call"
        );

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getNotificationManager().apply {
                var channelCall = getNotificationChannel(NOTIFICATION_CHANNEL_ID_INCOMING)
                if (channelCall != null) {
                    channelCall.setSound(null, null)
                } else {
                    channelCall = NotificationChannel(
                        NOTIFICATION_CHANNEL_ID_INCOMING,
                        incomingCallChannelName,
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = ""
                        vibrationPattern = longArrayOf(0, 1000, 500, 1000, 500)
                        lightColor = Color.RED
                        enableLights(true)
                        enableVibration(true)
                        setSound(null, null)
                    }
                }
                channelCall.lockscreenVisibility = Notification.VISIBILITY_PUBLIC

                channelCall.importance = NotificationManager.IMPORTANCE_HIGH

                createNotificationChannel(channelCall)

                val channelMissedCall = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID_MISSED,
                    missedCallChannelName,
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = ""
                    vibrationPattern = longArrayOf(0, 1000)
                    lightColor = Color.RED
                    enableLights(true)
                    enableVibration(true)
                }
                channelMissedCall.importance = NotificationManager.IMPORTANCE_HIGH
                createNotificationChannel(channelMissedCall)

                val channelOngoingCall = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID_ONGOING,
                    ongoingCallChannelName,
                    NotificationManager.IMPORTANCE_LOW // disables notification popup for ongoing call
                )
                createNotificationChannel(channelOngoingCall)
            }
        }
    }

    private fun getAcceptPendingIntent(id: Int, data: Bundle): PendingIntent {
        val intentTransparent = TransparentActivity.getIntent(
            context, CallkitConstants.ACTION_CALL_ACCEPT, data
        )
        return PendingIntent.getActivity(context, id, intentTransparent, getFlagPendingIntent())
    }

    private fun getDeclinePendingIntent(id: Int, data: Bundle): PendingIntent {
        val declineIntent = CallkitIncomingBroadcastReceiver.getIntentDecline(context, data)
        return PendingIntent.getBroadcast(context, id, declineIntent, getFlagPendingIntent())
    }

    private fun getTimeOutPendingIntent(id: Int, data: Bundle): PendingIntent {
        val timeOutIntent = CallkitIncomingBroadcastReceiver.getIntentTimeout(context, data)
        return PendingIntent.getBroadcast(context, id, timeOutIntent, getFlagPendingIntent())
    }

    private fun getCallbackPendingIntent(id: Int, data: Bundle): PendingIntent {
        val intentTransparent = TransparentActivity.getIntent(
            context, CallkitConstants.ACTION_CALL_CALLBACK, data
        )
        return PendingIntent.getActivity(context, id, intentTransparent, getFlagPendingIntent())
    }

    private fun getActivityPendingIntent(id: Int, data: Bundle): PendingIntent {
        val intent = CallkitIncomingActivity.getIntent(context, data)
        return PendingIntent.getActivity(context, id, intent, getFlagPendingIntent())
    }

    private fun getAppPendingIntent(id: Int, data: Bundle): PendingIntent {
        val intent: Intent? = AppUtils.getAppIntent(context, data = data)
        return PendingIntent.getActivity(context, id, intent, getFlagPendingIntent())
    }


    private fun getHangupPendingIntent(notificationId: Int, data: Bundle): PendingIntent {
        val endedIntent = CallkitIncomingBroadcastReceiver.getIntentEnded(context, data)
        return PendingIntent.getBroadcast(
            context, notificationId, endedIntent, getFlagPendingIntent()
        )
    }


    private fun getFlagPendingIntent(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
    }


    private fun getNotificationManager(): NotificationManagerCompat {
        return NotificationManagerCompat.from(context)
    }

    // Start Signify modification
    inner class VolumeKeyBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VOLUME_CHANGED) {
                val streamType =
                    intent.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1)
                if (streamType != AudioManager.STREAM_RING) {
                    return
                }
                if (callkitSoundPlayerManager?.isPlaying == true) {
                    callkitSoundPlayerManager.stop()
                }
            }
        }
    }
    // End Signify modification

    @SuppressLint("MissingPermission")
    fun showIncomingNotification(data: Bundle) {
        val callkitNotification = getIncomingNotification(data)
        if (incomingChannelEnabled()) {
            callkitSoundPlayerManager?.play(data)
            // Start Signify modification
            volumeKeyReceiver = VolumeKeyBroadcastReceiver()
            context.registerReceiver(
                volumeKeyReceiver,
                IntentFilter(ACTION_VOLUME_CHANGED)
            )
            // End Signify modification
        }
        callkitNotification?.let {
            getNotificationManager().notify(
                it.id, callkitNotification.notification
            )
        }
    }

    @SuppressLint("MissingPermission")
    fun showOngoingCallNotification(data: Bundle, isConnected: Boolean?) {
        val callkitNotification = getOnGoingCallNotification(data, isConnected)
        callkitNotification?.let {
            getNotificationManager().notify(
                callkitNotification.id, it.notification
            )
        }
        callkitSoundPlayerManager?.stop()
    }


    fun requestNotificationPermission(activity: Activity?, map: Map<String, Any>) {
        this.dataNotificationPermission = map
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity?.let {
                if (ActivityCompat.checkSelfPermission(
                        it, Manifest.permission.POST_NOTIFICATIONS
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    ActivityCompat.requestPermissions(
                        it,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        PERMISSION_NOTIFICATION_REQUEST_CODE
                    )
                }
            }
        }
    }

    fun requestFullIntentPermission(activity: Activity?) {
        val canUseFullScreenIntent = getNotificationManager().canUseFullScreenIntent()
        if (!canUseFullScreenIntent && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.fromParts("package", activity?.packageName, null)
            }
            activity?.startActivity(intent)
        }
    }

    fun canUseFullScreenIntent(): Boolean {
        val canUseFullScreenIntent = getNotificationManager().canUseFullScreenIntent()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return canUseFullScreenIntent
        }
        return true
    }


    fun onRequestPermissionsResult(activity: Activity?, requestCode: Int, grantResults: IntArray) {
        when (requestCode) {
            PERMISSION_NOTIFICATION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] === PackageManager.PERMISSION_GRANTED) {
                    // allow
                } else {
                    //deny
                    activity?.let {
                        if (ActivityCompat.shouldShowRequestPermissionRationale(
                                it, Manifest.permission.POST_NOTIFICATIONS
                            )
                        ) {
                            //showDialogPermissionRationale()
                            if (this.dataNotificationPermission["title"] != null && this.dataNotificationPermission["rationaleMessagePermission"] != null) {
                                showDialogMessage(
                                    it,
                                    this.dataNotificationPermission["title"] as String,
                                    this.dataNotificationPermission["rationaleMessagePermission"] as String
                                ) { dialog, _ ->
                                    dialog?.dismiss()
                                    requestNotificationPermission(
                                        activity, this.dataNotificationPermission
                                    )
                                }
                            } else {
                                requestNotificationPermission(
                                    activity, this.dataNotificationPermission
                                )
                            }
                        } else {
                            //Open Setting
                            if (this.dataNotificationPermission["title"] != null && this.dataNotificationPermission["postNotificationMessageRequired"] != null) {
                                showDialogMessage(
                                    it,
                                    this.dataNotificationPermission["title"] as String,
                                    this.dataNotificationPermission["postNotificationMessageRequired"] as String
                                ) { dialog, _ ->
                                    dialog?.dismiss()
                                    val intent = Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.fromParts("package", it.packageName, null)
                                    )
                                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
                                    it.startActivity(intent)
                                }
                            } else {
                                showDialogMessage(
                                    it,
                                    it.resources.getString(R.string.text_title_post_notification),
                                    it.resources.getString(R.string.text_post_notification_message_required)
                                ) { dialog, _ ->
                                    dialog?.dismiss()
                                    val intent = Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.fromParts("package", it.packageName, null)
                                    )
                                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
                                    it.startActivity(intent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun showDialogMessage(
        activity: Activity?,
        title: String,
        message: String,
        okListener: DialogInterface.OnClickListener
    ) {
        activity?.let {
            AlertDialog.Builder(it, R.style.DialogTheme).setTitle(title).setMessage(message)
                .setPositiveButton(android.R.string.ok, okListener)
                .setNegativeButton(android.R.string.cancel, null).create().show()
        }
    }

    fun destroy() {

        callkitSoundPlayerManager?.destroy()
    }

}

data class CallkitNotification(val id: Int, val notification: Notification)


