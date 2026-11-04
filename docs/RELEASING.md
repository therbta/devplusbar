# Releasing Dev+ Bar

Default release path (required for normal releases):

```sh
make preflight-release
make release
make publish
```

`make preflight-release` must pass before a strict release. It checks that:

1. The Developer ID signing identity is in the Keychain (`SIGN_ID` in the Makefile).
2. Notary credentials work for `xcrun notarytool` (the `NOTARY_PROFILE` keychain profile, or
   `NOTARY_KEY_ID` and `NOTARY_ISSUER`).

`make publish` refuses to upload a build that `spctl` rejects.

Before releasing, bump `VERSION` in the Makefile and add `docs/release-notes/v<VERSION>.md`.

## Emergency fallback

Only when signing or notarization is temporarily unavailable:

```sh
make release SKIP_NOTARIZE=1
make publish ALLOW_UNNOTARIZED_PUBLISH=1
```

Do not use fallback flags as default release policy.
