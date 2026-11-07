{
  description = "NixOS configuration for @HOST@";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/@CHANNEL@";

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.@HOST@ = nixpkgs.lib.nixosSystem {
      modules = [ ./hosts/@HOST@ ];
    };
  };
}
