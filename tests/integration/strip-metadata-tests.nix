# tests/integration/strip-metadata-tests.nix — Verify cross-platform parity for metadata stripping.

let
  lib = import <nixpkgs/lib>;
  macAutomatorWorkflowsText = builtins.readFile ../../src/hosts/MacBook/services/automator-workflows/default.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  nixosDesktopText = builtins.readFile ../../src/hosts/NixOS/desktop.nix;
  windowsDscText = builtins.readFile ../../src/hosts/Windows/user/context-strip-metadata.dsc.yml;
  nautilusScriptText = builtins.readFile ../../src/scripts/integrations/configure-file-manager-strip-metadata.sh;
  dolphinDesktopText = builtins.readFile ../../src/users/default/plasma/desktop/nucleus-strip-metadata.desktop;
  utilsShText = builtins.readFile ../../scripts/utils.sh;
  utilsPs1Text = builtins.readFile ../../scripts/utils.ps1;

  inherit (import ../lib.nix) assert';

  macWorkflowsDir = ../../src/hosts/MacBook/services/automator-workflows;
  macWorkflowPlist = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/strip metadata.workflow/Contents/Info.plist")
  );
  macWorkflowDocument = builtins.readFile (
    builtins.toPath (toString macWorkflowsDir + "/strip metadata.workflow/Contents/document.wflow")
  );

  # The declared input formats — the single source of truth every surface that
  # decides whether the strip-metadata action is offered must agree with.
  types = import ../../src/modules/lib/strip-metadata-types.nix;

  # plistArrayValues — capture the `<string>` values of a `<key>`-named array.
  # WHY: the plist is a text mirror of strip-metadata-types.nix — a .workflow
  # bundle is copied into ~/Library/Services verbatim, so it cannot be generated
  # from Nix — and a scan is the only way to compare the shipped list against
  # the declaration. The assertion below is set equality, not string presence:
  # a format added to the declaration without a matching plist entry fails here
  # instead of silently never appearing in Finder.
  plistArrayValues =
    key: text:
    let
      afterKey = builtins.elemAt (builtins.split "<key>${key}</key>" text) 2;
      body = builtins.head (builtins.split "</array>" afterKey);
    in
    map (match: builtins.elemAt match 0) (
      builtins.filter builtins.isList (builtins.split "<string>([^<]*)</string>" body)
    );

  macosSendFileTypes = plistArrayValues "NSSendFileTypes" macWorkflowPlist;

  # dolphinMimeTypes — the `MimeType=` list of the Dolphin service menu entry.
  dolphinMimeTypes =
    let
      mimeLine = builtins.head (
        builtins.filter (line: lib.hasPrefix "MimeType=" line) (lib.splitString "\n" dolphinDesktopText)
      );
    in
    builtins.filter (entry: builtins.isString entry && entry != "") (
      builtins.split ";" (lib.removePrefix "MimeType=" mimeLine)
    );

  # windowsExtensions — the extensions the Windows context-menu verbs register.
  # Extension of the literal `SystemFileAssociations\.<ext>\shell` key path.
  windowsExtensions = map (match: builtins.elemAt match 0) (
    builtins.filter builtins.isList (
      builtins.split "SystemFileAssociations[\\\\][.]([a-z0-9]+)" windowsDscText
    )
  );

  # Each extension has a verb key and a command key, so it appears twice.
  windowsDeclaredExtensions = uniqueSet windowsExtensions;

  # Set comparison: the surfaces group their entries semantically, so only the
  # membership is contractual.
  asSet = list: builtins.sort builtins.lessThan list;

  uniqueSet =
    list:
    asSet (
      builtins.foldl' (acc: item: if builtins.elem item acc then acc else acc ++ [ item ]) [ ] list
    );

  # hasBarePackageEntry — does a Nix file list `name` as a bare entry (the
  # desktop package list is `with pkgs;`-scoped, so entries carry no `pkgs.`
  # prefix)? WHY: the entry, not the word — a mention inside a comment must not
  # satisfy an assertion about what is installed. The trailing `\n` also keeps
  # a commented-out `# zenity` from matching.
  hasBarePackageEntry =
    name: text:
    builtins.length (builtins.filter builtins.isList (builtins.split "\n[ \t]*${name}[ \t]*\n" text))
    >= 1;

  # === Declared input format set ===

  test_declared_formats_are_complete = assert' (
    types.supported != [ ]
    && types.unsupported != [ ]
    && lib.all (
      format:
      format.extensions != [ ]
      && format.mimes != [ ]
      && (format.uti or null) != null
      && !(lib.any (extension: lib.hasInfix "." extension) format.extensions)
    ) types.supported
  ) "every supported format must declare dot-free extensions, at least one MIME type and a UTI";

  test_declared_formats_never_offer_pdf = assert' (
    !(lib.hasInfix "pdf" (lib.concatStrings types.macosSendFileTypes))
    && !(lib.hasInfix "pdf" (lib.concatStrings types.dolphinMimeTypes))
    && !(lib.hasInfix "pdf" (lib.concatStrings types.allExtensions))
  ) "no declared input format may be a PDF: strip-metadata cannot rewrite PDF metadata";

  # === macOS tests ===

  test_single_strip_metadata_workflow_exists = assert' (
    lib.hasInfix "strip metadata.workflow" macAutomatorWorkflowsText
    && lib.hasInfix "com.nucleus.StripMetadata" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - excel.workflow" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - word.workflow" macAutomatorWorkflowsText
    && !lib.hasInfix "strip metadata - powerpoint.workflow" macAutomatorWorkflowsText
  ) "macOS automator-workflows.nix must define exactly 1 strip-metadata workflow (not 6 variants)";

  test_strip_metadata_offers_declared_types_only =
    assert' (asSet macosSendFileTypes == asSet types.macosSendFileTypes)
      "strip metadata Info.plist NSSendFileTypes must match macosSendFileTypes in strip-metadata-types.nix";

  # The offered types are compared as a set above; this pins the two ways the
  # action could silently widen again — the PDF type itself, and a broad root
  # type (public.item/public.data) that matches everything.
  test_strip_metadata_workflow_does_not_offer_pdf = assert' (
    !(builtins.elem "com.adobe.pdf" macosSendFileTypes)
    && !(builtins.elem "public.item" macosSendFileTypes)
    && !(builtins.elem "public.data" macosSendFileTypes)
  ) "strip metadata Quick Action must not be offered for PDFs (or every file type)";

  test_strip_metadata_workflow_reports_in_one_dialog =
    assert'
      (
        lib.hasInfix "strip-metadata --dialog \"$@\"" macWorkflowDocument
        && !lib.hasInfix "for f in \"$@\"" macWorkflowDocument
      )
      "strip metadata workflow must hand the whole selection to one --dialog invocation, not loop over files";

  # === NixOS tests ===

  test_nixos_has_strip_metadata = assert' (
    lib.hasInfix "strip metadata" nixosServicesText
    && lib.hasInfix "strip-metadata-nautilus" nixosServicesText
  ) "NixOS services.nix must define strip-metadata Nautilus script";

  test_nixos_file_manager_entries_offer_declared_types_only =
    assert' (asSet dolphinMimeTypes == asSet types.dolphinMimeTypes)
      "Dolphin nucleus-strip-metadata.desktop MimeType must match dolphinMimeTypes in strip-metadata-types.nix";

  test_nixos_file_manager_entries_report_in_one_dialog = assert' (
    lib.hasInfix "strip-metadata --dialog" nautilusScriptText
    && lib.hasInfix "strip-metadata --dialog %f" dolphinDesktopText
  ) "NixOS file manager entries must pass --dialog so a skip is reported in a dialog";

  test_nixos_desktop_provides_dialog_tool = assert' (hasBarePackageEntry "zenity" nixosDesktopText) "NixOS desktop.nix must install zenity, the dialog tool the Nautilus and Dolphin entries need";

  # === Windows tests ===

  test_windows_has_strip_metadata_label = assert' (lib.hasInfix "strip metadata" windowsDscText) "Windows DSC must use the 'strip metadata' label";

  # Windows deliberately offers a subset — the Office formats, legacy OLE2
  # included, so that an old .doc still explains itself in the dialog. The
  # contract is that it never registers an extension outside the declared set.
  test_windows_verbs_use_declared_extensions = assert' (
    windowsDeclaredExtensions != [ ]
    && !(builtins.elem "pdf" windowsDeclaredExtensions)
    && lib.all (extension: builtins.elem extension types.allExtensions) windowsDeclaredExtensions
  ) "Windows context-menu verbs must register only extensions declared in strip-metadata-types.nix";

  test_windows_verbs_report_in_one_dialog = assert' (
    builtins.length (
      builtins.filter builtins.isList (builtins.split "strip-metadata -Dialog '%1'" windowsDscText)
    ) == builtins.length windowsDeclaredExtensions
  ) "every Windows strip-metadata verb must pass -Dialog so a skip is reported in a dialog";

  # === Report channel parity tests ===

  test_posix_has_notify_helper = assert' (
    lib.hasInfix "_notify" utilsShText
    && lib.hasInfix "osascript" utilsShText
    && lib.hasInfix "notify-send" utilsShText
  ) "POSIX utils.sh must define _notify helper with osascript + notify-send";

  test_posix_reports_skips_in_one_dialog =
    assert'
      (
        lib.hasInfix "_popup()" utilsShText
        && lib.hasInfix "zenity" utilsShText
        && lib.hasInfix "kdialog" utilsShText
        && lib.hasInfix "_strip_metadata_summary" utilsShText
        && lib.hasInfix "--dialog" utilsShText
      )
      "POSIX utils.sh must aggregate not-processed inputs into one modal dialog (osascript/zenity/kdialog)";

  test_windows_has_notification = assert' (lib.hasInfix "Show-NucleusNotification" utilsPs1Text) "Windows utils.ps1 must call Show-NucleusNotification in strip-metadata path";

  test_windows_reports_skips_in_one_dialog = assert' (
    lib.hasInfix "Show-NucleusPopup" utilsPs1Text && lib.hasInfix "$Dialog" utilsPs1Text
  ) "Windows utils.ps1 must aggregate not-processed inputs into one modal popup (-Dialog)";

  allTests = [
    test_declared_formats_are_complete
    test_declared_formats_never_offer_pdf
    test_single_strip_metadata_workflow_exists
    test_strip_metadata_offers_declared_types_only
    test_strip_metadata_workflow_does_not_offer_pdf
    test_strip_metadata_workflow_reports_in_one_dialog
    test_nixos_has_strip_metadata
    test_nixos_file_manager_entries_offer_declared_types_only
    test_nixos_file_manager_entries_report_in_one_dialog
    test_nixos_desktop_provides_dialog_tool
    test_windows_has_strip_metadata_label
    test_windows_verbs_use_declared_extensions
    test_windows_verbs_report_in_one_dialog
    test_posix_has_notify_helper
    test_posix_reports_skips_in_one_dialog
    test_windows_has_notification
    test_windows_reports_skips_in_one_dialog
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "strip-metadata cross-platform parity tests passed";
}
