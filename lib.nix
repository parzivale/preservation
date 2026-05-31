{ lib, ... }:

rec {
  # concatenates two paths
  # inserts a "/" in between if there is none, removes one if there are two
  concatTwoPaths =
    parent: child:
    with lib.strings;
    if hasSuffix "/" parent then
      if
        hasPrefix "/" child
      # "/parent/" "/child"
      then
        parent + (removePrefix "/" child)
      # "/parent/" "child"
      else
        parent + child
    else if
      hasPrefix "/" child
    # "/parent" "/child"
    then
      parent + child
    # "/parent" "child"
    else
      parent + "/" + child;

  # concatenates a list of paths using `concatTwoPaths`
  concatPaths = builtins.foldl' concatTwoPaths "";

  # get the parent directory of an absolute path
  parentDirectory =
    path:
    with lib.strings;
    assert "/" == (builtins.substring 0 1 path);
    let
      parts = splitString "/" (removeSuffix "/" path);
      len = builtins.length parts;
    in
    if len < 1 then "/" else concatPaths ([ "/" ] ++ (lib.lists.sublist 0 (len - 1) parts));

  # splits a path on "/", returning a list of non-empty path components
  parts =
    path:
    builtins.foldl' (acc: p: if builtins.isString p && p != "" then acc ++ [ p ] else acc) [ ] (
      builtins.split "/" path
    );

  # generates a list of path segments that are parents of the given path
  # e.g.: for "/foo/bar/baz" this yields [ "foo" "foo/bar" ]
  parentSegments =
    path:
    let
      includingPath = builtins.foldl' (
        acc: part: if acc == [ ] then [ part ] else ([ (concatTwoPaths (builtins.head acc) part) ] ++ acc)
      ) [ ] (parts path);
    in
    builtins.tail includingPath;

  # generates a list of unique path segments that are parents of a given list of paths
  missingIntermediatePaths =
    paths:
    let
      intermediates = builtins.foldl' (acc: path: acc ++ (parentSegments path)) [ ] paths;
    in
    lib.lists.unique (builtins.filter (path: !(builtins.elem path paths)) intermediates);

  # generates a list of attributes to be used in the `directories` option of the `userModule`
  mkIntermediateUserDirectories =
    defaults: files: prefix: directories:
    let
      partitions = builtins.partition (d: d.inInitrd) (files ++ directories);
      toPaths = map (
        d: if builtins.hasAttr "file" d then lib.removePrefix prefix d.file else d.directory
      );
      intermediateInitrdPaths = missingIntermediatePaths (toPaths partitions.right);
      intermediateRegularPaths = missingIntermediatePaths (toPaths partitions.wrong);
      initrdIntermediates = map (
        p: defaults // { inInitrd = true; directory = p; }
      ) intermediateInitrdPaths;
      regularIntermediates = map (
        p: defaults // { inInitrd = false; directory = p; }
      ) intermediateRegularPaths;
    in
    directories ++ initrdIntermediates ++ regularIntermediates;

  getUserDirectories = lib.mapAttrsToList (_: userConfig: userConfig.directories);
  getUserFiles = lib.mapAttrsToList (_: userConfig: userConfig.files);

  getAllDirectories =
    stateConfig:
    stateConfig.directories ++ (builtins.concatLists (getUserDirectories stateConfig.users));

  getAllFiles =
    stateConfig: stateConfig.files ++ (builtins.concatLists (getUserFiles stateConfig.users));

  getNonEmptyUserConfigs =
    forInitrd: stateConfig:
    let
      preservesAny =
        userConfig: lib.any (def: def.inInitrd == forInitrd) (userConfig.files ++ userConfig.directories);
      nonEmptyUsers = lib.filterAttrs (_: preservesAny) stateConfig.users;
    in
    lib.mapAttrsToList (_: userConfig: userConfig) nonEmptyUsers;

  onlyBindMounts =
    forInitrd: builtins.filter (conf: conf.how == "bindmount" && conf.inInitrd == forInitrd);
  onlySymLinks =
    forInitrd: builtins.filter (conf: conf.how == "symlink" && conf.inInitrd == forInitrd);
  onlyIntermediates =
    forInitrd: builtins.filter (conf: conf.how == "_intermediate" && conf.inInitrd == forInitrd);

  # returns all non-empty user configs regardless of inInitrd flag
  getAllNonEmptyUserConfigs =
    stateConfig:
    lib.mapAttrsToList (_: u: u) (
      lib.filterAttrs (_: u: (u.files ++ u.directories) != [ ]) stateConfig.users
    );

  # produces shell commands for all bind mounts to run in the initrd after mount-all.
  # doing everything here means bind mounts persist through switch_root, so all paths are
  # available from the very start of stage 2.
  mkFinitInitrdMountCmds =
    _preserveAt: stateConfig:
    let
      allDirectories = getAllDirectories stateConfig;
      allFiles = getAllFiles stateConfig;
      initrdDirectories = builtins.filter (d: d.how == "bindmount") allDirectories;
      initrdFiles = builtins.filter (f: f.how == "bindmount") allFiles;

      prefix = "/sysroot";

      dirCmds = lib.concatMap (
        dirConfig:
        let
          persistentPath = concatPaths [ prefix stateConfig.persistentStoragePath dirConfig.directory ];
          volatilePath = concatPaths [ prefix dirConfig.directory ];
        in
        [
          "mkdir -p ${persistentPath}"
          "mkdir -p ${volatilePath}"
          "mount --bind ${persistentPath} ${volatilePath}"
        ]
      ) initrdDirectories;

      fileCmds = lib.concatMap (
        fileConfig:
        let
          persistentPath = concatPaths [ prefix stateConfig.persistentStoragePath fileConfig.file ];
          volatilePath = concatPaths [ prefix fileConfig.file ];
        in
        [
          "mkdir -p ${parentDirectory persistentPath}"
          "mkdir -p ${parentDirectory volatilePath}"
          "touch ${persistentPath}"
          "touch ${volatilePath}"
          "mount --bind ${persistentPath} ${volatilePath}"
        ]
      ) initrdFiles;
    in
    dirCmds ++ fileCmds;

  # produces tmpfiles.d(5) text lines for inInitrd=false paths, for the regular (stage-2) system.
  # bootmisc processes these before any run [S] commands, so directories exist by the time
  # mkFinitRegularMountRuns bind-mounts them.
  mkFinitRegularTmpfilesRules =
    _preserveAt: stateConfig:
    let
      allDirectories = getAllDirectories stateConfig;
      allFiles = getAllFiles stateConfig;
      mountedDirectories = onlyBindMounts false allDirectories;
      intermediateDirectories = onlyIntermediates false allDirectories;
      mountedFiles = onlyBindMounts false allFiles;
      symlinkedDirectories = onlySymLinks false allDirectories;
      symlinkedFiles = onlySymLinks false allFiles;
      nonEmptyUserConfigs = getNonEmptyUserConfigs false stateConfig;

      mkDir = path: user: group: mode: "d ${path} ${mode} ${user} ${group} - -";
      mkFile = path: user: group: mode: "f ${path} ${mode} ${user} ${group} - -";
      mkSymlink = path: target: "L ${path} - - - - ${target}";

      mountedDirRules = lib.concatMap (
        dirConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath dirConfig.directory ];
          volatilePath = dirConfig.directory;
        in
        [
          (mkDir persistentPath dirConfig.user dirConfig.group dirConfig.mode)
          (mkDir volatilePath dirConfig.user dirConfig.group dirConfig.mode)
        ]
        ++ lib.optionals dirConfig.configureParent [
          (mkDir (parentDirectory persistentPath) dirConfig.parent.user dirConfig.parent.group dirConfig.parent.mode)
          (mkDir (parentDirectory volatilePath) dirConfig.parent.user dirConfig.parent.group dirConfig.parent.mode)
        ]
      ) mountedDirectories;

      intermediateDirRules = lib.concatMap (
        dirConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath dirConfig.directory ];
          volatilePath = dirConfig.directory;
        in
        [
          (mkDir persistentPath dirConfig.user dirConfig.group dirConfig.mode)
          (mkDir volatilePath dirConfig.user dirConfig.group dirConfig.mode)
        ]
      ) intermediateDirectories;

      intermediateHomeRules = map (
        userConfig:
        mkDir (concatPaths [ stateConfig.persistentStoragePath userConfig.home ]) userConfig.username userConfig.homeGroup userConfig.homeMode
      ) nonEmptyUserConfigs;

      # intermediate parent directories on the persistent side that aren't created by anything else
      # (the volatile side is handled by finix's own tmpfiles; user home dirs by intermediateHomeRules)
      handledPersistentPaths = map (u: lib.removePrefix "/" u.home) nonEmptyUserConfigs;
      allPersistentLeafPaths =
        (map (d: d.directory) (mountedDirectories ++ intermediateDirectories))
        ++ (map (f: f.file) mountedFiles);
      intermediatePersistentPaths = builtins.filter
        (p: !(builtins.elem p handledPersistentPaths))
        (missingIntermediatePaths allPersistentLeafPaths);
      intermediatePersistentRules = map (
        path: mkDir (concatPaths [ stateConfig.persistentStoragePath path ]) "root" "root" "0755"
      ) intermediatePersistentPaths;

      mountedFileRules = lib.concatMap (
        fileConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath fileConfig.file ];
          volatilePath = fileConfig.file;
        in
        [
          (mkFile persistentPath fileConfig.user fileConfig.group fileConfig.mode)
          (mkFile volatilePath fileConfig.user fileConfig.group fileConfig.mode)
        ]
        ++ lib.optionals fileConfig.configureParent [
          (mkDir (parentDirectory persistentPath) fileConfig.parent.user fileConfig.parent.group fileConfig.parent.mode)
          (mkDir (parentDirectory volatilePath) fileConfig.parent.user fileConfig.parent.group fileConfig.parent.mode)
        ]
      ) mountedFiles;

      symlinkedDirRules = lib.concatMap (
        dirConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath dirConfig.directory ];
          volatilePath = dirConfig.directory;
          target = concatPaths [ stateConfig.persistentStoragePath dirConfig.directory ];
        in
        [ (mkSymlink volatilePath target) ]
        ++ lib.optionals dirConfig.createLinkTarget [
          (mkDir persistentPath dirConfig.user dirConfig.group dirConfig.mode)
        ]
        ++ lib.optionals dirConfig.configureParent [
          (mkDir (parentDirectory persistentPath) dirConfig.parent.user dirConfig.parent.group dirConfig.parent.mode)
          (mkDir (parentDirectory volatilePath) dirConfig.parent.user dirConfig.parent.group dirConfig.parent.mode)
        ]
      ) symlinkedDirectories;

      symlinkedFileRules = lib.concatMap (
        fileConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath fileConfig.file ];
          volatilePath = fileConfig.file;
          target = concatPaths [ stateConfig.persistentStoragePath fileConfig.file ];
        in
        [ (mkSymlink volatilePath target) ]
        ++ lib.optionals fileConfig.createLinkTarget [
          (mkFile persistentPath fileConfig.user fileConfig.group fileConfig.mode)
        ]
        ++ lib.optionals fileConfig.configureParent [
          (mkDir (parentDirectory persistentPath) fileConfig.parent.user fileConfig.parent.group fileConfig.parent.mode)
          (mkDir (parentDirectory volatilePath) fileConfig.parent.user fileConfig.parent.group fileConfig.parent.mode)
        ]
      ) symlinkedFiles;
    in
    mountedDirRules
    ++ intermediateDirRules
    ++ intermediateHomeRules
    ++ intermediatePersistentRules
    ++ symlinkedDirRules
    ++ mountedFileRules
    ++ symlinkedFileRules;

  # produces finit `run [S]` lines for bind-mounting inInitrd=false paths in the regular (stage-2) system.
  # runs in the S phase; mkdir -p ensures directories exist regardless of bootmisc timing.
  mkFinitRegularMountRuns =
    _preserveAt: stateConfig:
    let
      allDirectories = getAllDirectories stateConfig;
      allFiles = getAllFiles stateConfig;
      mountedDirectories = onlyBindMounts false allDirectories;
      mountedFiles = onlyBindMounts false allFiles;

      dirRuns = lib.concatMap (
        dirConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath dirConfig.directory ];
          volatilePath = dirConfig.directory;
        in
        [
          "run [S] mkdir -p ${persistentPath}"
          "run [S] mkdir -p ${volatilePath}"
          "run [S] mount --bind ${persistentPath} ${volatilePath}"
        ]
      ) mountedDirectories;

      fileRuns = lib.concatMap (
        fileConfig:
        let
          persistentPath = concatPaths [ stateConfig.persistentStoragePath fileConfig.file ];
          volatilePath = fileConfig.file;
        in
        [
          "run [S] mkdir -p ${parentDirectory persistentPath}"
          "run [S] mkdir -p ${parentDirectory volatilePath}"
          "run [S] touch ${persistentPath}"
          "run [S] touch ${volatilePath}"
          "run [S] mount --bind ${persistentPath} ${volatilePath}"
        ]
      ) mountedFiles;
    in
    dirRuns ++ fileRuns;
}
