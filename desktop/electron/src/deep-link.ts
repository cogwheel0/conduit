/**
 * `conduit://` links, and what the window is asked to open.
 *
 * A link comes from anywhere on the system -- a web page, another app, a
 * notification -- so it is parsed into one of a few shapes here, in the
 * main process, and the renderer is only ever told which of those to open.
 * Nothing in a link becomes a path the router sees unchecked.
 */
/** A file already uploaded through the daemon, for a new chat to carry. */
export interface OpenedFile {
  readonly id: string
  readonly name: string
  readonly size: number
  readonly contentType?: string
}

export type OpenRequest =
  | { readonly kind: 'chat'; readonly id: string }
  | { readonly kind: 'newChat'; readonly text?: string; readonly files?: readonly OpenedFile[] }
  | { readonly kind: 'channel'; readonly id: string }
  | { readonly kind: 'note'; readonly id: string }
  | { readonly kind: 'settings'; readonly tab?: string }

export const DEEP_LINK_SCHEME = 'conduit'

const ID = /^[A-Za-z0-9:_.-]{1,128}$/
const TAB = /^[a-z]{1,32}$/
const MAX_TEXT = 8000

/** What [url] asks for, or null when it is not a link this app opens. */
export function parseDeepLink(url: string): OpenRequest | null {
  // `URL` would resolve dot segments into some other, valid-looking link;
  // one that needs them is not one to open.
  if (/(^|\/)\.{1,2}(\/|$)/.test(url.split(/[?#]/)[0] ?? '')) return null
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  if (parsed.protocol !== `${DEEP_LINK_SCHEME}:`) return null
  // `conduit://chat/abc` puts `chat` in the host; `conduit:chat/abc` in the
  // path. Both are seen in the wild.
  const segments = [parsed.host, ...parsed.pathname.split('/')]
    .map((segment) => decodeURIComponentSafe(segment))
    .filter((segment): segment is string => segment !== null && segment !== '')
  const [kind, id, ...rest] = segments
  if (rest.length > 0) return null
  switch (kind) {
    case 'chat':
      return id !== undefined && ID.test(id) ? { kind: 'chat', id } : null
    case 'new': {
      if (id !== undefined) return null
      const text = parsed.searchParams.get('q') ?? parsed.searchParams.get('prompt')
      return text === null || text.trim() === ''
        ? { kind: 'newChat' }
        : { kind: 'newChat', text: text.slice(0, MAX_TEXT) }
    }
    case 'channel':
    case 'channels':
      return id !== undefined && ID.test(id) ? { kind: 'channel', id } : null
    case 'note':
    case 'notes':
      return id !== undefined && ID.test(id) ? { kind: 'note', id } : null
    case 'settings':
      if (id === undefined) return { kind: 'settings' }
      return TAB.test(id) ? { kind: 'settings', tab: id } : null
    default:
      return null
  }
}

/**
 * Re-checks an [OpenRequest] that came back from the renderer (a
 * notification's target), which is as untrusted as a link.
 */
export function sanitizeOpenRequest(raw: unknown): OpenRequest | null {
  if (raw === null || typeof raw !== 'object') return null
  const source = raw as Record<string, unknown>
  const id = typeof source.id === 'string' && ID.test(source.id) ? source.id : null
  switch (source.kind) {
    case 'chat':
    case 'channel':
    case 'note':
      return id === null ? null : { kind: source.kind, id }
    case 'newChat': {
      const files = Array.isArray(source.files) ? source.files.flatMap(openedFile).slice(0, 20) : []
      return {
        kind: 'newChat',
        ...(typeof source.text === 'string' && source.text.trim() !== ''
          ? { text: source.text.slice(0, MAX_TEXT) }
          : {}),
        ...(files.length > 0 ? { files } : {}),
      }
    }
    case 'settings':
      return typeof source.tab === 'string' && TAB.test(source.tab)
        ? { kind: 'settings', tab: source.tab }
        : { kind: 'settings' }
    default:
      return null
  }
}

function openedFile(raw: unknown): OpenedFile[] {
  if (raw === null || typeof raw !== 'object') return []
  const file = raw as Record<string, unknown>
  if (typeof file.id !== 'string' || !ID.test(file.id)) return []
  if (typeof file.name !== 'string' || file.name === '' || file.name.length > 255) return []
  if (typeof file.size !== 'number' || !Number.isFinite(file.size) || file.size < 0) return []
  return [
    {
      id: file.id,
      name: file.name,
      size: file.size,
      ...(typeof file.contentType === 'string' && file.contentType.length < 128
        ? { contentType: file.contentType }
        : {}),
    },
  ]
}

/** The first `conduit://` link among a process's arguments. */
export function deepLinkInArgs(argv: readonly string[]): string | null {
  return argv.find((arg) => arg.startsWith(`${DEEP_LINK_SCHEME}:`)) ?? null
}

function decodeURIComponentSafe(value: string): string | null {
  try {
    return decodeURIComponent(value)
  } catch {
    return null
  }
}
