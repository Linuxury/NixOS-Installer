# Flake for the NixOS host @HOST@, written by the installer from its starter template.
# nixos-rebuild --flake .#@HOST@ reads this file, locks the inputs in flake.lock,
# and builds nixosConfigurations.@HOST@. The installer fills in @HOST@ and @CHANNEL@.
{
  # Free-text label for the flake, shown by nix flake metadata.
  description = "NixOS configuration for @HOST@";

  # The only input: the nixpkgs branch the installer chose (default nixos-unstable).
  # The exact commit is pinned in flake.lock; `nix flake update` moves it to the newest one.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/@CHANNEL@";

  # Takes the inputs and returns the outputs. Only nixosConfigurations is defined.
  outputs = { nixpkgs, ... }: {
    # The host, built by nixpkgs.lib.nixosSystem (defined in nixos/lib/eval-config.nix).
    #   modules      NixOS modules to combine; here only the host directory
    #   system       not set: defaults to builtins.currentSystem, the system evaluating the flake
    #   specialArgs  extra arguments passed to every module (e.g. inputs); not used here
    nixosConfigurations.@HOST@ = nixpkgs.lib.nixosSystem {
      # ./hosts/@HOST@ is a directory, so Nix loads its default.nix.
      modules = [ ./hosts/@HOST@ ];
    };
  };
}
