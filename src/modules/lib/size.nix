# Size string parsing shared by VM provisioning.  src/scripts/lib/size.sh and
# src/platforms/Windows/modules/SizeStrings.ps1 implement the IDENTICAL grammar;
# keep all three in sync (see test_size_grammar_parity_across_implementations).
#
# Grammar: ^([0-9]+) ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$
#   - Decimal prefixes (kB/MB/GB/TB) multiply by powers of 10.
#   - Binary prefixes (kiB/MiB/GiB/TiB) multiply by powers of 2.
#   - A single optional space between the number and the prefix is allowed.
#   - The grammar is case-sensitive: KB, KiB and lowercase prefixes are invalid.
# Invalid strings abort evaluation with an error (never coerce to a value).
let
  factors = {
    kB = 1000;
    MB = 1000000;
    GB = 1000000000;
    TB = 1000000000000;
    kiB = 1024;
    MiB = 1024 * 1024;
    GiB = 1024 * 1024 * 1024;
    TiB = 1024 * 1024 * 1024 * 1024;
  };
  grammar = "^([0-9]+) ?(kB|MB|GB|TB|kiB|MiB|GiB|TiB)$";
in
{
  # parse SIZE_STRING — exact byte count, or an evaluation error when invalid.
  parse =
    input:
    let
      m = builtins.match grammar input;
    in
    if m == null then
      builtins.throw "invalid size string '${input}' (expected ${grammar})"
    else
      builtins.fromJSON (builtins.elemAt m 0) * factors.${builtins.elemAt m 1};

  # ceilMib BYTES — round UP to whole MiB so allocated guest memory never
  # under-allocates the declared size (UTM and the QEMU -m flag use MiB).
  ceilMib = bytes: (bytes + 1048576 - 1) / 1048576;
}
