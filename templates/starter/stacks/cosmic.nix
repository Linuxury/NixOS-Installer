# COSMIC desktop stack, imported by hosts/<HOST>/default.nix as
# ../../stacks/cosmic.nix. Enables the login screen, the desktop, PipeWire audio,
# Bluetooth and printing. Keep its import line in default.nix to use COSMIC;
# comment the line out to remove it, or swap in gnome.nix or kde.nix.
{ ... }:

{
  # Login screen (cosmic-greeter). The other stacks use gdm or sddm instead.
  #   services.displayManager.cosmic-greeter.enable  the greeter (off by default)
  services.displayManager.cosmic-greeter.enable = true;
  # COSMIC desktop environment.
  #   services.desktopManager.cosmic.enable            the desktop (set here)
  #   services.desktopManager.cosmic.xwayland.enable   Xwayland for X11 apps (on by default)
  #   environment.cosmic.excludePackages               COSMIC packages to leave out (none by default)
  services.desktopManager.cosmic.enable = true;

  # RealtimeKit: lets PipeWire request realtime scheduling for audio threads.
  #   security.rtkit.enable  the rtkit service (off by default)
  security.rtkit.enable = true;   # lets PipeWire run with realtime priority
  # PipeWire audio server, with the ALSA and PulseAudio interfaces apps use.
  #   services.pipewire.enable             the server (set here)
  #   services.pipewire.alsa.enable        ALSA applications (set here)
  #   services.pipewire.alsa.support32Bit  32-bit ALSA apps on 64-bit systems (off)
  #   services.pipewire.pulse.enable       PulseAudio clients (set here)
  #   services.pipewire.jack.enable        JACK clients, for pro audio (off)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Bluetooth (BlueZ).
  #   hardware.bluetooth.enable       the stack (set here)
  #   hardware.bluetooth.powerOnBoot  power the adapter on at boot (on by default)
  hardware.bluetooth.enable = true;
  # CUPS printing.
  #   services.printing.enable           the print server (set here)
  #   services.printing.cups-pdf.enable  virtual "pdf" printer that writes PDF files (off)
  services.printing.enable = true;
}
