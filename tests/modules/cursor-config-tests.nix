# tests/modules/cursor-config-tests.nix — Cursor BYOK settings value invariants.

let
  inherit (import ../lib.nix) assert';

  settings = builtins.fromJSON (builtins.readFile ../../src/users/default/cursor/settings.json);

  test_byok_api_key = assert' (settings."cursor.aiprovider.openai.apiKey" == "sk-nucleus-litellm")
    "cursor BYOK apiKey must be sk-nucleus-litellm";

  test_byok_base_url = assert' (settings."cursor.aiprovider.openai.baseUrl" == "http://127.0.0.1:4000/v1")
    "cursor BYOK baseUrl must be http://127.0.0.1:4000/v1";

  test_byok_model = assert' (settings."cursor.aiprovider.openai.model" == "deepseek/deepseek-v4-flash")
    "cursor BYOK model must be deepseek/deepseek-v4-flash";

  allTests = [ test_byok_api_key test_byok_base_url test_byok_model ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} cursor BYOK settings tests passed";
}
