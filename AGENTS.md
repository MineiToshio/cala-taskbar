# Agent rules for Cala

## Install every change

Every change to the app ends installed, with no need to ask:

1. Build passes and the `scripts/check-*.sh` checks pass.
2. Commit the change.
3. Run `./install.sh` from the repo root. It builds, publishes `/Applications/Cala.app` and relaunches it. It asks for sudo, so run it in the owner's Terminal panel (never type the password yourself) and wait until it finishes.
4. Tell the owner the new build is installed, or what failed.

This applies to every change to the app, whoever makes it. Docs-only changes do not need an install.

Exceptions:
- Parallel workers or subagents never install or launch Cala themselves; only the main session installs, once their work is merged. Never open `build/Cala.app` directly: a second instance, killed afterwards, deletes the Dock autohide delay.
