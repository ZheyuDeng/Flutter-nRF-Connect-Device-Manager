;(function () {
  if (!navigator.bluetooth || window._mcumgrSetupDone) return
  window._mcumgrSetupDone = true
  window._mcumgrDeviceCache = new Map()

  const SMP_SERVICE_UUID = '8d53dc1d-1db7-4cd3-868b-8a527460aa84'

  const _original = navigator.bluetooth.requestDevice.bind(navigator.bluetooth)
  navigator.bluetooth.requestDevice = async function (options, ...rest) {
    // Ensure the SMP service is always in optionalServices so MCUmgr can access it
    if (options) {
      options.optionalServices = options.optionalServices || []
      if (!options.optionalServices.includes(SMP_SERVICE_UUID)) {
        options.optionalServices.push(SMP_SERVICE_UUID)
      }
    }
    const device = await _original(options, ...rest)
    if (device && device.id) {
      window._mcumgrDeviceCache.set(device.id, device)
      console.log(`[McuMgr] Cached BLE device: ${device.id} (${device.name})`)
    }
    return device
  }
})()
