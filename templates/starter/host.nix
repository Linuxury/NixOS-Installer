# Host configuration for @HOST@, written by the NixOS installer. Edit freely.
{ pkgs, ... }:

{
  imports = [
    ./disk.nix                     # boot loader, encryption, filesystems, swap
    ./hardware-configuration.nix   # kernel modules found by nixos-generate-config
    ./hardware.nix                 # CPU, GPU and laptop settings found by the installer

    # Desktop: keep exactly one line (they conflict), or none for a text-only system.
    @GNOME@../../stacks/gnome.nix
    @KDE@../../stacks/kde.nix
    @COSMIC@../../stacks/cosmic.nix
  ];

  networking.hostName = "@HOST@";
  networking.networkmanager.enable = true;

  time.timeZone = "@TZ@";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "@KEYMAP@";
  services.xserver.xkb.layout = "@XKB@";

  users.users.@USER@ = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];   # wheel = administrator (sudo)
  };

  services.openssh.enable = @SSH@;

  environment.systemPackages = with pkgs; [ git vim@BROWSER_PKG@ ];
@BROWSER_PROGRAM@
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "@STATEVERSION@";
}
