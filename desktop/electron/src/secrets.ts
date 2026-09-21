import { randomBytes } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { safeStorage } from 'electron'

/** Bytes of entropy for both the session token and the master key. */
const KEY_BYTES = 32

export interface CoreSecrets {
  /**
   * Authorizes RPC and HTTP calls from the renderer.
   *
   * Regenerated on every launch and never persisted, so a token that leaks
   * into a log or a crash dump is worthless once the app restarts.
   */
  readonly sessionToken: string
  /** Base64 of the key that encrypts the daemon's secure store. */
  readonly masterKey: string
  /**
   * True when the OS refused to give us a real keyring, so the master key is
   * sitting on disk in plaintext. Surfaced once in the UI rather than
   * silently degrading the user's threat model.
   */
  readonly masterKeyIsPlaintext: boolean
}

/**
 * Loads or creates the daemon's secrets.
 *
 * The master key must survive restarts — it decrypts the stored server
 * credentials — so it is written to `userData/secure/master.bin` wrapped by
 * Electron's `safeStorage` (Keychain, DPAPI, libsecret/kwallet).
 *
 * On a Linux box with no keyring `safeStorage` reports the `basic_text`
 * backend, which is obfuscation rather than encryption. Refusing to run would
 * strand those users, so the key is still written and the caller is told, per
 * the section 11 mitigation.
 */
export function loadOrCreateSecrets(userDataDir: string): CoreSecrets {
  const keyPath = join(userDataDir, 'secure', 'master.bin')
  const encryptionAvailable = safeStorage.isEncryptionAvailable()
  const backend =
    process.platform === 'linux' && encryptionAvailable
      ? safeStorage.getSelectedStorageBackend()
      : null
  const masterKeyIsPlaintext = !encryptionAvailable || backend === 'basic_text'

  let masterKey: Buffer | null = null
  if (existsSync(keyPath)) {
    const stored = readFileSync(keyPath)
    try {
      masterKey = encryptionAvailable
        ? Buffer.from(safeStorage.decryptString(stored), 'base64')
        : Buffer.from(stored.toString('utf8'), 'base64')
    } catch {
      // A key we cannot decrypt is a key the user's credentials are already
      // lost to (a restored profile, a changed OS account). Starting over
      // beats refusing to launch; the daemon will ask them to sign in again.
      masterKey = null
    }
    if (masterKey?.length !== KEY_BYTES) masterKey = null
  }

  if (masterKey === null) {
    masterKey = randomBytes(KEY_BYTES)
    mkdirSync(dirname(keyPath), { recursive: true })
    const encoded = masterKey.toString('base64')
    writeFileSync(
      keyPath,
      encryptionAvailable ? safeStorage.encryptString(encoded) : Buffer.from(encoded, 'utf8'),
      { mode: 0o600 },
    )
    // writeFileSync only applies `mode` when it creates the file, so set it
    // explicitly for the overwrite case.
    chmodSync(keyPath, 0o600)
  }

  return {
    // base64url without padding: 43 chars for 32 bytes, and safe to carry in
    // a WebSocket subprotocol token, which forbids `=`.
    sessionToken: randomBytes(KEY_BYTES).toString('base64url'),
    masterKey: masterKey.toString('base64'),
    masterKeyIsPlaintext,
  }
}
