{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.preservation;

  inherit (import ./lib.nix { inherit lib; })
    mkFinitInitrdMountCmds
    ;

  allCmds = lib.flatten (lib.mapAttrsToList mkFinitInitrdMountCmds cfg.preserveAt);
  script = pkgs.writeScript "preservation-initrd" ''
    #!/bin/sh
    ${lib.concatStringsSep "\n" allCmds}
  '';
  conditions = map (n: "task/${n}/success")
    (lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "mount-" n) config.boot.initrd.finit.tasks));
  conditionString = lib.optionalString (conditions != [ ]) " <${lib.concatStringsSep "," conditions}>";
in
{
  imports = [
    ./options.nix
  ];

  config = lib.mkIf (cfg.enable && allCmds != [ ]) {
    boot.initrd.contents = [
      {
        target = "/usr/local/bin/preservation";
        source = script;
      }
      {
        target = "/etc/finit.d/preservation.conf";
        source = pkgs.writeText "preservation-finit-initrd.conf" ''
          run [S] name:preservation${conditionString} preservation
        '';
      }
    ];
  };
}
