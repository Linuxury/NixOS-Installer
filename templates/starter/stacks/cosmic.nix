# COSMIC desktop with sound, Bluetooth and printing.
{ ... }:

{
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

  security.rtkit.enable = true;   # lets PipeWire run with realtime priority
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.printing.enable = true;
}
