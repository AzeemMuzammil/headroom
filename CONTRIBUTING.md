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

## Guidelines

- **Match the surrounding code:** SwiftUI, Swift Charts, no third-party dependencies.
- **Keep it private by default.** Nothing should leave the user's Mac except Direct mode's single request to `api.anthropic.com`. Never log, store or send credentials.
- **Screenshots:** use `Headroom --render-preview <dir>`, which renders sample data. Never share `--live` renders, since they include your own project names.
- **Signing:** keep your personal signing settings in `Config/Local.xcconfig` (gitignored). Don't change `Config/Base.xcconfig` for that.
- **Colors:** chart colors follow a palette checked for colorblind readability (see `App/UI/Components/Theme.swift`). Use the existing slots rather than new colors.
- **The usage API is undocumented.** If it changes, the parser in `App/Services/UsageAPI.swift` is the place to update. Include a sample response in the PR with any identifying fields removed.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
