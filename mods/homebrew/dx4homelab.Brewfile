# dx4homelab Homebrew packages — the workstation's manually-installed CLI tools
# (brew leaves --installed-on-request) plus fonts/casks.
#
# Baked into the dx image at /usr/share/ublue-os/homebrew/dx4homelab.Brewfile via
# customize-build.py EXTRA_FILE_COPIES. Install on a deployed instance with:
#     ujust install-dx4homelab-brews
#
# To refresh this list from a configured workstation:
#     brew bundle dump --file=- | grep -E '^(tap|brew|cask) ' > mods/homebrew/dx4homelab.Brewfile
# (brew bundle dump also emits vscode/flatpak/mas lines — those are not brew
# packages, so they are intentionally excluded here.)

brew "ant"
brew "arp-scan"
brew "aws-cdk"
brew "awscli"
brew "b3sum"
brew "cosign"
brew "gh"
brew "go"
brew "helm"
brew "k9s"
brew "kubernetes-cli"
brew "kubeseal"
brew "node@22"
brew "openjdk@17"
brew "openjdk@21"
brew "pandoc"
brew "phoronix-test-suite"
brew "python@3.12"
brew "python@3.9"
brew "stress-ng"
brew "wmctrl"

cask "font-hack-nerd-font"
