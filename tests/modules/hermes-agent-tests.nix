# tests/modules/hermes-agent-tests.nix — Hermes Agent service registry and cross-host parity.
#
# Validates services.json hermes-agent entry per host.
#
# Run with: nix-instantiate --eval tests/modules/hermes-agent-tests.nix

let
  inherit (import ../lib.nix) assert';

  servicesJson = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  hermes = servicesJson.hermes-agent;
  hosts = hermes.hosts;

  # Per-host type/service
  hostTypes = builtins.mapAttrs (_: v: v.type or null) hosts;
  hostServices = builtins.mapAttrs (_: v: v.service or null) hosts;

  # --- Secret selection and SOPS coverage (fixture-driven) ---
  # Both rules live in src/modules/lib/hermes-secrets.nix, where they are free of
  # file access and platform context: this is the only place they can be
  # exercised without a full NixOS evaluation.
  secretUtils = import ../../src/modules/lib/hermes-secrets.nix;

  # Four entries: one per SOPS file, a second user entry whose keys are also
  # declared, and one consumed by another tool — which must be ignored.
  fixtureSecrets = [
    {
      name = "TELEGRAM_BOT_TOKEN";
      consumers = [ "hermes-agent" ];
      sopsSource = "system";
    }
    {
      name = "NTFY_TOPIC";
      consumers = [ "hermes-agent" ];
      sopsSource = "user";
    }
    {
      name = "OTHER_CONSUMER_KEY";
      consumers = [ "blogbot" ];
      sopsSource = "system";
    }
    {
      name = "BOTH_FILES_KEY";
      consumers = [ "hermes-agent" ];
      sopsSource = "user";
    }
  ];

  secretNames = entries: builtins.map (entry: entry.name) entries;
  fixtureGroups = secretUtils.selectHermesSecrets fixtureSecrets;

  # Every key of a group is present in its own SOPS file.  Each list also carries
  # a key of another consumer, which is what a shared SOPS file looks like.
  completeAudit = secretUtils.auditHermesSecrets {
    groups = fixtureGroups;
    systemKeys = [
      "TELEGRAM_BOT_TOKEN"
      "OTHER_CONSUMER_KEY"
    ];
    userKeys = [
      "NTFY_TOPIC"
      "BOTH_FILES_KEY"
    ];
  };

  # The system file carries the user keys only, so every system key is missing;
  # the user file carries the system key only, so every user key is.
  systemMissingAudit = secretUtils.auditHermesSecrets {
    groups = fixtureGroups;
    systemKeys = [ "NTFY_TOPIC" ];
    userKeys = [
      "NTFY_TOPIC"
      "BOTH_FILES_KEY"
    ];
  };
  userMissingAudit = secretUtils.auditHermesSecrets {
    groups = fixtureGroups;
    systemKeys = [ "TELEGRAM_BOT_TOKEN" ];
    userKeys = [ "TELEGRAM_BOT_TOKEN" ];
  };

  emptyGroups = secretUtils.selectHermesSecrets [ ];
  emptyAudit = secretUtils.auditHermesSecrets {
    groups = emptyGroups;
    systemKeys = [ ];
    userKeys = [ ];
  };
