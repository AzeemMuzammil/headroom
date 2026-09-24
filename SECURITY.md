# Security policy

Headroom can read Claude Code's saved login (in Direct mode) and edits `~/.claude/settings.json` (in "Through Claude Code" mode), so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue.** Report it privately through [GitHub's private vulnerability reporting](https://github.com/AzeemMuzammil/headroom/security/advisories/new). Include steps to reproduce and the impact.

You'll get a reply as soon as possible, and credit in the fix if you'd like.

## Scope

Examples of what's in scope:
- credentials being logged, stored, cached or sent anywhere other than `api.anthropic.com`;
- `~/.claude/settings.json` being corrupted or changed beyond the `statusLine` entry;
- the status line helper running something other than the user's own configured command.

Problems with Claude Code or Anthropic's services themselves should go to [Anthropic](https://www.anthropic.com/responsible-disclosure-policy).
