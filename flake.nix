{
  description = "NixOS installer: a guided wizard that partitions, formats and installs from a live ISO";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      installer = pkgs.writeShellApplication {
        name = "nixos-installer";
        runtimeInputs = with pkgs; [
          gum jq qrencode smartmontools openssh util-linux gawk iputils git
          parted dosfstools btrfs-progs e2fsprogs xfsprogs cryptsetup
        ];
        # jq programs in single quotes, colours in printf formats, literal \n for Nix: all intended
        excludeShellChecks = [ "SC2016" "SC2028" "SC2059" ];
        runtimeEnv.INSTALLER_TEMPLATES = "${./templates}";
        text = builtins.readFile ./install.sh;
      };

      demo = pkgs.writeShellApplication {
        name = "install-demo";
        text = ''exec ${installer}/bin/nixos-installer --demo "$@"'';
        meta.description = "Run the installer wizard without writing anything";
      };
    in
    {
      packages.${system}.default = installer;

      apps.${system} = {
        install      = { type = "app"; program = "${installer}/bin/nixos-installer"; };
        install-demo = { type = "app"; program = "${demo}/bin/install-demo"; };
        default      = self.apps.${system}.install;
      };
    };
}
