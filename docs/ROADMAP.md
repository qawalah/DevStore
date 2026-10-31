# DevStore roadmap

Ideas agreed for later. Not built yet.

## Next
- **Add GitHub accounts from Settings.** An "Add account" button in Settings →
  GitHub accounts: paste a token, approve one Windows admin prompt, done. Also
  a Remove button per extra account. The token is handed over through the
  user's private temp folder and deleted after it's saved; the window itself
  never gets admin rights or reads stored tokens. Today this is done with
  `DevStoreSetup.exe` → "Add as another GitHub account".

## Later
- **Choose the install folder** (for example another drive) in setup and
  Settings. Today apps always go to `C:\DevStore\apps`.
- **Exact versions of older images on the NAS.** The NAS page says whether the
  NAS runs the newest version, not which older one it runs (Watchtower doesn't
  report versions). An app's own version endpoint (Werd's `/v1/info`) could add it.
- **Code signing** for the exe files, to avoid Windows SmartScreen and
  antivirus warnings.
- **Android apps in the store window** (read-only list of phone apps and their
  versions, next to the Windows ones).
