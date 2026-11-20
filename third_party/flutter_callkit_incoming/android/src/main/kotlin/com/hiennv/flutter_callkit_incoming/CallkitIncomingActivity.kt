//  Modification by Signify in this file are under the following license:
//
//  Copyright 2024, Signify Holding
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

package com.hiennv.flutter_callkit_incoming

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.Intent.FLAG_ACTIVITY_NEW_TASK
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.drawable.Drawable
import androidx.core.graphics.drawable.DrawableCompat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.view.animation.AnimationUtils
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.hiennv.flutter_callkit_incoming.widgets.RippleRelativeLayout
import de.hdodenhof.circleimageview.CircleImageView
import kotlin.math.abs
import android.view.ViewGroup.MarginLayoutParams
import android.os.PowerManager
import android.text.TextUtils
import android.util.Log

class CallkitIncomingActivity : Activity() {

    companion object {

        private const val TAG = "CallkitIncomingActivity"

        private const val ACTION_ENDED_CALL_INCOMING =
            "com.hiennv.flutter_callkit_incoming.ACTION_ENDED_CALL_INCOMING"

        fun getIntent(context: Context, data: Bundle) =
            Intent(CallkitConstants.ACTION_CALL_INCOMING).apply {
                setClassName(context.packageName, "com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity")
                action = "${context.packageName}.${CallkitConstants.ACTION_CALL_INCOMING}"
                putExtra(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA, data)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                `package` = context.packageName
            }

        fun getIntentEnded(context: Context, isAccepted: Boolean): Intent {
            val intent = Intent("${context.packageName}.${ACTION_ENDED_CALL_INCOMING}")
            intent.putExtra("ACCEPTED", isAccepted)
            intent.setPackage(context.packageName)
            intent.setClassName(
                context.packageName,
                "com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity"
            )
            return intent
        }
    }

