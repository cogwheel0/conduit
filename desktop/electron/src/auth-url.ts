/**
 * URL rules for external sign-in, with no Electron import.
 *
 * Separate from `auth-window.ts` so it can be unit tested: that module pulls
 * in `electron`, which cannot be loaded outside an Electron process, and this
 * is the part with rules worth asserting rather than plumbing.
 */

/** Rejected before a window is ever created. */
export class AuthWindowRejected extends Error {}

/** The origin of [url], or null if it is not a URL at all. */
export function originOf(url: string): string | null {
  try {
    return new URL(url).origin
  } catch {
    return null
  }
}

/**
 * Accepts only absolute http(s) URLs.
 *
 * `file:` would load from disk with no meaningful origin, and a custom scheme
 * can reach a registered protocol handler — including our own `app://`, which
 * is how a sign-in window would get back the preload bridge it is not
 * supposed to have. Neither belongs in a window whose cookies we then read.
 */
export function requireHttpUrl(value: string, field: string): string {
  let parsed: URL
  try {
    parsed = new URL(value)
  } catch {
    throw new AuthWindowRejected(`${field} is not a URL`)
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new AuthWindowRejected(`${field} must be http or https`)
  }
  return parsed.toString()
}

/** The origin of an http(s) URL, rejecting anything else. */
export function requireHttpOrigin(value: string, field: string): string {
  return new URL(requireHttpUrl(value, field)).origin
}
