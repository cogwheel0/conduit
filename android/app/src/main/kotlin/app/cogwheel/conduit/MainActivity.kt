package app.cogwheel.conduit

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat

class MainActivity : FlutterActivity() {
    private lateinit var backgroundStreamingHandler: BackgroundStreamingHandler
    private lateinit var assistIntentChannel: MethodChannel
    
    companion object {
        private const val ASSIST_INTENT_CHANNEL = "conduit/assist_intent"
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        // Ensure content draws behind system bars (backwards compatible helper)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        
        super.onCreate(savedInstanceState)
        
        // Handle ASSIST intent if launched with it
        handleAssistIntent(intent)
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Initialize background streaming handler
        backgroundStreamingHandler = BackgroundStreamingHandler(this)
        backgroundStreamingHandler.setup(flutterEngine)
        
        // Initialize ASSIST intent channel
        assistIntentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ASSIST_INTENT_CHANNEL)
    }
    
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAssistIntent(intent)
    }
    
    private fun handleAssistIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_ASSIST) {
            // Notify Flutter side that ASSIST intent was triggered
            if (::assistIntentChannel.isInitialized) {
                assistIntentChannel.invokeMethod("assistTriggered", null)
            }
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        if (::backgroundStreamingHandler.isInitialized) {
            backgroundStreamingHandler.cleanup()
        }
    }
}
