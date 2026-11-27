# Agent rules for Cala

## Install every change

Every change to the app ends published on GitHub and installed, with no need to ask.

1. Build passes and the `scripts/check-*.sh` checks pass.
2. Write `docs/releases/<version>.en.md` and `docs/releases/<version>.es.md` and commit them with the change. Keep both sets of notes short, user-facing and in plain language.
3. Run `./scripts/ship.sh` from the repo root in the owner's Terminal panel and wait for it to finish. It verifies the signed public GitHub release, installs Cala and relaunches it. After setup, shipping normally needs no password. If prompted, let the owner type it.
4. Tell the owner the version published and installed, or which step failed.

This applies to every change to the app, whoever makes it. Docs-only changes need neither ship nor install.

Exceptions:
- Only the main session ships, installs or launches Cala, after merging any parallel workers' or subagents' changes. Never open `build/Cala.app` directly: a second instance, killed afterwards, deletes the Dock autohide delay.
