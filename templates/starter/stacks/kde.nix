# KDE Plasma 6 desktop with sound, Bluetooth and printing.
{ ... }:

{
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  security.rtkit.enable = true;   # lets PipeWire run with realtime priority
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.printing.enable = true;
}
