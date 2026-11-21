# KDE Plasma 6 desktop stack, imported by hosts/<HOST>/default.nix as
# ../../stacks/kde.nix. Enables the login screen, the desktop, PipeWire audio,
# Bluetooth and printing. Keep its import line in default.nix to use Plasma;
# comment the line out to remove it, or swap in gnome.nix or cosmic.nix.
{ ... }:

{
  # Login screen (SDDM). The other stacks use cosmic-greeter or gdm.
  #   services.displayManager.sddm.enable                 the login screen (set here)
  #   services.displayManager.sddm.wayland.enable         run the greeter on Wayland (set here; experimental)
  #   services.displayManager.sddm.wayland.compositor     compositor for that session (default "weston")
  #   services.displayManager.sddm.enableHidpi            automatic HiDPI mode (on by default)
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  # KDE Plasma 6 desktop.
  #   services.desktopManager.plasma6.enable                 the desktop (set here)
  #   services.desktopManager.plasma6.enableQt5Integration   Qt 5 theming (on by default; off for pure Qt 6)
  #   environment.plasma6.excludePackages                    Plasma packages to leave out (none by default)
  services.desktopManager.plasma6.enable = true;

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
