"""Remote UI test of a Windows app in the VM, driven from this host.

    winvm uitest start
    pip install Appium-Python-Client
    python examples/uitest.py [PORT]      # default 47230 (VM "default")

Opens Notepad in the VM, types into it, reads the text back and saves a
screenshot. Copy the WinAppDriver class into your own tests.
"""
import sys

from appium import webdriver
from appium.options.windows import WindowsOptions
from appium.webdriver.common.appiumby import AppiumBy


class WinAppDriver(webdriver.Remote):
    """Appium/Selenium 4 client adapted to WinAppDriver 1.2, which speaks the
    older JSON Wire Protocol."""

    def execute(self, driver_command, params=None):
        # It only reads the legacy 'desiredCapabilities', without 'appium:' prefixes.
        if driver_command == 'newSession':
            caps = params['capabilities']['alwaysMatch']
            params = {**params, 'desiredCapabilities': {k.split(':', 1)[-1]: v for k, v in caps.items()}}
        return super().execute(driver_command, params)

    def _unwrap_value(self, value):
        # It returns elements as {'ELEMENT': id}, which Selenium 4 no longer converts.
        if isinstance(value, dict) and 'ELEMENT' in value:
            return self.create_web_element(value['ELEMENT'])
        return super()._unwrap_value(value)


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else '47230'
    opts = WindowsOptions()
    opts.app = r'C:\Windows\System32\notepad.exe'   # or an AppUserModelId, or 'Root' for the desktop
    driver = WinAppDriver(f'http://127.0.0.1:{port}', options=opts)
    try:
        edit = driver.find_element(AppiumBy.CLASS_NAME, 'Edit')
        edit.send_keys('hello from the host')
        print('text in Notepad:', edit.text)
        driver.get_screenshot_as_file('uitest.png')
        print('screenshot: uitest.png')
    finally:
        driver.quit()


if __name__ == '__main__':
    main()
