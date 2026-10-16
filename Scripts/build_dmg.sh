#!/bin/zsh
# Builds a drag-to-install DMG in dist/.
#
#   Scripts/build_dmg.sh                         # development: for installing on your own Macs
#   RELEASE_MODE=developer-id NOTARY_KEYCHAIN_PROFILE=<profile> Scripts/build_dmg.sh
#                                                # signed + notarized, for publishing
#
# Signing comes from Config/Signing.local.xcconfig (see the .example next to it).
# Without it the app is ad-hoc signed, which still installs and runs on this Mac.

set -euo pipefail

fail() {
  print -u2 -- "错误：$*"
  exit 1
}

# Resolve the project from the script's location, whatever the caller's directory.
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
PROJECT_SPEC="${PROJECT_DIRECTORY}/project.yml"
DMG_BACKGROUND_SOURCE="${PROJECT_DIRECTORY}/Branding/DmgBackground.svg"
DMG_LAYOUT_SCRIPT="${SCRIPT_DIRECTORY}/layout_dmg.applescript"
BUILD_TMP_DIRECTORY="${PROJECT_DIRECTORY}/build/tmp"
DIST_DIRECTORY="${PROJECT_DIRECTORY}/dist"
RELEASE_MODE="${RELEASE_MODE:-development}"
APP_NAME="NeoShuttle"

for required_command in SetFile awk codesign diskutil ditto hdiutil osascript plutil security shasum sips spctl xcodebuild xcodegen xcrun; do
  command -v "${required_command}" >/dev/null 2>&1 || fail "缺少必要命令：${required_command}"
done
[[ -f "${PROJECT_SPEC}" ]] || fail "未找到项目配置：${PROJECT_SPEC}"
[[ -f "${DMG_BACKGROUND_SOURCE}" ]] || fail "未找到 DMG 背景：${DMG_BACKGROUND_SOURCE}"
[[ -f "${DMG_LAYOUT_SCRIPT}" ]] || fail "未找到 DMG 布局脚本：${DMG_LAYOUT_SCRIPT}"

# hdiutil still works but prints a deprecation notice per call on recent macOS; keep output readable.
hdiutil() {
  command hdiutil "$@" 2> >(grep -v 'is deprecated' >&2)
}

read_project_setting() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/["[:space:]]/, "", value)
      print value
      exit
    }
  ' "${PROJECT_SPEC}"
}

MARKETING_VERSION="$(read_project_setting MARKETING_VERSION)"
BUILD_NUMBER="$(read_project_setting CURRENT_PROJECT_VERSION)"
[[ "${MARKETING_VERSION}" =~ '^[0-9]+([.][0-9]+)*$' ]] || fail "MARKETING_VERSION 无效：${MARKETING_VERSION:-<空>}"
[[ "${BUILD_NUMBER}" =~ '^[0-9]+$' ]] || fail "CURRENT_PROJECT_VERSION 无效：${BUILD_NUMBER:-<空>}"

case "${RELEASE_MODE}" in
  development) DMG_FILENAME="${APP_NAME}-${MARKETING_VERSION}-development.dmg" ;;
  developer-id)
    DMG_FILENAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
    [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] || fail "developer-id 模式必须设置 NOTARY_KEYCHAIN_PROFILE"
    # Check the profile before the slow build.
    xcrun notarytool history --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" >/dev/null \
      || fail "NOTARY_KEYCHAIN_PROFILE 无效或无法访问公证服务"
    ;;
  *) fail "RELEASE_MODE 仅支持 development 或 developer-id，当前：${RELEASE_MODE}" ;;
esac
DMG_PATH="${DIST_DIRECTORY}/${DMG_FILENAME}"
SHA256_FILENAME="${DMG_FILENAME}.sha256"

mkdir -p "${BUILD_TMP_DIRECTORY}" "${DIST_DIRECTORY}"
WORK_DIRECTORY="$(mktemp -d "${BUILD_TMP_DIRECTORY}/neoshuttle-release.XXXXXX")"
DMG_MOUNT_DEVICE=""
DMG_MOUNT_DIRECTORY=""

