# tests/modules/vagrant-plugins-tests.nix: Vagrant provider plugin wiring.
#
# Verifies the plugin registry handed to activation, and that the deployed
# wrapper can actually see the plugin gems:
#   • every built plugin has a registry entry keyed by its gem name
#   • each entry pins the gem version the derivation was built at
#   • ruby_version matches the pinned Ruby, so a Ruby bump cannot leave a
#     registry that Vagrant silently refuses to load
#   • the UTM provider is macOS-only, matching the macOS-only UTM application
#   • the wrapper exports a GEM_PATH naming every plugin gem directory
#
# Run with: nix-instantiate --eval --strict tests/modules/vagrant-plugins-tests.nix

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  pkgs = import <nixpkgs> {
    system = builtins.currentSystem;
    # WHY: pkgs.vagrant is unfree, and the registry has to name the exact
    # Ruby version it was built against.
    config.allowUnfree = true;
  };

  plugins = import ../../src/modules/lib/vagrant-plugins.nix { inherit lib pkgs; };

  registry = plugins.registry.installed;
  pluginNames = map (p: p.passthru.pluginName) plugins.plugins;

  test_registry_covers_every_plugin = assert' (lib.all (
    name: builtins.hasAttr name registry
  ) pluginNames) "every built Vagrant plugin needs a registry entry";

  test_registry_pins_built_version = assert' (lib.all (
    p: (registry.${p.passthru.pluginName}.gem_version) == p.version
  ) plugins.plugins) "each registry entry must pin the version its gem was built at";

  # WHY: installed_gem_version is the requirement Bundler resolves during init,
  # so an entry without it degrades to "> 0" and stops pinning anything.
  test_registry_pins_installed_version = assert' (lib.all (
    name: registry.${name}.installed_gem_version == registry.${name}.gem_version
  ) pluginNames) "each registry entry must pin installed_gem_version to the built gem version";

  test_registry_matches_pinned_ruby = assert' (lib.all (
    name: registry.${name}.ruby_version == pkgs.ruby_3_4.version
  ) pluginNames) "each registry entry must name the Ruby version the gems were built against";

  test_registry_matches_pinned_vagrant = assert' (lib.all (
    name: registry.${name}.vagrant_version == pkgs.vagrant.version
  ) pluginNames) "each registry entry must name the Vagrant version the gems were built against";

  test_qemu_provider_present = assert' (builtins.hasAttr "vagrant-qemu" registry) "the QEMU provider is required on both POSIX hosts";

  test_utm_provider_is_darwin_only = assert' (
    if pkgs.stdenv.hostPlatform.isDarwin then
      builtins.hasAttr "vagrant_utm" registry
    else
      !(builtins.hasAttr "vagrant_utm" registry)
  ) "the UTM provider belongs to macOS only, since UTM is a macOS application";

  # WHY the wrapper body is asserted as text: GEM_PATH is the only channel
  # through which Vagrant's Bundler sees the store gems, and reading the built
  # file would make this test depend on a build.
  wrapperText = plugins.wrapperBody;

  test_wrapper_exports_every_plugin_gem_path = assert' (lib.all
    (p: lib.hasInfix "${p.passthru.pluginName}-${p.version}/gems" wrapperText)
    plugins.plugins
  ) "the deployed wrapper must export a GEM_PATH containing every plugin gem directory";

  test_wrapper_keeps_vagrant_gem_path = assert' (lib.hasInfix "lib/ruby/gems/${pkgs.ruby_3_4.version.libDir}" wrapperText) "the wrapper must keep Vagrant's own gem path alongside the plugin gems";

  # WHY: the nixpkgs wrapper exports GEM_PATH itself, so a wrapper that execs it
  # loses the plugin gems no matter what the caller sets.
  test_wrapper_runs_ruby_directly = assert' (lib.hasInfix "${pkgs.ruby_3_4.version.libDir}/gems/vagrant-${pkgs.vagrant.version}/bin/vagrant" wrapperText) "the wrapper must run Vagrant's Ruby entry point so its own GEM_PATH export wins";

  allTests = [
    test_registry_covers_every_plugin
    test_registry_pins_built_version
    test_registry_pins_installed_version
    test_registry_matches_pinned_ruby
    test_registry_matches_pinned_vagrant
    test_qemu_provider_present
    test_utm_provider_is_darwin_only
    test_wrapper_exports_every_plugin_gem_path
    test_wrapper_keeps_vagrant_gem_path
    test_wrapper_runs_ruby_directly
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  plugins = pluginNames;
  message = "All ${builtins.toString (builtins.length allTests)} Vagrant plugin tests passed for ${builtins.toString (builtins.length pluginNames)} providers";
}
