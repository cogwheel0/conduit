//  Modification by Signify in this file are under the following license:
//
//  Copyright 2024, Signify Holding
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

package com.hiennv.flutter_callkit_incoming

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.text.TextUtils
import java.util.Timer
import java.util.TimerTask

class CallkitSoundPlayerManager(private val context: Context) {

    private var vibrator: Vibrator? = null
    private var audioManager: AudioManager? = null

    private var ringtone: Ringtone? = null

    // Start Signify modification
    var isPlaying: Boolean = false
        private set
    // End Signify modification

    private var keepRingingForFullScreenIntent: Boolean = false

    inner class ScreenOffCallkitIncomingBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (isPlaying && !keepRingingForFullScreenIntent) {
                stop()
            }
        }
    }

    private var screenOffCallkitIncomingBroadcastReceiver =
        ScreenOffCallkitIncomingBroadcastReceiver()


    fun play(data: Bundle) {
        this.isPlaying = true
        this.prepare()

        // Honour the ringer mode before making any sound: SILENT is fully quiet and
        // VIBRATE vibrates without a ringtone. The check used to live inside
        // playVibrator(), which left the ringtone audible in silent mode.
        val ringerMode = (context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.ringerMode
        if (ringerMode != AudioManager.RINGER_MODE_SILENT) {
            if (ringerMode != AudioManager.RINGER_MODE_VIBRATE) {
                this.playSound(data)
            }
            this.playVibrator()
        }

        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        context.registerReceiver(screenOffCallkitIncomingBroadcastReceiver, filter)
    }

    fun stop() {
        this.isPlaying = false

        ringtone?.stop()
        vibrator?.cancel()
        ringtone = null
        vibrator = null
        try {
            context.unregisterReceiver(screenOffCallkitIncomingBroadcastReceiver)
        } catch (_: Exception) {
        }
    }

    fun destroy() {
        this.isPlaying = false

        ringtone?.stop()
        vibrator?.cancel()
        ringtone = null
        vibrator = null
        try {
            context.unregisterReceiver(screenOffCallkitIncomingBroadcastReceiver)
        } catch (_: Exception) {
        }
    }

    private fun prepare() {
        ringtone?.stop()
        vibrator?.cancel()
    }

    private fun playVibrator() {
        vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager =
                context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vibratorManager.defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audioManager?.ringerMode == AudioManager.RINGER_MODE_SILENT) return

        val pattern = longArrayOf(0L, 1000L, 1000L)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val audioAttrs = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setLegacyStreamType(AudioManager.STREAM_RING)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(
                    VibrationEffect.createWaveform(pattern, 0),
                    audioAttrs
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0, audioAttrs)
            }
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    private fun playSound(data: Bundle?) {
        val sound = data?.getString(
            CallkitConstants.EXTRA_CALLKIT_RINGTONE_PATH,
            ""
        )
        val uri = sound?.let { getRingtoneUri(it) }
        if (uri == null) {
            // Failed to get ringtone url, can't play sound
            return
        }
        try {
            ringtone = RingtoneManager.getRingtone(context, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val attribution = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setLegacyStreamType(AudioManager.STREAM_RING)
                    .build()
                ringtone?.setAudioAttributes(attribution)
            } else {
                ringtone?.streamType = AudioManager.STREAM_RING
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ringtone?.isLooping = true
            }
            ringtone?.play()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun getRingtoneUri(fileName: String): Uri? {
        if (TextUtils.isEmpty(fileName)) {
            return getDefaultRingtoneUri()
        }

        // If system_ringtone_default is explicitly requested, bypass resource check
        if (fileName.equals("system_ringtone_default", true)) {
            return getDefaultRingtoneUri(useSystemDefault = true)
        }

        try {
            val resId = context.resources.getIdentifier(fileName, "raw", context.packageName)
            if (resId != 0) {
                return Uri.parse("android.resource://${context.packageName}/$resId")
            }

            // For any other unresolved filename, return the default ringtone
            return getDefaultRingtoneUri()
        } catch (e: Exception) {
            // If anything fails, try to return the system default ringtone
            return getDefaultRingtoneUri()
        }
    }

    private fun getDefaultRingtoneUri(useSystemDefault: Boolean = false): Uri? {
        try {
            if (!useSystemDefault) {
                // First try to use ringtone_default resource if it exists
                val resId =
                    context.resources.getIdentifier("ringtone_default", "raw", context.packageName)
                if (resId != 0) {
                    return Uri.parse("android.resource://${context.packageName}/$resId")
                }
            }

            // Fall back to system default ringtone
            return RingtoneManager.getActualDefaultRingtoneUri(
                context,
                RingtoneManager.TYPE_RINGTONE
            )
        } catch (e: Exception) {
            // getActualDefaultRingtoneUri can throw an exception on some devices
            // for custom ringtones
            return getSafeSystemRingtoneUri()
        }
    }

    private fun getSafeSystemRingtoneUri(): Uri? {
        try {
            val defaultUri = RingtoneManager.getActualDefaultRingtoneUri(
                context,
                RingtoneManager.TYPE_RINGTONE
            )

            val rm = RingtoneManager(context)
            rm.setType(RingtoneManager.TYPE_RINGTONE)
            val cursor = rm.cursor
            if (defaultUri != null && cursor != null) {
                while (cursor.moveToNext()) {
                    val uri = rm.getRingtoneUri(cursor.position)
                    if (uri == defaultUri) {
                        cursor.close()
                        return defaultUri
                    }
                }
            }

            // Default isn't system-provided → fallback to first available
            if (cursor != null && cursor.moveToFirst()) {
                val fallback = rm.getRingtoneUri(cursor.position)
                cursor.close()
                return fallback
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    private var ringingTimer: Timer? = null

    // This function is called when the incoming call full intent (CallkitIncomingActivity) is shown
    // It prevents the sound from stopping when the screen is turned off because of an auto lock
    fun keepRingingOnFullScreen() {
        keepRingingForFullScreenIntent = true
        ringingTimer?.cancel()
        ringingTimer = Timer().apply {
            schedule(object : TimerTask() {
                override fun run() {
                    keepRingingForFullScreenIntent = false
                }
            }, 500)
        }
    }
}