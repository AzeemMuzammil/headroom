# Contributing to Headroom

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and ideas

Open an [issue](https://github.com/AzeemMuzammil/headroom/issues/new/choose) using the bug report or feature request template. For security problems, see [SECURITY.md](SECURITY.md) instead.

## Making changes

1. Fork the repo and create a branch from `main`.
2. Build and run your changes:
   ```sh
   brew install xcodegen          # once
   ./scripts/build.sh --install   # build, install to /Applications, launch
   ```
   To work in Xcode, run `xcodegen generate` and open `Headroom.xcodeproj`. The Xcode project is generated from `project.yml` and isn't committed, so add new files on disk rather than through Xcode's project settings.
3. Open a pull request against `main` and fill in the template.

`main` is protected: every change goes through a pull request, and PRs are squash-merged.

Every pull request is built by CI on a macOS runner (`.github/workflows/ci.yml`), and it has to pass before merging.

## Releasing (maintainers)

1. Merge the changes into `main`.
2. In **Actions → Release → Run workflow**, keep the branch on `main` and enter the new version (e.g. `1.2.0`).
3. The workflow builds the app with that version, zips it, tags `v1.2.0` and publishes a GitHub Release. The notes are generated from the merged PRs, with install instructions added.

### Signing and notarization

Releases are signed with a Developer ID certificate and notarized by Apple when these are configured in **Settings → Secrets and variables → Actions**. Without them, releases are ad-hoc signed and users have to click "Open Anyway".

| Name | Kind | Value |
|---|---|---|
| `MACOS_CERTIFICATE_P12` | secret | Base64 of the "Developer ID Application" certificate exported as .p12 |
| `MACOS_CERTIFICATE_PASSWORD` | secret | The .p12 export password |
| `NOTARY_API_KEY_P8` | secret | Base64 of an App Store Connect API key (.p8) with Developer access |
| `NOTARY_API_KEY_ID` | secret | That key's ID |
| `NOTARY_API_ISSUER_ID` | secret | The Issuer ID shown above the API keys list |
| `APPLE_TEAM_ID` | variable | The team ID of the certificate |
| `RELEASE_BUNDLE_ID` | variable | The bundle ID for release builds |

Signed builds use the hardened runtime and a secure timestamp. The workflow imports the certificate into a temporary keychain and deletes it at the end.

## Guidelines

- **Match the surrounding code:** SwiftUI, Swift Charts, no third-party dependencies.
- **Keep it private by default.** Nothing should leave the user's Mac except Direct mode's single request to `api.anthropic.com`. Never log, store or send credentials.
- **Screenshots:** use `Headroom --render-preview <dir>`, which renders sample data. Never share `--live` renders, since they include your own project names.
- **Signing:** keep your personal signing settings in `Config/Local.xcconfig` (gitignored). Don't change `Config/Base.xcconfig` for that.
- **Colors:** chart colors follow a palette checked for colorblind readability (see `App/UI/Components/Theme.swift`). Use the existing slots rather than new colors.
- **The usage API is undocumented.** If it changes, the parser in `App/Services/UsageAPI.swift` is the place to update. Include a sample response in the PR with any identifying fields removed.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
