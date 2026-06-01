pkgs: modules: let
  inherit (pkgs) lib;
  preservationLib = import ../lib.nix {inherit lib;};
in {
  name = "preservation-finit";

  nodes.machine = {pkgs, ...}: {
    imports = [../module.nix] ++ modules;

    preservation = {
      enable = true;
      preserveAt."/state" = {
        directories = [
          "/var/lib/someservice"
          "/var/log"
        ];
        files = [
          {
            file = "/etc/machine-id";
          }
        ];
        users = {
          alice.directories = [".rabbit_hole"];
        };
      };
    };

    users.users.alice = {
      isNormalUser = true;
    };

    fileSystems."/state" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = ["mode=0755"];
      neededForBoot = true;
    };
  };

  testScript = {nodes, ...}: let
    allFiles = lib.flatten (
      lib.mapAttrsToList (_: preservationLib.getAllFiles) nodes.machine.config.preservation.preserveAt
    );
    allDirs = lib.flatten (
      lib.mapAttrsToList (
        _: preservationLib.getAllDirectories
      )
      nodes.machine.config.preservation.preserveAt
    );
    allJSON = builtins.toJSON (allDirs ++ allFiles);
  in
    /*
    python
    */
    ''
      import json

      all_paths = json.loads('${allJSON}')

      def check_mountpoint(path):
        result = machine.succeed("cat /proc/mounts")
        t.assertIn(path, result, f"{path} not in mounts")

      machine.start()
      machine.wait_for_console_text("entering runlevel 2")

      with subtest("Preserved directories are bind-mounted"):
        check_mountpoint("/var/lib/someservice")
        check_mountpoint("/var/log")

      with subtest("Machine ID is bind-mounted"):
        check_mountpoint("/etc/machine-id")

      with subtest("Preserved user directory is bind-mounted"):
        check_mountpoint("/home/alice/.rabbit_hole")

      machine.shutdown()
    '';
}