in
{
  tests = builtins.filter (x: x != null) [
    # --- Behavioral: services.json structure ---
    (assert' (hermes ? displayName) "hermes-agent must have displayName")
    (assert' (hermes.displayName == "Hermes Agent") "hermes-agent displayName must be 'Hermes Agent'")
    (assert' (hermes ? logging) "hermes-agent must have logging config")
    (assert' (hermes.logging.capture == "all") "hermes-agent must capture all logs")

    # --- MacBook: launchd user agent ---
    (assert' (
      hostTypes.MacBook == "macos-launchctl"
    ) "MacBook hermes-agent must be launchctl, got ${hostTypes.MacBook or "null"}")
    (assert' (
      hostServices.MacBook == "org.nix-community.home.hermes-agent"
    ) "MacBook hermes-agent service must be org.nix-community.home.hermes-agent")
    (assert' (hosts.MacBook.scope == "user") "MacBook hermes-agent must be user-scoped")
    (assert' (hosts.MacBook.launchdDomain == "gui") "MacBook hermes-agent must use gui domain")

    # --- NixOS: systemd user service ---
    (assert' (
      hostTypes.NixOS == "nixos-systemctl"
    ) "NixOS hermes-agent must be systemctl, got ${hostTypes.NixOS or "null"}")
    (assert' (
      hostServices.NixOS == "hermes-agent.service"
    ) "NixOS hermes-agent service must be hermes-agent.service")
    (assert' (hosts.NixOS.scope == "user") "NixOS hermes-agent must be user-scoped")

    # --- Windows: SCM native service ---
    (assert' (
      hostTypes.Windows == "windows-native"
    ) "Windows hermes-agent must be native SCM, got ${hostTypes.Windows or "null"}")
    (assert' (
      hostServices.Windows == "hermes-gateway"
    ) "Windows hermes-agent service must be hermes-gateway")

    # --- Selection: which catalog entries the gateway consumes ---
    (assert'
      (
        secretNames fixtureGroups.all == [
          "TELEGRAM_BOT_TOKEN"
          "NTFY_TOPIC"
          "BOTH_FILES_KEY"
        ]
      )
      "only entries whose consumers name hermes-agent may be selected, got ${builtins.toJSON (secretNames fixtureGroups.all)}"
    )
    (assert' (secretNames fixtureGroups.system == [ "TELEGRAM_BOT_TOKEN" ])
      "the system group must hold the entries declared in the system SOPS file, got ${builtins.toJSON (secretNames fixtureGroups.system)}"
    )
    (assert'
      (
        secretNames fixtureGroups.user == [
          "NTFY_TOPIC"
          "BOTH_FILES_KEY"
        ]
      )
      "the user group must hold the entries declared in the user SOPS file, got ${builtins.toJSON (secretNames fixtureGroups.user)}"
    )
    (assert' (
      !(builtins.elem "OTHER_CONSUMER_KEY" (secretNames fixtureGroups.all))
    ) "a secret consumed by another tool must not be declared for the gateway")

    # --- Audit: declared keys missing from the SOPS file they name ---
    (assert' (completeAudit.all == [ ])
      "a catalog whose keys all exist in their SOPS files must report nothing missing, got ${builtins.toJSON completeAudit.all}"
    )
    (assert' (
      systemMissingAudit.system == [ "TELEGRAM_BOT_TOKEN" ]
    ) "a declared system key absent from the system SOPS file must be reported")
    (assert' (
      systemMissingAudit.user == [ ]
    ) "a group whose declared keys are all present must not be reported")
    (assert' (
      systemMissingAudit.all == [ "TELEGRAM_BOT_TOKEN" ]
    ) "the missing-key list must carry the system group and not the user group")
    (assert' (
      userMissingAudit.user == [
        "NTFY_TOPIC"
        "BOTH_FILES_KEY"
      ]
    ) "every declared user key absent from the user SOPS file must be reported, in catalog order")
    (assert' (
      userMissingAudit.system == [ ]
    ) "an absent key in one SOPS file must not implicate the other file's group")
    (assert' (
      userMissingAudit.all == [
        "NTFY_TOPIC"
        "BOTH_FILES_KEY"
      ]
    ) "the missing-key list must carry the system group before the user group")
    (assert' (
      emptyGroups.all == [ ] && emptyGroups.system == [ ] && emptyGroups.user == [ ]
    ) "an absent catalog must select nothing rather than fail")
    (assert' (emptyAudit.all == [ ]) "an absent catalog must not report missing keys")
  ];

  success = true;
  message = "Hermes Agent tests passed";
}
