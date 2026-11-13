# changelog.d

One file per change that a user can see, assembled into `CHANGELOG.md` by `clichetool ship <patch|minor|major|x.y.z>`, which then
deletes them. Do not edit `CHANGELOG.md` by hand.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Fixed

**Short summary**: what changed for the user, in one entry (no leading "- ").
```

- `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)).
- The text is one entry of the list. It can span lines; sub-items are indented `  - ` lines; no blank line, no heading.
- A change that no user can see has no fragment.

gui_toolkit's `gt:changelog` reads and assembles them (its docs/changelog.md).