cleanup() {
  if [[ -n "${DMG_MOUNT_DEVICE}" ]]; then
    hdiutil detach "${DMG_MOUNT_DEVICE}" >/dev/null 2>&1 \
      || { print -u2 -- "警告：DMG 临时卷卸载失败，保留工作目录：${WORK_DIRECTORY}"; return 0; }
  fi
  # Only ever remove the mktemp directory created above, under build/tmp.
  [[ "${WORK_DIRECTORY}" == "${BUILD_TMP_DIRECTORY}/"* ]] && rm -rf -- "${WORK_DIRECTORY}"
}
trap cleanup EXIT

ARCHIVE_PATH="${WORK_DIRECTORY}/${APP_NAME}.xcarchive"
EXPORT_DIRECTORY="${WORK_DIRECTORY}/Export"
STAGING_DIRECTORY="${WORK_DIRECTORY}/DmgRoot"
READ_WRITE_DMG_PATH="${WORK_DIRECTORY}/${APP_NAME}-layout.dmg"
DMG_MOUNT_POINT="${WORK_DIRECTORY}/DmgMount"
WORK_DMG_PATH="${WORK_DIRECTORY}/${DMG_FILENAME}"
# A unique name while Finder lays the window out, so it can't reuse a cached layout.
LAYOUT_VOLUME_NAME="${APP_NAME} Layout $$-${RANDOM}"

DMG_WINDOW_WIDTH=680
DMG_WINDOW_HEIGHT=382
DMG_ICON_SIZE=128

print "开始构建 ${APP_NAME} ${MARKETING_VERSION} (${BUILD_NUMBER})，模式：${RELEASE_MODE}"

cd "${PROJECT_DIRECTORY}"
xcodegen generate --spec "${PROJECT_SPEC}"
xcodebuild \
  -project "${PROJECT_DIRECTORY}/${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${WORK_DIRECTORY}/DerivedData" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  -quiet \
  archive

if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  EXPORT_OPTIONS_PLIST="${WORK_DIRECTORY}/ExportOptions.plist"
  plutil -create xml1 "${EXPORT_OPTIONS_PLIST}"
  plutil -insert method -string developer-id "${EXPORT_OPTIONS_PLIST}"
  plutil -insert signingStyle -string automatic "${EXPORT_OPTIONS_PLIST}"
  xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIRECTORY}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    -allowProvisioningUpdates \
    -quiet
  APP_PATH="${EXPORT_DIRECTORY}/${APP_NAME}.app"
else
  APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
fi
[[ -d "${APP_PATH}" ]] || fail "未找到构建后的 ${APP_NAME}.app：${APP_PATH}"

# Signature: valid, and of the kind the mode promises.
codesign --verify --deep --strict "${APP_PATH}"
SIGNATURE="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  [[ "${SIGNATURE}" == *"Authority=Developer ID Application:"* ]] || fail "导出的 App 不是 Developer ID 签名"
  SIGNING_TEAM="$(print -r -- "${SIGNATURE}" | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
  # The DMG is signed with the same team's Developer ID identity as the app.
  DMG_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v team="(${SIGNING_TEAM})" '/"Developer ID Application:/ && index($0, team) { print $2; exit }')"
  [[ -n "${DMG_IDENTITY}" ]] || fail "钥匙串中没有团队 ${SIGNING_TEAM} 的 Developer ID Application 证书"
elif [[ "${SIGNATURE}" == *"Signature=adhoc"* ]]; then
  print "签名：临时签名（ad-hoc）。只适合本机使用；复制到其他 Mac 会被 Gatekeeper 拦截。"
else
  print "签名：$(print -r -- "${SIGNATURE}" | awk -F= '/^Authority=/ { print $2; exit }')"
fi

# The bundle must carry the version in project.yml.
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "${INFO_PLIST}")" == "${MARKETING_VERSION}" ]] \
  || fail "App 版本号与 project.yml 不一致"
[[ "$(plutil -extract CFBundleVersion raw "${INFO_PLIST}")" == "${BUILD_NUMBER}" ]] \
  || fail "App build 号与 project.yml 不一致"

