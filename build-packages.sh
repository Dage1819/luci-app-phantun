#!/bin/bash
set -e

PKG_NAME="luci-app-phantun"
PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' Makefile | head -n1 | tr -d '\r[:space:]')"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' Makefile | head -n1 | tr -d '\r[:space:]')"
MAINTAINER="Dage"
DESCRIPTION="LuCI support for Phantun (UDP over FakeTCP)"
HOMEPAGE="https://github.com/Dage1819/luci-app-phantun"
LICENSE="Apache-2.0"
DIST_DIR="${DIST_DIR:-dist}"
WORK_DIR="$(mktemp -d)"
TAR="$(command -v gtar 2>/dev/null || command -v tar)"

trap 'rm -rf "$WORK_DIR"' EXIT

[ -n "$PKG_VERSION" ] || { echo "PKG_VERSION missing" >&2; exit 1; }
[ -n "$PKG_RELEASE" ] || { echo "PKG_RELEASE missing" >&2; exit 1; }

IPK_FILE="${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
APK_FILE="${PKG_NAME}-${PKG_VERSION}-r${PKG_RELEASE}.apk"
DATA_DIR="$WORK_DIR/data"
mkdir -p "$DATA_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cp -a root/. "$DATA_DIR/"
if [ -d htdocs ]; then
    mkdir -p "$DATA_DIR/www"
    cp -a htdocs/. "$DATA_DIR/www/"
fi
find "$DATA_DIR" -type f -name '*.sh' -exec chmod 755 {} +
find "$DATA_DIR/etc/init.d" -type f -exec chmod 755 {} + 2>/dev/null || true
INSTALLED_SIZE="$(du -sk "$DATA_DIR" | awk '{print $1}')"

make_ipk() {
    local ipk_dir="$WORK_DIR/ipk"
    mkdir -p "$ipk_dir/control"
    cat > "$ipk_dir/control/control" <<EOF
Package: $PKG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Architecture: all
Maintainer: $MAINTAINER
Section: luci
Priority: optional
Installed-Size: $INSTALLED_SIZE
Depends: kmod-tun, unzip, curl, bind-host | drill
Description: $DESCRIPTION
Homepage: $HOMEPAGE
License: $LICENSE
EOF
    cat > "$ipk_dir/control/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
[ -x /etc/init.d/phantun ] && /etc/init.d/phantun enable 2>/dev/null
exit 0
EOF
    chmod 755 "$ipk_dir/control/postinst"
    cat > "$ipk_dir/control/postrm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
[ "$PKG_UPGRADE" = "1" ] && exit 0
[ -x /etc/init.d/phantun ] && /etc/init.d/phantun stop 2>/dev/null
killall phantun_server phantun_client 2>/dev/null || true
[ -x /usr/share/phantun/route.sh ] && /usr/share/phantun/route.sh flush_all 2>/dev/null || true
rm -f /usr/bin/phantun_server /usr/bin/phantun_client
rm -f /tmp/phantun_init.status /tmp/phantun_init.log
rm -rf /tmp/phantun_dl /var/run/phantun /usr/share/phantun
rm -f /etc/config/phantun /var/log/phantun*
exit 0
EOF
    chmod 755 "$ipk_dir/control/postrm"
    printf '2.0\n' > "$ipk_dir/debian-binary"
    (cd "$DATA_DIR" && "$TAR" --format=gnu --numeric-owner --owner=0 --group=0 -cf - . | gzip -n > "$ipk_dir/data.tar.gz")
    (cd "$ipk_dir/control" && "$TAR" --format=gnu --numeric-owner --owner=0 --group=0 -cf - . | gzip -n > "$ipk_dir/control.tar.gz")
    (cd "$ipk_dir" && "$TAR" --format=gnu --numeric-owner --owner=0 --group=0 -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n > "$OLDPWD/$DIST_DIR/$IPK_FILE")
}

