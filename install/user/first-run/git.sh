# Unattended installs and upgrades can carry a git identity already.
if [[ -z $(git config --global user.name) || -z $(git config --global user.email) ]]; then
  omarchy-notification-send -u critical -g  "Setup Git" $'Set your name and email for commits.\nSign in to GitHub.' \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-setup-git
fi
