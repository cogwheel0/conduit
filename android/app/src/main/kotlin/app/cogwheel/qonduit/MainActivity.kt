package app.cogwheel.qonduit

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Build
import android.os.Bundle
import android.webkit.CookieManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat

class MainActivity : FlutterActivity() {
    private lateinit var backgroundStreamingHandler: BackgroundStreamingHandler

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Enable edge-to-edge display for all Android versions
        // This is the official way to enable edge-to-edge that works with Android 15+
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Configure system bar appearance for edge-to-edge
        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightStatusBars = false
        windowInsetsController.isAppearanceLightNavigationBars = false
    }
    
    private val CHANNEL = "app.cogwheel.qonduit/assistant"
    private var methodChannel: io.flutter.plugin.common.MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize background streaming handler
        backgroundStreamingHandler = BackgroundStreamingHandler(this)
        backgroundStreamingHandler.setup(flutterEngine)

        methodChannel = io.flutter.plugin.common.MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        // Setup cookie manager channel for WebView cookie access
        val cookieChannel = io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.qonduit.app/cookies"
        )
        
        cookieChannel.setMethodCallHandler { call, result ->
            if (call.method == "getCookies") {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("INVALID_ARGS", "Invalid URL", null)
                    return@setMethodCallHandler
                }
                
                // Get cookies from Android's CookieManager (shared with WebView)
                val cookieManager = CookieManager.getInstance()
                val cookieString = cookieManager.getCookie(url)
                
                val cookieMap = mutableMapOf<String, String>()
                if (cookieString != null) {
                    // Parse cookie string: "name1=value1; name2=value2"
                    cookieString.split(";").forEach { cookie ->
                        val parts = cookie.trim().split("=", limit = 2)
                        if (parts.size == 2) {
                            cookieMap[parts[0].trim()] = parts[1].trim()
                        }
                    }
                }
                
                result.success(cookieMap)
            } else {
                result.notImplemented()
            }
        }
        
        // Check if started with context
        handleIntent(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: android.content.Intent) {
        android.util.Log.d("MainActivity", "handleIntent called")
        android.util.Log.d("MainActivity", "Intent extras: ${intent.extras?.keySet()}")

        val screenContext = intent.getStringExtra("screen_context")
        val screenshotPath = intent.getStringExtra("screenshot_path")
        val startVoiceCall = intent.getBooleanExtra("start_voice_call", false)
        val startNewChat = intent.getBooleanExtra("start_new_chat", false)

        android.util.Log.d("MainActivity", "screenContext: $screenContext")
        android.util.Log.d("MainActivity", "screenshotPath: $screenshotPath")
        android.util.Log.d("MainActivity", "startVoiceCall: $startVoiceCall")
        android.util.Log.d("MainActivity", "startNewChat: $startNewChat")
        android.util.Log.d("MainActivity", "methodChannel: $methodChannel")

        if (startVoiceCall) {
            android.util.Log.d("MainActivity", "Invoking startVoiceCall")
            methodChannel?.invokeMethod("startVoiceCall", null)
        } else if (startNewChat) {
            android.util.Log.d("MainActivity", "Invoking startNewChat")
            methodChannel?.invokeMethod("startNewChat", null)
        } else if (screenContext != null) {
            android.util.Log.d("MainActivity", "Invoking analyzeScreen")
            methodChannel?.invokeMethod("analyzeScreen", screenContext)
        } else if (screenshotPath != null) {
            android.util.Log.d("MainActivity", "Invoking analyzeScreenshot with path: $screenshotPath")
            methodChannel?.invokeMethod("analyzeScreenshot", screenshotPath)
        } else {
            android.util.Log.d("MainActivity", "No screen context or screenshot path found")
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        if (::backgroundStreamingHandler.isInitialized) {
            backgroundStreamingHandler.cleanup()
        }
    }
}
