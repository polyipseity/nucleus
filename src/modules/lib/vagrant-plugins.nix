# src/modules/lib/vagrant-plugins.nix: hash-pinned Vagrant provider plugins.
#
# nixpkgs bundles the libvirt provider into Vagrant on Linux and no provider on
# Darwin, so QEMU and UTM are built here from hash-pinned GitHub release tags and
# registered through VAGRANT_HOME. Building from source keeps apply offline:
# rubygems.org is unreachable from some build networks, and the fetch hash is
# what pins the version.
#
# Windows installs the HashiCorp MSI, which ships its own Ruby and plugins.
#
# Pure function, not a module: call with `pkgs` plus the host name.
{ lib, pkgs }:
let
  inherit (pkgs)
    fetchFromGitHub
    libarchive
    qemu
    ruby_3_4
    stdenvNoCC
    vagrant
    ;

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # Registration manifest. StateFile reads $VAGRANT_HOME/plugins.json and takes
  # its "installed" object as the plugin registry, with ruby_version and
  # vagrant_version deciding whether a registered gem is loadable. Both come
  # from the pinned nixpkgs versions, not from whatever is on PATH.
  registryEntries =
    lib.mapAttrs
      (_: plugin: {
        ruby_version = ruby_3_4.version;
        vagrant_version = vagrant.version;
        gem_version = plugin.version;
        # Bundler resolves this exact version from GEM_PATH during init.
        installed_gem_version = plugin.version;
        require = "";
        sources = [ ];
      })
      (
        lib.listToAttrs (
          map (p: {
            name = p.passthru.pluginName;
            value = p;
          }) plugins
        )
      );

  plugin =
    {
      name,
      owner,
      repo,
      rev,
      hash,
      version,
      patches ? [ ],
    }:
    stdenvNoCC.mkDerivation {
      pname = name;
      inherit version patches;
      src = fetchFromGitHub {
        inherit
          owner
          repo
          rev
          hash
          ;
      };
      nativeBuildInputs = [ ruby_3_4 ];
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        gem build ${name}.gemspec -o ${name}.gem
        # The built gem is kept so `vagrant plugin install` can consume it from
        # the store: Vagrant writes its own Bundler solution file only when it
        # performs the install, so a hand-written plugins.json is not enough.
        mkdir -p "$out/gem"
        cp ${name}.gem "$out/gem/${name}-${version}.gem"
        gem install --local --install-dir "$out/gems" --ignore-dependencies --no-document ${name}.gem
        runHook postInstall
      '';
      passthru.pluginName = name;
      meta = {
        description = "Vagrant ${name} provider";
        homepage = "https://rubygems.org/gems/${name}";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      };
    };

  qemuPlugin = plugin {
    name = "vagrant-qemu";
    owner = "ppggff";
    repo = "vagrant-qemu";
    rev = "v0.6.3";
    hash = "sha256-h2/wUqWWrrnf56u827vqbCeZFF/yN4t8qv1Caj8PMgc=";
    version = "0.6.3";
  };

  # WHY the patch: the gemspec collects its file list from `git ls-files`, which
  # returns nothing in a release tarball and would build an empty gem.
  utmPlugin = plugin {
    name = "vagrant_utm";
    owner = "naveenrajm7";
    repo = "vagrant_utm";
    rev = "v0.1.6";
    hash = "sha256-G7RaVRGQ2z1grAwl3ar/g2eJ44Cvq6erhs87X4OMk0o=";
    version = "0.1.6";
    patches = [ ./vagrant-utm-gemspec.patch ];
  };

  # UTM is a macOS application, so its provider has no meaning on NixOS, where
  # the libvirt provider is already inside pkgs.vagrant.
  plugins =
    if isDarwin then
      [
        qemuPlugin
        utmPlugin
      ]
    else
      [ qemuPlugin ];

  pluginGemPaths = map (p: "${p}/gems") plugins;

  # Vagrant's own gems come last so a plugin can never shadow the runtime.
  fullGemPaths = pluginGemPaths ++ [
    "${vagrant}/lib/ruby/gems/${ruby_3_4.version.libDir}"
    "${vagrant.passthru.deps}/lib/ruby/gems/${ruby_3_4.version.libDir}"
  ];

  # bsdtar extracts downloaded boxes; qemu-img and virt-sysprep back
  # `vagrant package`, matching the path additions nixpkgs bakes into its wrapper.
  runtimeInputs = lib.makeSearchPath "bin" (
    map lib.getBin [
      libarchive
      qemu
    ]
  );
  # A plain script, not writeShellScriptBin, because Vagrant shells out to curl
  # and ssh from the ambient PATH that writeShellScriptBin would replace.
  #
  # WHY Ruby is invoked directly: the nixpkgs wrapper exports GEM_PATH itself, so
  # a GEM_PATH set outside it is discarded. Owning GEM_PATH is what puts the
  # store gems in front of Vagrant's Bundler.
  wrapperBody = ''
    export GEM_PATH=${lib.escapeShellArg (builtins.concatStringsSep ":" fullGemPaths)}
    export PATH=${lib.escapeShellArg "${runtimeInputs}:"}$PATH
    exec ${vagrant.passthru.ruby}/bin/ruby \
      ${vagrant}/lib/ruby/gems/${ruby_3_4.version.libDir}/gems/vagrant-${vagrant.version}/bin/vagrant "$@"
  '';

  wrapperScript = pkgs.writeShellScript "vagrant-wrapper" wrapperBody;

  # The deployed binary. One package, because a second `vagrant` on PATH would
  # collide in the managed package environment.
  package = pkgs.runCommand "vagrant-with-plugins" { } ''
    mkdir -p "$out/bin"
    cp ${wrapperScript} "$out/bin/vagrant"
    chmod +x "$out/bin/vagrant"
  '';

in
{
  inherit plugins package wrapperBody;

  gemPaths = fullGemPaths;

  registry = {
    version = "1";
    installed = registryEntries;
  };

  # Store paths of the installed plugin gem directories, in registry order.
  gemFiles = pluginGemPaths;

  desired = map (p: {
    inherit (p.passthru) pluginName;
    inherit (p) version;
  }) plugins;
}
