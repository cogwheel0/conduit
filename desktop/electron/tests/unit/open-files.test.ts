import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, it } from 'node:test'
import { sanitizeOpenRequest } from '../../src/deep-link.js'
import { filesInArgs } from '../../src/open-files.js'

describe('filesInArgs', () => {
  it('finds files, relative or absolute, and nothing else', () => {
    const dir = mkdtempSync(join(tmpdir(), 'conduit-open-'))
    try {
      writeFileSync(join(dir, 'notes.md'), '# hi')
      writeFileSync(join(dir, 'photo.png'), '')
      const argv = [
        '/usr/bin/conduit',
        '--no-sandbox',
        'notes.md',
        join(dir, 'photo.png'),
        'conduit://chat/1',
        'missing.txt',
        dir,
      ]
      assert.deepEqual(filesInArgs(argv, dir, 1), [join(dir, 'notes.md'), join(dir, 'photo.png')])
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('a new chat with files', () => {
  it('keeps well-formed files and drops the rest', () => {
    assert.deepEqual(
      sanitizeOpenRequest({
        kind: 'newChat',
        files: [
          { id: 'f1', name: 'notes.md', size: 4, contentType: 'text/markdown' },
          { id: '../f2', name: 'x', size: 1 },
          { id: 'f3', name: '', size: 1 },
          'nonsense',
        ],
      }),
      {
        kind: 'newChat',
        files: [{ id: 'f1', name: 'notes.md', size: 4, contentType: 'text/markdown' }],
      },
    )
  })
})
