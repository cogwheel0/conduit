import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  AuthWindowRejected,
  originOf,
  requireHttpOrigin,
  requireHttpUrl,
} from '../../src/auth-url.js'

describe('requireHttpUrl', () => {
  it('accepts http and https', () => {
    assert.equal(requireHttpUrl('https://chat.example.com/auth', 'startUrl'),
      'https://chat.example.com/auth')
    assert.equal(requireHttpUrl('http://localhost:8080/', 'startUrl'),
      'http://localhost:8080/')
  })

  for (const rejected of [
    // Would load from disk with no meaningful origin.
    'file:///etc/passwd',
    // Reaches a registered protocol handler -- including our own, which is
    // how a sign-in window would get back the preload bridge.
    'app://conduit/',
    'conduit://chat/1',
    'javascript:alert(1)',
    'data:text/html,<h1>hi',
    'not a url',
    '',
  ]) {
    it(`rejects ${rejected || '(empty)'}`, () => {
      assert.throws(
        () => requireHttpUrl(rejected, 'startUrl'),
        AuthWindowRejected,
      )
    })
  }

  it('names the field it rejected, so the message is actionable', () => {
    assert.throws(
      () => requireHttpUrl('file:///x', 'serverUrl'),
      (error: unknown) =>
        error instanceof AuthWindowRejected &&
        error.message.includes('serverUrl'),
    )
  })
})

describe('requireHttpOrigin', () => {
  it('drops the path, query and fragment', () => {
    assert.equal(
      requireHttpOrigin('https://chat.example.com/a/b?c=d#e', 'serverUrl'),
      'https://chat.example.com',
    )
  })

  it('keeps a non-default port, which is part of the origin', () => {
    // Capture is scoped by origin, so treating :8443 as the same origin as
    // :443 would attach one server's cookies to another.
    assert.equal(
      requireHttpOrigin('https://chat.example.com:8443/', 'serverUrl'),
      'https://chat.example.com:8443',
    )
  })

  it('normalizes the default port away', () => {
    assert.equal(
      requireHttpOrigin('https://chat.example.com:443/', 'serverUrl'),
      'https://chat.example.com',
    )
  })
})

describe('originOf', () => {
  it('returns null rather than throwing on junk', () => {
    // Called on every navigation, including about:blank and the initial
    // empty document; a throw there would abort the flow.
    assert.equal(originOf('not a url'), null)
    assert.equal(originOf(''), null)
  })

  it('distinguishes a lookalike host', () => {
    assert.notEqual(
      originOf('https://chat.example.com.evil.test/'),
      originOf('https://chat.example.com/'),
    )
  })

  it('distinguishes scheme', () => {
    assert.notEqual(
      originOf('http://chat.example.com/'),
      originOf('https://chat.example.com/'),
    )
  })
})
