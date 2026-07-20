# modules/lib/apple-sdk-tools.nix — Authoritative xcrun shim-to-nixpkgs mapping.
#
# Every xcrun shim in /usr/bin/ gets an explicit entry.  Non-null = provisioned
# (symlinked into the enhanced SDK).  Null = known but not yet provisioned —
# placeholder for future work.
#
# Regenerate the shim list on any macOS version:
#   for f in /usr/bin/*; do otool -L "$f" 2>/dev/null | grep -q libxcselect && basename "$f"; done | sort
# The xcrun shim source (xcode_select) is Apple-proprietary and not published
# as open source; on-disk inspection is the ground truth.
# When macOS adds/removes shims, update `allTools` below to match.
{ pkgs, ... }:
let
  allTools = {
    # ── Language runtimes ──
    python3 = "${pkgs.python3}/bin/python3";
    pip3 = "${pkgs.python3}/bin/pip3";

    # ── Compilers & toolchain ──
    cc = "${pkgs.llvmPackages.clang}/bin/clang";
    c89 = "${pkgs.llvmPackages.clang}/bin/clang";
    c99 = "${pkgs.llvmPackages.clang}/bin/clang";
    clang = "${pkgs.llvmPackages.clang}/bin/clang";
    "c++" = "${pkgs.llvmPackages.clang}/bin/clang++";
    "clang++" = "${pkgs.llvmPackages.clang}/bin/clang++";
    gcc = "${pkgs.gcc}/bin/gcc";
    "g++" = "${pkgs.gcc}/bin/g++";
    cpp = "${pkgs.llvmPackages.clang}/bin/clang-cpp";
    ld = "${pkgs.llvmPackages.lld}/bin/ld.lld";

    # ── Version control ──
    git = "${pkgs.git}/bin/git";
    git-receive-pack = "${pkgs.git}/bin/git-receive-pack";
    git-shell = "${pkgs.git}/bin/git-shell";
    git-upload-archive = "${pkgs.git}/bin/git-upload-archive";
    git-upload-pack = "${pkgs.git}/bin/git-upload-pack";

    # ── Build tools ──
    make = "${pkgs.gnumake}/bin/make";

    # ── LLVM debugging & tooling ──
    clangd = "${pkgs.llvmPackages.clang-tools}/bin/clangd";
    lldb = "${pkgs.llvmPackages.lldb}/bin/lldb";
    sourcekit-lsp = "${pkgs.sourcekit-lsp}/bin/sourcekit-lsp";

    # ── Text processing ──
    flex = "${pkgs.flex}/bin/flex";
    "flex++" = "${pkgs.flex}/bin/flex++";
    bison = "${pkgs.bison}/bin/bison";
    m4 = "${pkgs.m4}/bin/m4";
    gm4 = "${pkgs.m4}/bin/m4";
    lex = "${pkgs.flex}/bin/flex"; # alias
    yacc = "${pkgs.bison}/bin/yacc"; # alias
    unifdef = "${pkgs.unifdef}/bin/unifdef";
    indent = "${pkgs.indent}/bin/indent";

    # ── Dev utilities ──
    ctags = "${pkgs.global}/bin/gtags"; # /usr/bin/ctags compat
    libtool = "${pkgs.libtool}/bin/libtool";
    gperf = "${pkgs.gperf}/bin/gperf";

    # ── Apple/Xcode build tools ──
    # These come from xcbuild (reimplementation) — already in apple-sdk's
    # usr/bin/ via the xcrun symlink.  No override needed.
    # xcrun, xcode-select, xcodebuild, actool, ibtool, PlistBuddy — handled
    # by xcbuild.  We intentionally do NOT override these — xcbuild's
    # implementations are purpose-built for the Nix SDK.

    # ── Known but NOT currently provisioned ──
    as = null; # cctools, rarely needed standalone
    ar = null;
    nm = null;
    ranlib = null;
    strings = null;
    strip = null;
    size = null;
    lipo = null;
    otool = null;
    objdump = null;
    dsymutil = null;
    dwarfdump = null;
    codesign_allocate = null;
    ctf_insert = null;
    dyld_info = null;
    vtool = null;
    install_name_tool = null;
    cmpdylib = null;
    segedit = null;
    nmedit = null;
    lorder = null;
    pagestuff = null;
    symbols = null;
    "c++filt" = null;
    unifdefall = null;
    Rez = null;
    DeRez = null;
    ResMerger = null;
    SetFile = null;
    GetFileInfo = null;
    SplitForks = null;
    agvtool = null;
    ictool = null;
    swift = null; # enormous dep chain
    swiftc = null;
    xed = null;
    xcdebug = null;
    xcscontrol = null;
    xcsdiagnose = null;
    xctrace = null;
    stapler = null;
    opendiff = null;
    sdef = null;
    sdp = null;
    genstrings = null;
    headerdoc2html = null;
    gatherheaderdoc = null;
    hdxml2manxml = null;
    xml2man = null;
    atos = null;
    leaks = null;
    vmmap = null;
    heap = null;
    malloc_history = null;
    sample = null;
    stringdups = null;
    filtercalltree = null;
    devicectl = null;
    kmutil = null;
    asa = null;
    desdp = null;
    resolveLinks = null;
    pbxcp = null;
  };

  # ── Subset of allTools for the /usr/local/bin/ symlink farm ────────
  # Only the most commonly needed tools that GUI apps `spawn()` by name
  # (python3, git, make) or that users commonly type in terminals.
  # NOTE: cannot use `inherit (allTools)` here because some names contain
  # `+` which is not a valid Nix identifier token.
  farmSet = {
    python3 = allTools.python3;
    pip3 = allTools.pip3;
    cc = allTools.cc;
    c89 = allTools.c89;
    c99 = allTools.c99;
    clang = allTools.clang;
    "clang++" = allTools."clang++";
    "c++" = allTools."c++";
    cpp = allTools.cpp;
    gcc = allTools.gcc;
    "g++" = allTools."g++";
    ld = allTools.ld;
    git = allTools.git;
    git-receive-pack = allTools.git-receive-pack;
    git-shell = allTools.git-shell;
    git-upload-archive = allTools.git-upload-archive;
    git-upload-pack = allTools.git-upload-pack;
    make = allTools.make;
    flex = allTools.flex;
    "flex++" = allTools."flex++";
    bison = allTools.bison;
    m4 = allTools.m4;
    gm4 = allTools.gm4;
    lex = allTools.lex;
    yacc = allTools.yacc;
    ctags = allTools.ctags;
    libtool = allTools.libtool;
    gperf = allTools.gperf;
    unifdef = allTools.unifdef;
    indent = allTools.indent;
  };
in
{
  inherit allTools;
  symlinkFarmTools = builtins.filterAttrs (_name: path: path != null) farmSet;
}
