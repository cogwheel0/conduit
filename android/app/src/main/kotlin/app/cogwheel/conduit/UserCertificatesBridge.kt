package app.cogwheel.conduit

import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import java.security.KeyStore
import java.util.concurrent.Executor

/**
 * Hands Dart the certificate authorities the user installed in Settings.
 *
 * network_security_config.xml trusts them for the Java and WebView stacks,
 * but Dart's own TLS reads only the system store.
 *
 * Loading AndroidCAStore reads every system CA file, so the read runs on
 * [executor] and the reply is posted back to the main thread.
 */
class UserCertificatesBridge(
    private val executor: Executor = Executor { Thread(it, "user-ca-read").start() },
    private val readCertificates: () -> List<String> = ::readUserCaCertificates,
) : UserCertificatesHostApi {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null

    fun setup(flutterEngine: FlutterEngine) {
        engine = flutterEngine
        UserCertificatesHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    fun dispose() {
        engine?.let { UserCertificatesHostApi.setUp(it.dartExecutor.binaryMessenger, null) }
        engine = null
    }

    override fun userCaCertificates(callback: (Result<List<String>>) -> Unit) {
        executor.execute {
            val result = runCatching(readCertificates)
            mainHandler.post { callback(result) }
        }
    }
}

internal fun readUserCaCertificates(): List<String> {
    val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
    return store.aliases().toList()
        .filter { it.startsWith("user:") }
        .mapNotNull { store.getCertificate(it)?.encoded }
        .map { der ->
            "-----BEGIN CERTIFICATE-----\n" +
                Base64.encodeToString(der, Base64.DEFAULT) +
                "-----END CERTIFICATE-----\n"
        }
}
