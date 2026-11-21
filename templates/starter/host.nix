# Host configuration for @HOST@: the file hosts/@HOST@/default.nix, which flake.nix
# loads. The installer writes it once. Edit it, then rebuild with
#   nixos-rebuild switch --flake .#@HOST@
# Settings are grouped below by topic. Each option is listed with what it does.
#
# Module arguments: pkgs is the nixpkgs package set, used for environment.systemPackages.
{ pkgs, ... }:

{
  # Modules this host imports. Relative paths are from hosts/@HOST@/.
  imports = [
    ./disk.nix                     # boot loader, encryption, filesystems, swap
    ./hardware-configuration.nix   # kernel modules found by nixos-generate-config
    ./hardware.nix                 # CPU, GPU and laptop settings found by the installer

    # Desktop: keep one of these three lines. Each stack enables its own display
    # manager and desktop, and ../../stacks/ is the repo's stacks/ folder. The
    # installer comments out the two it did not choose; comment all three out for
    # a text-only system.
    @GNOME@../../stacks/gnome.nix
    @KDE@../../stacks/kde.nix
    @COSMIC@../../stacks/cosmic.nix
  ];

  # Machine name and network. NetworkManager handles wired and Wi-Fi connections.
  #   networking.hostName              the machine name (set by the installer)
  #   networking.networkmanager.enable use NetworkManager for addresses and connections (set here)
  #                                    instead of NetworkManager, one of these:
  #                                    networking.useNetworkd (systemd-networkd),
  #                                    networking.wireless.enable (wpa_supplicant only)
  networking.hostName = "@HOST@";
  networking.networkmanager.enable = true;

  # Time zone, language and keyboard.
  #   time.timeZone                  IANA zone name, e.g. America/New_York (set by the installer)
  #   i18n.defaultLocale             language, date and time format, sort order (default en_US.UTF-8)
  #                                  i18n.extraLocaleSettings sets single LC_* categories instead
  #   console.keyMap                 keymap for the text console
  #                                  console.useXkbConfig = true reuses the X keyboard settings
  #   services.xserver.xkb.layout    X keyboard layout (default "us")
  #                                  also .variant (default "") and .options (default "terminate:ctrl_alt_bksp")
  time.timeZone = "@TZ@";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "@KEYMAP@";
  services.xserver.xkb.layout = "@XKB@";

  # The login account the installer created. Exactly one of isNormalUser and
  # isSystemUser must be true; this account is a normal user.
  #   isNormalUser  home directory and interactive login
  #   extraGroups   supplementary groups; wheel is the administrator group,
  #                 networkmanager lets the user change network connections
  #   packages      packages for this user only (environment.systemPackages is system-wide)
  users.users.@USER@ = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];   # wheel = administrator (sudo)
  };

  # Remote login. services.openssh.enable runs the OpenSSH daemon (sshd) when true.
  # The installer sets it from its SSH choice.
  services.openssh.enable = @SSH@;

  # Linux kernel. The installer either writes boot.kernelPackages (latest or zen)
  # or leaves a commented-out line, which keeps the default kernel.
  #   boot.kernelPackages  pkgs.linuxPackages (default), pkgs.linuxPackages_latest,
  #                        or pkgs.linuxPackages_zen
@KERNEL@

  # Unfree software (Steam, Discord, Spotify, the NVIDIA driver, ...)
  #   nixpkgs.config.allowUnfree          allow every unfree package (default false)
  #   nixpkgs.config.allowUnfreePackages  allow only the named ones (default [ ]);
  #                                       lists from several modules are merged
  nixpkgs.config.allowUnfree = @UNFREE@;

  # Packages installed system-wide, for every user: git and vim, plus any extra
  # packages picked in the installer (appended after vim). Per-user packages go in
  # users.users.<name>.packages.
  environment.systemPackages = with pkgs; [ git vim@EXTRA_PKGS@ ];

  # Nix settings. "nix-command" and "flakes" enable the nix CLI and the flake support
  # that nixos-rebuild --flake needs. Other features exist, e.g. "ca-derivations".
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Release this machine was first installed with (YY.MM). It keeps service data
  # formats compatible across upgrades, so leave it unchanged when upgrading NixOS.
  system.stateVersion = "@STATEVERSION@";
}
