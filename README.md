# How does this tool work?
It simply automates the installation of Snap and Flathub and enables them so they are visible in the relevant stores of the various desktop environments. In the case of Flatpak, it automatically configures everything according to the official guide on the website, avoiding the need to copy and paste individual commands into the terminal. After the script is executed, both Snap and Flathub are also accessible directly through the software store of your Linux distribution.

# Quick perks
If you have not installed gnome software or kde discover, you can choose to install it using either `--gnome-software` or `--kde-discover`. You can also skip the automatic update of system packages by typing `--skip-update`.

# What's missing and what's coming up in the "undefined" future?
Currently, the script is limited to Linux distros with the apt package manager (such as Debian, Ubuntu, and their derivatives). In the near, undefined future, I will probably also implement support for distros such as Arch or Fedora.
