# src/modules/lib/strip-metadata-types.nix — input formats `nucleus-utils strip-metadata` accepts.
#
# WHY: one declared set instead of one copy per surface. Three surfaces decide
# whether the action is offered, each in its own vocabulary — macOS Quick Action
# NSSendFileTypes (UTIs), KDE Dolphin MimeType (MIME types) and Windows
# context-menu verbs (extensions) — and drift between them is silent: a format
# missing from one list simply stops appearing in that file manager.
# tests/integration/strip-metadata-tests.nix fails when a surface drifts.
#
# WHY: PDF (com.adobe.pdf) is in no list. No CLI tool rewrites PDF metadata in
# place without invalidating signatures, so strip-metadata refuses PDFs;
# offering the action for a format the tool must refuse made the feature look
# broken — the action ran and appeared to do nothing. Where the platform can
# filter the input it does: NSSendFileTypes and Dolphin MimeType are
# inclusion-only (Apple defines no exclusion key), so the refusal is expressed
# as an allow-list. Where it cannot (Nautilus Scripts declare no type filter)
# the caller reports the refusal in a modal dialog — see `--dialog` in
# scripts/utils.sh.
#
# WHY: Apple's media supertypes are listed alongside the specific UTIs they
# cover. A third-party format with no type declaration gets a dyn.* UTI that
# conforms only to public.data, so the supertype covers it; a declaration that
# does not claim the class is covered by the specific UTI. Neither can match a
# PDF: com.adobe.pdf conforms to public.data and public.composite-content only.
# Source: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/UTIRef/Articles/System-DeclaredUniformTypeIdentifiers.html
let
  # dedupSorted — byte-ordered unique list. Every surface must serialize
  # identically, and several formats share a MIME type or UTI (the ODF and OGG
  # families), so duplicates would otherwise reach the .desktop and plist.
  dedupSorted =
    list:
    builtins.sort builtins.lessThan (
      builtins.foldl' (acc: item: if builtins.elem item acc then acc else acc ++ [ item ]) [ ] list
    );

  # Formats strip-metadata rewrites in place: mat2 for OOXML, exiftool for the
  # rest. `extensions` is dot-free and non-empty — the Windows context menu
  # registers one verb per extension.
  supported = [
    {
      extensions = [ "docx" ];
      mimes = [ "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ];
      uti = "org.openxmlformats.wordprocessingml.document";
    }
    {
      extensions = [ "epub" ];
      mimes = [ "application/epub+zip" ];
      uti = "org.idpf.epub-container";
    }
    {
      extensions = [ "flac" ];
      mimes = [ "audio/flac" ];
      uti = "org.xiph.flac";
    }
    {
      extensions = [ "gif" ];
      mimes = [ "image/gif" ];
      uti = "com.compuserve.gif";
    }
    {
      extensions = [
        "jpeg"
        "jpg"
      ];
      mimes = [ "image/jpeg" ];
      uti = "public.jpeg";
    }
    {
      extensions = [ "mkv" ];
      mimes = [ "video/x-matroska" ];
      uti = "org.matroska.mkv";
    }
    {
      extensions = [ "mp3" ];
      mimes = [ "audio/mpeg" ];
      uti = "public.mp3";
    }
    {
      extensions = [ "mp4" ];
      mimes = [ "video/mp4" ];
      uti = "public.mpeg-4";
    }
    {
      extensions = [ "odp" ];
      mimes = [ "application/vnd.oasis.opendocument.presentation" ];
      uti = "org.oasis-open.opendocument.presentation";
    }
    {
      extensions = [ "ods" ];
      mimes = [ "application/vnd.oasis.opendocument.spreadsheet" ];
      uti = "org.oasis-open.opendocument.spreadsheet";
    }
    {
      extensions = [ "odt" ];
      mimes = [ "application/vnd.oasis.opendocument.text" ];
      uti = "org.oasis-open.opendocument.text";
    }
    {
      extensions = [
        "oga"
        "ogg"
      ];
      mimes = [
        "application/ogg"
        "audio/ogg"
      ];
      uti = "org.xiph.ogg-audio";
    }
    {
      extensions = [
        "pbm"
        "pgm"
        "ppm"
      ];
      mimes = [ "image/x-portable-pixmap" ];
      uti = "public.pbm";
    }
    {
      extensions = [ "png" ];
      mimes = [ "image/png" ];
      uti = "public.png";
    }
    {
      extensions = [ "pptx" ];
      mimes = [ "application/vnd.openxmlformats-officedocument.presentationml.presentation" ];
      uti = "org.openxmlformats.presentationml.presentation";
    }
    {
      extensions = [
        "tif"
        "tiff"
      ];
      mimes = [ "image/tiff" ];
      uti = "public.tiff";
    }
    {
      extensions = [ "wav" ];
      mimes = [ "audio/x-wav" ];
      uti = "com.microsoft.waveform-audio";
    }
    {
      extensions = [ "webm" ];
      mimes = [ "video/webm" ];
      uti = "org.webmproject.webm";
    }
    {
      extensions = [ "webp" ];
      mimes = [ "image/webp" ];
      uti = "org.webmproject.webp";
    }
    {
      extensions = [ "xlsx" ];
      mimes = [ "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ];
      uti = "org.openxmlformats.spreadsheetml.sheet";
    }
  ];

  # Formats no CLI tool can rewrite in place. The surfaces that exist to explain
  # a refusal (Windows context menu, Nautilus report) still offer them; the
  # filtering surfaces (macOS Quick Action, Dolphin) do not.
  unsupported = [
    {
      extensions = [ "doc" ];
      mimes = [ "application/msword" ];
    }
    {
      extensions = [ "ppt" ];
      mimes = [ "application/vnd.ms-powerpoint" ];
    }
    {
      extensions = [ "xls" ];
      mimes = [ "application/vnd.ms-excel" ];
    }
  ];

  # Apple's class UTIs for the media formats above.
  macosSupertypes = [
    "public.audio"
    "public.image"
    "public.movie"
  ];

  all = supported ++ unsupported;
in
{
  inherit supported unsupported;

  # macOS: NSSendFileTypes of the strip metadata Quick Action. `unsupported`
  # formats are deliberately not offered — the action must not appear for input
  # the tool will refuse.
  macosSendFileTypes = dedupSorted (macosSupertypes ++ map (format: format.uti) supported);

  # Dolphin service menu: `MimeType=` of nucleus-strip-metadata.desktop. Unlike
  # macOS this also covers `unsupported`: Dolphin can show the refusal, and an
  # old .doc would otherwise get no explanation at all.
  dolphinMimeTypes = dedupSorted (builtins.concatMap (format: format.mimes) all);

  # Every declared extension, dot-free — the vocabulary the Windows registry
  # verbs and the parity test work in.
  allExtensions = dedupSorted (builtins.concatMap (format: format.extensions) all);
}
