# Phone setup (Android, one time)

DevStore publishes each Android app as a GitHub Release. **Obtainium** on the
phone watches those releases and installs updates by itself.

## 1. Install Obtainium
Download it from its GitHub releases page (github.com/ImranR98/Obtainium,
pick the `app-arm64-v8a-release.apk` or the universal APK) or from F-Droid.
Allow your browser or file manager to "install unknown apps" when asked.

## 2. Give Obtainium read access to your private repos
1. On GitHub: **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. Resource owner: `qawalah`. Repository access: **All repositories** (or
   pick your app repos). Permissions: **Contents → Read-only**. Pick an
   expiry you'll remember, such as 1 year.
3. In Obtainium: **Settings → GitHub → Personal access token**, then paste it.

The Windows updater uses the same kind of token, and you can reuse this one.

## 3. Add each app
1. Obtainium → **Add app** → paste the repo URL, for example
   `https://github.com/qawalah/my-app`.
2. If the repo also releases a Windows app, open the source settings and set
   **Filter release titles/tags by regular expression** to `^android-`.
3. Tap **Add** and install.

> **Already have the app installed from a manual APK?** Uninstall it first
> (export any data you care about), then install it through Obtainium. The
> old APK was signed with a different key, so Android refuses to update it,
> and Obtainium must be the app's installer to update it silently.

## 4. Turn on background updates
Obtainium → **Settings** (menu names can differ slightly between Obtainium versions):
- **Background update checking**: on (for example, every 1 hour).
- **Enable background updates**: on.

On Android 12 and newer, Obtainium can then update apps it installed without
asking you. On some phones, battery optimization can delay checks; set
Obtainium's battery usage to **Unrestricted** if updates arrive late.

## Google's developer verification (2026–2027)
Google is rolling out a rule that apps must come from a verified developer.
It's already enforced in Brazil, Indonesia, Singapore and Thailand, with
worldwide enforcement planned for 2027. Where it applies, unregistered apps
(like yours) still install if you turn on the **advanced sideloading
option** in Developer Options once. There's a one-time 24-hour wait. Check
this again before 2027.

## Test builds (before a pull request is merged)
Each pull request in an app's repo also publishes a test build as a
**pre-release**. In Obtainium, open the app → settings → turn on **Include
prereleases** to get them; turn it off to go back to normal releases.

Android only accepts an update with the same or a higher `versionCode`. If a
test build raised `versionCode`, going back to the stable release needs an
uninstall first. Raise `versionCode` only when the change is ready to release.
