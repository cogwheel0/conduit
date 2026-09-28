import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { frameOptions, TITLE_BAR_HEIGHT } from '../../src/window-frame.js'

describe('frameOptions', () => {
  it('keeps the traffic lights on macOS, inset into the drawn bar', () => {
    const options = frameOptions('darwin', 'main')
    assert.equal(options.titleBarStyle, 'hidden')
    assert.equal(options.frame, undefined)
    const y = options.trafficLightPosition?.y ?? -1
    assert.ok(y > 0 && y + 12 < TITLE_BAR_HEIGHT)
  })

  it('draws its own frame on Windows and Linux', () => {
    for (const platform of ['win32', 'linux'] as const) {
      assert.deepEqual(frameOptions(platform, 'main'), { frame: false })
    }
  })

  it('leaves the quick-ask panel frameless everywhere', () => {
    for (const platform of ['darwin', 'win32', 'linux'] as const) {
      assert.deepEqual(frameOptions(platform, 'quickAsk'), { frame: false })
    }
  })
})
