#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re

root = Path("Sources/Cala")
inventory_path = Path("build/settings-audit/inventory.md")

# The Settings audit classifies each serialized key by its UI or internal owner.
settings = {
    "Settings/GeneralSettings.swift": "language theme",
    "Settings/ModuleSettings.swift": "barEnabled trayEnabled zonesEnabled switcherEnabled switcherReplaceCmdTab",
    "Settings/BarSettings.swift": """
        autoHide attentionEdgeCue iconSize previewDelay previewWidth alignments barOpacity hideNativeDock restoreDockOnQuit
        hideMenuBar restoreMenuBarOnQuit menuBarHiddenIcons
    """,
    "Settings/TraySettings.swift": "trayLayout trayOrder monitorBarMetric diskFolders restartAdvice",
    "Settings/UsageSettings.swift": """
        usageEnabled usageClaudeEnabled usageCodexEnabled usageClaudeConfigDir usageCodexHome
        usageClaudeStatusLine usageAlertsEnabled usageAlertThreshold
    """,
    "Settings/SupportSettings.swift": "crashReports relaunchOnCrash updateChecks updateAutoInstall",
    "Zones/ZonesSettingsPane.swift": "zonesActivation zonesGap zonesLayoutStrip zonesStatusItem",
    "CalendarViews.swift": "calendarEnabled calendarJoinEnabled calendarDays calendarExcludedIDs",
    "MailViews.swift": "mailLoadsRemoteImages",
}
other_ui = {
    "Model.swift": "pinned order",
    "Zones/ZoneEditor.swift": "zonesEditorGrid",
}
internal = {
    "ModuleRegistry.swift": "modulesChosen",
    "TrayLayout.swift": "diskEnabled monitorEnabled",
    "DockControl.swift": "dockBackupSaved dockOverridePending dockBackupAutohide dockBackupDelay dockBackupNoBouncingSaved dockBackupNoBouncing",
    "MenuBarControl.swift": "menuBarBackupSaved menuBarBackupOption menuBarBackupHide menuBarBackupFullscreen menuBarIconBackupV2",
}

def fail(message):
    raise SystemExit(f"FAIL settings audit: {message}")

def keys_in(owners):
    keys = set()
    for file, names in owners.items():
        source = (root / file).read_text()
        for key in names.split():
            if key in keys:
                fail(f"{key} is listed more than once")
            prefix = r"!" if file == "TrayLayout.swift" else r"\bconfig\."
            if not re.search(rf"{prefix}{key}\b", source):
                fail(f"{key} has no config reference in {file}")
            keys.add(key)
    return keys

direct = keys_in(settings)
external = keys_in(other_ui)
hidden = keys_in(internal)
all_keys = direct | external | hidden
coding_block = (root / "Config.swift").read_text().split("enum CodingKeys", 1)[1].split("}", 1)[0]
serialized = set(re.findall(r"\b\w+\b", coding_block.split("{", 1)[1])) - {"case"}
if (len(direct), len(external), len(hidden), len(all_keys)) != (45, 3, 14, 62):
    fail("expected 45 Settings controls, 3 controls elsewhere, and 14 internal keys")
if all_keys != serialized:
    fail(f"CodingKeys differ from audited keys: {sorted(all_keys ^ serialized)}")

if inventory_path.is_file():
    index = inventory_path.read_text().split("## Índice de Config.swift", 1)[1].split("## Capturas", 1)[0]
    sections = re.split(r"^### .*\n", index, flags=re.MULTILINE)[1:]
    inventoried = [set(re.findall(r"^\| `(\w+)` \|", section, flags=re.MULTILINE)) for section in sections]
    if inventoried != [direct, external, hidden]:
        fail("inventory.md classifications differ from their current owners")

for file in settings:
    source = (root / file).read_text()
    for key in external | hidden:
        if re.search(rf"\bconfig\.{key}\b", source):
            fail(f"{file} directly references {key}, which belongs outside Settings")

print("PASS settings audit: 62/62 keys (45 Settings, 3 other UI, 14 internal)")
PY

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -module-cache-path "$out/modules" -o "$out/cala-settings-tray" \
    Sources/Cala/TrayOrder.swift Checks/SettingsTray/main.swift
"$out/cala-settings-tray"
