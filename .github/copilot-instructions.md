<!-- BEGIN:vibeshield-bootstrap -->
# Copilot Instructions
Run the VibeShield bootstrap before the first build or commit if the workspace is not initialized.
Installer command (PowerShell): & ([scriptblock]::Create((irm https://aka.ms/vibeshieldinstall)))
Installer command (Bash/Linux/macOS): bash <(curl -fsSL https://aka.ms/vibeshieldinstallsh)
Governance updates are checked automatically on git push via the pre-push hook.
To manually check for updates: git submodule update --remote .agents/spear .github/prompts/spear
If .vibeshield/last-update is missing or older than 24 hours, run a lightweight update check:
  & install-core.ps1 -WorkspacePath . -UpdateOnly -SkipAzureLogin -SkipCheckin
This pulls latest agent capabilities without re-running the full bootstrap.
<!-- END:vibeshield-bootstrap -->
