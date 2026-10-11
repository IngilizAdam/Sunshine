import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

vi.mock('../../src_assets/common/assets/web/Navbar.vue', () => ({
  default: { template: '<div />' },
}))
vi.mock('../../src_assets/common/assets/web/fetch_utils', () => ({
  apiFetch: vi.fn(() => Promise.resolve({ status: 200 })),
}))

import Apps from '../../src_assets/common/assets/web/Apps.vue'
import AudioVideo from '../../src_assets/common/assets/web/configs/tabs/AudioVideo.vue'
import configTabs from '../../src_assets/common/assets/web/configs/config_tabs.json'
import configDocumentation from '../../docs/configuration.md?raw'

const OPTIONS = ['headless_mode', 'virtual_display_hidpi', 'virtual_display_make_main']

function mountAudioVideo(platform) {
  const config = structuredClone(configTabs.find(tab => tab.id === 'av').options)
  const wrapper = mount(AudioVideo, {
    props: { platform, config },
    global: {
      mocks: { $t: key => key },
      provide: {
        platform: ref(platform),
        i18n: { t: key => key },
      },
      stubs: {
        AdapterNameSelector: true,
        DisplayOutputSelector: true,
        DisplayDeviceOptions: true,
        DisplayModesSettings: true,
      },
    },
  })
  return { wrapper, config }
}

/**
 * Build a minimal context object that satisfies the `this` contract of newApp() and editApp().
 *
 * @param {string} platform Host platform reported by the server.
 * @param {object[]} apps Apps loaded from apps.json.
 * @returns {object} A stub context for `.call()`.
 */
function appsContext(platform, apps = []) {
  return {
    platform,
    apps,
    editForm: null,
    editFormError: '',
    openEditModal: vi.fn(),
  }
}

afterEach(() => {
  vi.restoreAllMocks()
  document.body.innerHTML = ''
})

describe('virtual display configuration', () => {
  it('shows the macOS options with their defaults and saves changes', async () => {
    const { wrapper, config } = mountAudioVideo('macos')
    for (const option of OPTIONS) {
      expect(wrapper.find(`#${option}`).exists()).toBe(true)
    }
    expect(config.headless_mode).toBe('disabled')
    expect(config.virtual_display_hidpi).toBe('disabled')
    expect(config.virtual_display_make_main).toBe('enabled')
    expect(wrapper.get('#virtual_display_make_main').element.checked).toBe(true)

    await wrapper.get('#headless_mode').setValue(true)
    await wrapper.get('#virtual_display_hidpi').setValue(true)
    await wrapper.get('#virtual_display_make_main').setValue(false)
    expect(config.headless_mode).toBe('enabled')
    expect(config.virtual_display_hidpi).toBe('enabled')
    expect(config.virtual_display_make_main).toBe('disabled')
    wrapper.unmount()
  })

  it.each(['windows', 'linux', 'freebsd'])('hides the macOS-only options on %s', platform => {
    const { wrapper } = mountAudioVideo(platform)
    for (const option of OPTIONS) {
      expect(wrapper.find(`#${option}`).exists()).toBe(false)
    }
    wrapper.unmount()
  })

  it.each(OPTIONS)('documents %s as a macOS option', option => {
    const section = configDocumentation.split(`### ${option}\n`)[1].split('\n### ')[0]
    expect(section).toContain('only supported on macOS')
  })
})

describe('always use virtual display app option', () => {
  it('defaults new macOS apps to the physical display', () => {
    const ctx = appsContext('macos')
    Apps.methods.newApp.call(ctx)
    expect(ctx.editForm['virtual-display']).toBe(false)
    expect(ctx.openEditModal).toHaveBeenCalled()
  })

  it.each(['windows', 'linux', 'freebsd'])('does not add the option to new apps on %s', platform => {
    const ctx = appsContext(platform)
    Apps.methods.newApp.call(ctx)
    expect(ctx.editForm).not.toHaveProperty('virtual-display')
  })

  it('keeps an existing value and fills a missing one on macOS', () => {
    const ctx = appsContext('macos', [{ name: 'On', 'virtual-display': true }, { name: 'Unset' }])
    Apps.methods.editApp.call(ctx, 0)
    expect(ctx.editForm['virtual-display']).toBe(true)
    Apps.methods.editApp.call(ctx, 1)
    expect(ctx.editForm['virtual-display']).toBe(false)
  })

  it('does not add the option when editing apps on other platforms', () => {
    const ctx = appsContext('linux', [{ name: 'Unset' }])
    Apps.methods.editApp.call(ctx, 0)
    expect(ctx.editForm).not.toHaveProperty('virtual-display')
  })
})
