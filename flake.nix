# ===========================================================================
# flake.nix — packages and runnable apps for the installer wizard
#
# Packages the wizard (install.sh) as a self-contained command that carries
# its own tools and templates, so it runs from any NixOS live ISO.
# Outputs (x86_64-linux only):
#   packages.default  the nixos-installer command
#   apps.install      real install (partitions and writes disks; needs root)
#   apps.install-demo same wizard with --demo: writes nothing
#   apps.default      alias of apps.install
# Run:
#   nix run .#install-demo                       try the wizard safely
#   nix run .#install-demo -- --fake-disks 3-mixed   with simulated disks
#   sudo nix run .                               real install
# Tests: tests/smoke.sh and tests/starter.sh use apps.install-demo.
# ===========================================================================
{
  description = "NixOS installer: a guided wizard that partitions, formats and installs from a live ISO";

  # nixpkgs supplies the tools below and writeShellApplication.
  # Alternative: a release branch (e.g. nixos-25.05) for a fixed package set.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The wizard. writeShellApplication wraps a script with a fixed PATH and
      # runs shellcheck on it at build time.
      #   name                command name in bin/
      #   runtimeInputs       the only tools on PATH when it runs:
      #                         gum, qrencode            terminal UI, QR codes
      #                         jq, gawk                 JSON and text processing
      #                         smartmontools            drive health (smartctl)
      #                         openssh, git, iputils    keys, config clone, network check
      #                         util-linux, parted       disk listing and partitioning
      #                         dosfstools, btrfs-progs, e2fsprogs, xfsprogs
      #                                                  mkfs for vfat, btrfs, ext4, xfs
      #                         cryptsetup               LUKS encryption
      #   excludeShellChecks  shellcheck codes switched off (below)
      #   runtimeEnv          environment variables exported by the wrapper
      #   text                the script body (install.sh read as a string)
      # Other options: bashOptions (default errexit, nounset, pipefail),
      # checkPhase (replace the shellcheck step), meta.
      installer = pkgs.writeShellApplication {
        name = "nixos-installer";
        runtimeInputs = with pkgs; [
          gum jq qrencode smartmontools openssh util-linux gawk iputils git
          parted dosfstools btrfs-progs e2fsprogs xfsprogs cryptsetup
        ];
        # SC2016 jq programs in single quotes, SC2028 literal \n in echo,
        # SC2059 colour codes inside printf formats: all intended.
        excludeShellChecks = [ "SC2016" "SC2028" "SC2059" ];
        # Store path of templates/; install.sh reads it as INSTALLER_TEMPLATES.
        runtimeEnv.INSTALLER_TEMPLATES = "${./templates}";
        text = builtins.readFile ./install.sh;
      };

      # Same wizard forced into --demo: nothing is partitioned or written.
      # Extra arguments pass through, e.g. install-demo --fake-disks windows.
      demo = pkgs.writeShellApplication {
        name = "install-demo";
        text = ''exec ${installer}/bin/nixos-installer --demo "$@"'';
        meta.description = "Run the installer wizard without writing anything";
      };
    in
    {
      packages.${system}.default = installer;

      # Apps are what `nix run .#<name>` starts; `nix run .` uses default.
      apps.${system} = {
        install      = { type = "app"; program = "${installer}/bin/nixos-installer"; };
        install-demo = { type = "app"; program = "${demo}/bin/install-demo"; };
        default      = self.apps.${system}.install;
      };
    };
}