# Disk contents: the app, a link to /Applications, the background and the volume icon.
mkdir -p "${STAGING_DIRECTORY}/.background"
ditto "${APP_PATH}" "${STAGING_DIRECTORY}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIRECTORY}/Applications"
VOLUME_ICON_SOURCE="${APP_PATH}/Contents/Resources/AppIcon.icns"
[[ -f "${VOLUME_ICON_SOURCE}" ]] || fail "未找到 AppIcon.icns"
ditto "${VOLUME_ICON_SOURCE}" "${STAGING_DIRECTORY}/.VolumeIcon.icns"
sips -s format png -s dpiWidth 72 -s dpiHeight 72 "${DMG_BACKGROUND_SOURCE}" \
  --out "${STAGING_DIRECTORY}/.background/background.png" >/dev/null

hdiutil create -volname "${LAYOUT_VOLUME_NAME}" -srcfolder "${STAGING_DIRECTORY}" \
  -fs HFS+ -format UDRW -ov "${READ_WRITE_DMG_PATH}" >/dev/null
mkdir -p "${DMG_MOUNT_POINT}"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "${DMG_MOUNT_POINT}" "${READ_WRITE_DMG_PATH}")"
DMG_MOUNT_DEVICE="$(print -r -- "${ATTACH_OUTPUT}" | awk '$2 == "Apple_HFS" { print $1; exit }')"
[[ -n "${DMG_MOUNT_DEVICE}" ]] || fail "无法识别 DMG 的挂载设备"

# Finder writes the window layout (.DS_Store). This needs permission for the
# terminal to control Finder; without it the DMG still works, just unstyled.
if osascript "${DMG_LAYOUT_SCRIPT}" "${DMG_MOUNT_POINT}" \
    "${DMG_WINDOW_WIDTH}" "${DMG_WINDOW_HEIGHT}" 180 150 500 150 "${DMG_ICON_SIZE}"; then
  [[ -s "${DMG_MOUNT_POINT}/.DS_Store" ]] || print -u2 -- "警告：Finder 没有写入布局，DMG 窗口将使用默认排列"
else
  print -u2 -- "警告：无法让 Finder 排列 DMG 窗口（可能缺少“自动化 › 访达”权限），DMG 仍可正常安装"
fi

diskutil rename "${DMG_MOUNT_DEVICE}" "${APP_NAME}" >/dev/null
# Finder drops the preset volume icon when it updates the volume, so add it back last.
ditto "${VOLUME_ICON_SOURCE}" "${DMG_MOUNT_POINT}/.VolumeIcon.icns"
SetFile -a C "${DMG_MOUNT_POINT}"
hdiutil detach "${DMG_MOUNT_DEVICE}" >/dev/null
DMG_MOUNT_DEVICE=""

hdiutil convert "${READ_WRITE_DMG_PATH}" -format UDZO -imagekey zlib-level=9 -ov -o "${WORK_DMG_PATH}" >/dev/null

if [[ "${RELEASE_MODE}" == "developer-id" ]]; then
  codesign --force --timestamp --sign "${DMG_IDENTITY}" "${WORK_DMG_PATH}"
  NOTARY_RESULT="${WORK_DIRECTORY}/notary.json"
  xcrun notarytool submit "${WORK_DMG_PATH}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
    --wait --output-format json > "${NOTARY_RESULT}"
  [[ "$(plutil -extract status raw "${NOTARY_RESULT}")" == "Accepted" ]] \
    || fail "公证未通过：$(plutil -extract id raw "${NOTARY_RESULT}")"
  xcrun stapler staple "${WORK_DMG_PATH}"
  spctl --assess --type open --context context:primary-signature "${WORK_DMG_PATH}"
  print "公证已通过"
fi

# Only bytes that pass verification reach dist/.
hdiutil verify "${WORK_DMG_PATH}" >/dev/null
mv -f -- "${WORK_DMG_PATH}" "${DMG_PATH}"
( cd "${DIST_DIRECTORY}" && shasum -a 256 "${DMG_FILENAME}" > "${SHA256_FILENAME}" )

print "DMG：${DMG_PATH}"
print "SHA-256：${DIST_DIRECTORY}/${SHA256_FILENAME}"
print "安装：打开 DMG，把 ${APP_NAME} 拖到“应用程序”。"
