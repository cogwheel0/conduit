package app.cogwheel.conduit

import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import java.security.KeyStore

/**
 * Hands Dart the certificate authorities the user installed in Settings.
 *
 * network_security_config.xml trusts them for the Java and WebView stacks,
 * but Dart's own TLS reads only the system store.
 */
class UserCertificatesBridge : UserCertificatesHostApi {
    private var engine: FlutterEngine? = null

    fun setup(flutterEngine: FlutterEngine) {
        engine = flutterEngine
        UserCertificatesHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    fun dispose() {
        engine?.let { UserCertificatesHostApi.setUp(it.dartExecutor.binaryMessenger, null) }
        engine = null
    }

    override fun userCaCertificates(): List<String> {
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
}
