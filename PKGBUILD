# Local development package. No downloads, daemons, udev changes or firmware writes.
pkgname=dell-power-extension
pkgver=2.0.0
pkgrel=1
pkgdesc='Transactional Dell/Alienware power helper for the local Omarchy extension'
arch=('any')
license=('MIT')
options=('!debug')
depends=('python' 'power-profiles-daemon' 'sudo' 'polkit' 'dbus')
source=()
sha256sums=()

package() {
  install -Dm755 "$startdir/system/control" "$pkgdir/usr/lib/dell-power-extension/control"
  install -Dm644 "$startdir/system/backend.py" "$pkgdir/usr/lib/dell-power-extension/backend.py"
  install -Dm755 "$startdir/system/setup" "$pkgdir/usr/lib/dell-power-extension/setup"
  install -Dm644 "$startdir/system/local.dell-power-extension.policy" "$pkgdir/usr/lib/dell-power-extension/control.policy"
  install -Dm644 "$startdir/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -dm755 "$pkgdir/usr/lib/dell-power-extension"
  printf '%s\n' 'local.dell-power-extension' > "$pkgdir/usr/lib/dell-power-extension/INSTALLER_OWNER"
}