    inner class EndedCallkitIncomingBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!isFinishing) {
                val isAccepted = intent.getBooleanExtra("ACCEPTED", false)
                if (isAccepted) {
                    finishDelayed()
                } else {
                    finishTask()
                }
            }
        }
    }

    private var endedCallkitIncomingBroadcastReceiver = EndedCallkitIncomingBroadcastReceiver()

    private var wakeLock: PowerManager.WakeLock? = null

    private lateinit var ivBackground: ImageView
    private lateinit var llBackgroundAnimation: RippleRelativeLayout

    private lateinit var tvNameCaller: TextView
    private lateinit var tvNumber: TextView
    private lateinit var ivLogo: ImageView
    private lateinit var ivAvatar: CircleImageView

    private lateinit var llAction: LinearLayout
    private lateinit var ivAcceptCall: ImageView
    private lateinit var tvAccept: TextView

    private lateinit var ivDeclineCall: ImageView
    private lateinit var tvDecline: TextView

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = if (!Utils.isTablet(this@CallkitIncomingActivity)) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            setTurnScreenOn(true)
            setShowWhenLocked(true)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        transparentStatusAndNavigation()
        setContentView(R.layout.activity_callkit_incoming)
        initView()
        incomingData(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(
                endedCallkitIncomingBroadcastReceiver,
                IntentFilter("${packageName}.${ACTION_ENDED_CALL_INCOMING}"),
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            registerReceiver(
                endedCallkitIncomingBroadcastReceiver,
                IntentFilter("${packageName}.${ACTION_ENDED_CALL_INCOMING}")
            )
        }
        FlutterCallkitIncomingPlugin.getInstance()?.getCallkitSoundPlayerManager()?.keepRingingOnFullScreen();
    }

    private fun wakeLockRequest(duration: Long) {
        releaseWakeLock()
        val pm = applicationContext.getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.FULL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "Callkit:PowerManager"
        ).also { it.acquire(duration) }
    }

    /**
     * Without this the screen stays forced on for the whole ring duration even after
     * the call has been answered or declined.
     */
    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            Log.e(TAG, "releaseWakeLock failed", e)
        }
        wakeLock = null
    }

    private fun transparentStatusAndNavigation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT && Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            setWindowFlag(
                WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS
                        or WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION, true
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            setWindowFlag(
                (WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS
                        or WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION), false
            )
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }
    }

    private fun setWindowFlag(bits: Int, on: Boolean) {
        val win: Window = window
        val winParams: WindowManager.LayoutParams = win.attributes
        if (on) {
            winParams.flags = winParams.flags or bits
        } else {
            winParams.flags = winParams.flags and bits.inv()
        }
        win.attributes = winParams
    }


    private fun incomingData(intent: Intent) {
        val data = intent.extras?.getBundle(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA)
        if (data == null) finish()

        val isShowFullLockedScreen =
            data?.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_FULL_LOCKED_SCREEN, true)
        if (isShowFullLockedScreen == true) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
            } else {
                window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
            }
        }

        val textColor = data?.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_COLOR, "#ffffff")
        val isShowCallID = data?.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_CALL_ID, false)
        tvNameCaller.text = data?.getString(CallkitConstants.EXTRA_CALLKIT_NAME_CALLER, "")
        tvNumber.text = data?.getString(CallkitConstants.EXTRA_CALLKIT_HANDLE, "")
        tvNumber.visibility = if (isShowCallID == true) View.VISIBLE else View.INVISIBLE

        try {
            tvNameCaller.setTextColor(Color.parseColor(textColor))
            tvNumber.setTextColor(Color.parseColor(textColor))
        } catch (error: Exception) {
        }

        val isShowLogo = data?.getBoolean(CallkitConstants.EXTRA_CALLKIT_IS_SHOW_LOGO, false)
        ivLogo.visibility = if (isShowLogo == true) View.VISIBLE else View.INVISIBLE
        var logoUrl = data?.getString(CallkitConstants.EXTRA_CALLKIT_LOGO_URL, "")
        if (!logoUrl.isNullOrEmpty()) {
            if (!logoUrl.startsWith("http://", true) && !logoUrl.startsWith("https://", true)) {
                logoUrl = String.format("file:///android_asset/flutter_assets/%s", logoUrl)
            }
            val headers =
                data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
            ImageLoaderProvider.loadImage(this@CallkitIncomingActivity, logoUrl, headers, R.drawable.transparent, ivLogo)
        }

        var avatarUrl = data?.getString(CallkitConstants.EXTRA_CALLKIT_AVATAR, "")
        if (!avatarUrl.isNullOrEmpty()) {
            ivAvatar.visibility = View.VISIBLE
            if (!avatarUrl.startsWith("http://", true) && !avatarUrl.startsWith("https://", true)) {
                avatarUrl = String.format("file:///android_asset/flutter_assets/%s", avatarUrl)
            }
            val headers =
                data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
            ImageLoaderProvider.loadImage(this@CallkitIncomingActivity, avatarUrl, headers, R.drawable.ic_default_avatar, ivAvatar)
        }

        val callType = data?.getInt(CallkitConstants.EXTRA_CALLKIT_TYPE, 0) ?: 0
        if (callType > 0) {
            ivAcceptCall.setImageResource(R.drawable.ic_video)
        }
        val duration = data?.getLong(CallkitConstants.EXTRA_CALLKIT_DURATION, 0L) ?: 0L
        wakeLockRequest(duration)

        finishTimeout(data, duration)

        val textAccept = data?.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_ACCEPT, "")
        tvAccept.text =
            if (TextUtils.isEmpty(textAccept)) getString(R.string.text_accept) else textAccept
        val textDecline = data?.getString(CallkitConstants.EXTRA_CALLKIT_TEXT_DECLINE, "")
        tvDecline.text =
            if (TextUtils.isEmpty(textDecline)) getString(R.string.text_decline) else textDecline

        val acceptCallColor =
            data?.getString(CallkitConstants.EXTRA_CALLKIT_ACCEPT_COLOR, "#4CAF50")
        try {
            ivAcceptCall.setBackground(AppUtils.createCircleDrawable(Color.parseColor(acceptCallColor)))
        } catch (error: Exception) {
        }

        val declineCallColor =
            data?.getString(CallkitConstants.EXTRA_CALLKIT_DECLINE_COLOR, "#F44336")
        try {
            ivDeclineCall.setBackground(AppUtils.createCircleDrawable(Color.parseColor(declineCallColor)))
        } catch (error: Exception) {
        }

        try {
            tvAccept.setTextColor(Color.parseColor(textColor))
            tvDecline.setTextColor(Color.parseColor(textColor))
        } catch (error: Exception) {
        }

        val backgroundColor =
            data?.getString(CallkitConstants.EXTRA_CALLKIT_BACKGROUND_COLOR, "#0955fa")
        try {
            ivBackground.setBackgroundColor(Color.parseColor(backgroundColor))
        } catch (error: Exception) {
        }
        var backgroundUrl = data?.getString(CallkitConstants.EXTRA_CALLKIT_BACKGROUND_URL, "")
        if (!backgroundUrl.isNullOrEmpty()) {
            if (!backgroundUrl.startsWith("http://", true) && !backgroundUrl.startsWith(
                    "https://",
                    true
                )
            ) {
                backgroundUrl =
                    String.format("file:///android_asset/flutter_assets/%s", backgroundUrl)
            }
            val headers =
                data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS) as HashMap<String, Any?>
            ImageLoaderProvider.loadImage(this@CallkitIncomingActivity, backgroundUrl, headers, R.drawable.transparent, ivBackground)
        }
    }

    private fun finishTimeout(data: Bundle?, duration: Long) {
        val currentSystemTime = System.currentTimeMillis()
        val timeStartCall =
            data?.getLong(CallkitNotificationManager.EXTRA_TIME_START_CALL, currentSystemTime)
                ?: currentSystemTime

        val timeOut = duration - abs(currentSystemTime - timeStartCall)
        Handler(Looper.getMainLooper()).postDelayed({
            if (!isFinishing) {
                finishTask()
            }
        }, timeOut)
    }

    private fun initView() {
        ivBackground = findViewById(R.id.ivBackground)
        llBackgroundAnimation = findViewById(R.id.llBackgroundAnimation)
        llBackgroundAnimation.layoutParams.height =
            Utils.getScreenWidth() + Utils.getStatusBarHeight(this@CallkitIncomingActivity)
        llBackgroundAnimation.startRippleAnimation()

        tvNameCaller = findViewById(R.id.tvNameCaller)
        tvNumber = findViewById(R.id.tvNumber)
        ivLogo = findViewById(R.id.ivLogo)
        ivAvatar = findViewById(R.id.ivAvatar)

        llAction = findViewById(R.id.llAction)

        val params = llAction.layoutParams as MarginLayoutParams
        params.setMargins(0, 0, 0, Utils.getNavigationBarHeight(this@CallkitIncomingActivity))
        llAction.layoutParams = params

        ivAcceptCall = findViewById(R.id.ivAcceptCall)
        tvAccept = findViewById(R.id.tvAccept)
        ivDeclineCall = findViewById(R.id.ivDeclineCall)
        tvDecline = findViewById(R.id.tvDecline)
        animateAcceptCall()

        ivAcceptCall.setOnClickListener {
            onAcceptClick()
        }
        ivDeclineCall.setOnClickListener {
            onDeclineClick()
        }
    }

    private fun animateAcceptCall() {
        val shakeAnimation =
            AnimationUtils.loadAnimation(this@CallkitIncomingActivity, R.anim.shake_anim)
        ivAcceptCall.animation = shakeAnimation
    }


    private fun onAcceptClick() {
        // Log.d("CallkitIncomingActivity", "[CALLKIT] 📱 onAcceptClick")
        val data = intent.extras?.getBundle(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA)


        CallkitNotificationService.startServiceWithAction(
            this@CallkitIncomingActivity,
            CallkitConstants.ACTION_CALL_ACCEPT,
            data
        )


        val acceptIntent =
            TransparentActivity.getIntent(this, CallkitConstants.ACTION_CALL_ACCEPT, data)
        startActivity(acceptIntent)

        dismissKeyguard()
        finish()
    }

    private fun dismissKeyguard() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
        }
    }

    private fun onDeclineClick() {
        // Log.d("CallkitIncomingActivity", "[CALLKIT] 📱 onDeclineClick")
        val data = intent.extras?.getBundle(CallkitConstants.EXTRA_CALLKIT_INCOMING_DATA)

        val intent =
            CallkitIncomingBroadcastReceiver.getIntentDecline(this@CallkitIncomingActivity, data)
        sendBroadcast(intent)
        finishTask()
    }

    private fun finishDelayed() {
        Handler(Looper.getMainLooper()).postDelayed({
            finishTask()
        }, 1000)
    }

    private fun finishTask() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            finishAndRemoveTask()
        } else {
            finish()
        }
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            unregisterReceiver(endedCallkitIncomingBroadcastReceiver)
        } catch (e: IllegalArgumentException) {
            // Registration failed earlier, or onDestroy ran twice.
            Log.w(TAG, "endedCallkitIncomingBroadcastReceiver was not registered")
        }
        super.onDestroy()
    }

    // Start Signify modification
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            val soundPlayerManager = FlutterCallkitIncomingPlugin.getInstance()?.getCallkitSoundPlayerManager()
            if (soundPlayerManager?.isPlaying == true) {
                soundPlayerManager.stop()
                return true 
            }
        }
        return super.onKeyDown(keyCode, event)
    }
    // End Signify modification

    override fun onBackPressed() {}
}
