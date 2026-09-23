import { statSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { basename, extname, isAbsolute, resolve } from 'node:path'
import type { OpenedFile } from './deep-link.js'

/**
 * "Open with Conduit" (WP-9.3): files the OS hands the app.
 *
 * The window cannot read a path off the disk -- it is sandboxed, and that
 * is the point -- so the main process uploads each file through the
 * daemon's `/upload`, as the window's own attachments go, and the window is
 * asked to start a chat with them already attached.
 */

/** The most files one "Open with" attaches. */
const MAX_FILES = 10

/** Larger files are left for the attach button, which shows progress. */
const MAX_BYTES = 256 * 1024 * 1024

const TYPES: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.html': 'text/html',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
}

/**
 * The files among a launch's arguments: absolute, or relative to [cwd],
 * and regular files. Flags, links and the app's own path are not files.
 */
export function filesInArgs(argv: readonly string[], cwd: string, skip: number): string[] {
  const files: string[] = []
  for (const arg of argv.slice(skip)) {
    if (arg.startsWith('-') || arg.includes('://') || arg === '.') continue
    const path = isAbsolute(arg) ? arg : resolve(cwd, arg)
    try {
      if (statSync(path).isFile()) files.push(path)
    } catch {
      // Not a path at all.
    }
    if (files.length >= MAX_FILES) break
  }
  return files
}

/** Uploads [paths] through the daemon on [port]; the ones that made it. */
export async function uploadFiles(
  paths: readonly string[],
  port: number,
  token: string,
): Promise<OpenedFile[]> {
  const uploaded: OpenedFile[] = []
  for (const path of paths.slice(0, MAX_FILES)) {
    try {
      if (statSync(path).size > MAX_BYTES) continue
      const bytes = await readFile(path)
      const name = basename(path)
      const contentType = TYPES[extname(path).toLowerCase()] ?? 'application/octet-stream'
      const response = await fetch(`http://127.0.0.1:${port}/upload`, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'x-conduit-filename': encodeURIComponent(name),
          'content-type': contentType,
        },
        body: bytes,
      })
      if (!response.ok) {
        console.warn(`could not open ${name}: the daemon answered ${response.status}`)
        continue
      }
      const file = (await response.json()) as { id: string; name: string; size: number }
      uploaded.push({ id: file.id, name: file.name, size: file.size, contentType })
    } catch (error) {
      console.warn('could not open a file', error)
    }
  }
  return uploaded
}