make_apk() {
    command -v docker >/dev/null 2>&1 || { echo "Docker is required to build APK" >&2; exit 1; }
    local apk_dir="$WORK_DIR/apk"
    mkdir -p "$apk_dir"
    cat > "$apk_dir/post-install.sh" <<'EOF'
#!/bin/sh
[ -n "$APK_INSTROOT" ] && exit 0
[ -x /etc/init.d/phantun ] && /etc/init.d/phantun enable 2>/dev/null
exit 0
EOF
    cat > "$apk_dir/post-deinstall.sh" <<'EOF'
#!/bin/sh
[ -n "$APK_INSTROOT" ] && exit 0
[ -x /etc/init.d/phantun ] && /etc/init.d/phantun stop 2>/dev/null || true
killall phantun_server phantun_client 2>/dev/null || true
[ -x /usr/share/phantun/route.sh ] && /usr/share/phantun/route.sh flush_all 2>/dev/null || true
rm -f /usr/bin/phantun_server /usr/bin/phantun_client
rm -f /tmp/phantun_init.status /tmp/phantun_init.log
rm -rf /tmp/phantun_dl /var/run/phantun /usr/share/phantun
rm -f /etc/config/phantun /var/log/phantun*
exit 0
EOF
    chmod 755 "$apk_dir/post-install.sh" "$apk_dir/post-deinstall.sh"

    # Pin apk-tools v3 to a verified commit. Alpine's normal runtime apk is
    # often still v2 and does not provide mkpkg/mkndx, while cloning HEAD made
    # this build change underneath us. Build only the components required for
    # v3 packaging, then use that exact binary for creation and validation.
    docker run --rm \
        -e PKG_NAME="$PKG_NAME" \
        -e PKG_VERSION="$PKG_VERSION" \
        -e PKG_RELEASE="$PKG_RELEASE" \
        -e DESCRIPTION="$DESCRIPTION" \
        -e HOMEPAGE="$HOMEPAGE" \
        -e LICENSE="$LICENSE" \
        -e MAINTAINER="$MAINTAINER" \
        -e APK_FILE="$APK_FILE" \
        -v "$DATA_DIR:/pkg/files:ro" \
        -v "$apk_dir/post-install.sh:/pkg/post-install.sh:ro" \
        -v "$apk_dir/post-deinstall.sh:/pkg/post-deinstall.sh:ro" \
        -v "$(pwd)/$DIST_DIR:/pkg/out" \
        alpine:3.22 sh -ec '
          APK_TOOLS_COMMIT=9de54a44947b8bbf6b746c9c67bc2e18e4002f3c
          apk add --no-cache build-base git meson samurai linux-headers openssl-dev zlib-dev
          git clone --filter=blob:none --no-checkout https://gitlab.alpinelinux.org/alpine/apk-tools.git /tmp/apk-tools
          git -C /tmp/apk-tools checkout --detach "$APK_TOOLS_COMMIT"
          test "$(git -C /tmp/apk-tools rev-parse HEAD)" = "$APK_TOOLS_COMMIT"
          meson setup /tmp/apk-tools-build /tmp/apk-tools \
            -Ddocs=disabled -Dhelp=disabled -Dlua=disabled \
            -Dpython=disabled -Dtests=disabled -Dzstd=disabled \
            -Durl_backend=wget
          meson compile -C /tmp/apk-tools-build
          APK_BIN=/tmp/apk-tools-build/src/apk
          test -x "$APK_BIN"
          "$APK_BIN" mkpkg \
            --info "name:$PKG_NAME" \
            --info "version:${PKG_VERSION}-r${PKG_RELEASE}" \
            --info "description:$DESCRIPTION" \
            --info "arch:noarch" \
            --info "license:$LICENSE" \
            --info "origin:$PKG_NAME" \
            --info "url:$HOMEPAGE" \
            --info "maintainer:$MAINTAINER" \
            --info "depends:kmod-tun unzip curl bind-host" \
            --script "post-install:/pkg/post-install.sh" \
            --script "post-deinstall:/pkg/post-deinstall.sh" \
            --files /pkg/files \
            --output "/pkg/out/$APK_FILE"
          test -s "/pkg/out/$APK_FILE"
          "$APK_BIN" adbdump --format json "/pkg/out/$APK_FILE" > /pkg/out/apk-metadata.json
          grep -q "luci-app-phantun" /pkg/out/apk-metadata.json
          "$APK_BIN" mkndx --allow-untrusted -o /pkg/out/packages.adb "/pkg/out/$APK_FILE"
          test -s /pkg/out/packages.adb
          "$APK_BIN" adbdump --format json /pkg/out/packages.adb > /dev/null
        '
}

echo "==> Building $IPK_FILE"
make_ipk
echo "==> Building $APK_FILE"
make_apk
echo "==> Validating package archives"
test -s "$DIST_DIR/$IPK_FILE"
test -s "$DIST_DIR/$APK_FILE"
tar -tzf "$DIST_DIR/$IPK_FILE" | grep -q './data.tar.gz'
tar -tzf "$DIST_DIR/$IPK_FILE" | grep -q './control.tar.gz'
ls -lh "$DIST_DIR/$IPK_FILE" "$DIST_DIR/$APK_FILE"
