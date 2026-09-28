import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { deepLinkInArgs, parseDeepLink, sanitizeOpenRequest } from '../../src/deep-link.js'
import {
  DEFAULT_SHELL_SETTINGS,
  isAccelerator,
  sanitizeShellSettings,
} from '../../src/shell-settings.js'

describe('parseDeepLink', () => {
  it('opens a chat, a channel, a note or a settings tab', () => {
    assert.deepEqual(parseDeepLink('conduit://chat/abc-123'), { kind: 'chat', id: 'abc-123' })
    assert.deepEqual(parseDeepLink('conduit:chat/abc'), { kind: 'chat', id: 'abc' })
    assert.deepEqual(parseDeepLink('conduit://channels/c1'), { kind: 'channel', id: 'c1' })
    assert.deepEqual(parseDeepLink('conduit://note/n1'), { kind: 'note', id: 'n1' })
    assert.deepEqual(parseDeepLink('conduit://settings/audio'), { kind: 'settings', tab: 'audio' })
    assert.deepEqual(parseDeepLink('conduit://settings'), { kind: 'settings' })
  })

  it('starts a new chat, with text when given', () => {
    assert.deepEqual(parseDeepLink('conduit://new'), { kind: 'newChat' })
    assert.deepEqual(parseDeepLink('conduit://new?q=Hello%20there'), {
      kind: 'newChat',
      text: 'Hello there',
    })
  })

  for (const rejected of [
    'https://example.com/chat/1',
    'app://conduit/settings',
    'conduit://chat',
    'conduit://chat/../../etc',
    'conduit://chat/a/b',
    'conduit://chat/%E0%A4%A',
    'conduit://settings/Audio<script>',
    'conduit://unknown/1',
    'not a url',
  ]) {
    it(`refuses ${rejected}`, () => assert.equal(parseDeepLink(rejected), null))
  }

  it('finds a link among arguments', () => {
    assert.equal(deepLinkInArgs(['/app', '--flag', 'conduit://chat/1']), 'conduit://chat/1')
    assert.equal(deepLinkInArgs(['/app']), null)
  })
})

describe('sanitizeOpenRequest', () => {
  it('keeps a well-formed request and drops anything else', () => {
    assert.deepEqual(sanitizeOpenRequest({ kind: 'chat', id: 'c1', extra: 1 }), {
      kind: 'chat',
      id: 'c1',
    })
    assert.equal(sanitizeOpenRequest({ kind: 'chat', id: '../x' }), null)
    assert.equal(sanitizeOpenRequest({ kind: 'path', path: '/etc' }), null)
    assert.equal(sanitizeOpenRequest('chat'), null)
  })
})

describe('shell settings', () => {
  it('accepts accelerators with a modifier and one key', () => {
    assert.ok(isAccelerator('CommandOrControl+Shift+Space'))
    assert.ok(isAccelerator('Alt+K'))
    assert.ok(!isAccelerator('K'))
    assert.ok(!isAccelerator('Shift+'))
    assert.ok(!isAccelerator('Hyper+K'))
  })

  it('keeps known keys of the right type only', () => {
    const next = sanitizeShellSettings(
      { closeToTray: true, launchAtLogin: 'yes', quickAskShortcut: 'K', evil: true },
      DEFAULT_SHELL_SETTINGS,
    )
    assert.equal(next.closeToTray, true)
    assert.equal(next.launchAtLogin, false)
    assert.equal(next.quickAskShortcut, DEFAULT_SHELL_SETTINGS.quickAskShortcut)
    assert.equal((next as unknown as Record<string, unknown>).evil, undefined)
  })
})
