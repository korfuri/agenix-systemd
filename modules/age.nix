{ config, options, lib, pkgs, ... }:
with lib;
let
  cfg = config.age;
  
  # we need at least rage 0.5.0 to support ssh keys
  rage =
    if lib.versionOlder pkgs.rage.version "0.5.0"
    then pkgs.callPackage ../pkgs/rage.nix { }
    else pkgs.rage;
  ageBin = config.age.ageBin;
  systemdCredsBin = config.age.systemdCredsBin;

  identities = builtins.concatStringsSep " " (map (path: "-i ${path}") cfg.identityPaths);

  installSecret = secretType: ''
  set -xe
  echo "[agenix] Processing secret ${secretType.name}"
  _truePath="${secretType.path}"
  TMP_FILE="$_truePath.tmp"
  echo "[agenix] true path: $_truePath"
  echo "[agenix] Tmp path: $TMP_FILE"
  mkdir -p "$(dirname "$_truePath")"
  (
    umask u=r,g=,o=
    test -f "${secretType.file}" || echo '[agenix] WARNING: encrypted file ${secretType.file} does not exist!'
    test -d "$(dirname "$TMP_FILE")" || echo "[agenix] WARNING: $(dirname "$TMP_FILE") does not exist!"
    echo "[agenix] Decrypt:"
    ${ageBin} --decrypt ${identities} -o - ${secretType.file} | base64
    ${ageBin} --decrypt ${identities} -o - ${secretType.file} | ${systemdCredsBin} ${cfg.systemd-creds-flags} encrypt --name="${secretType.name}" - - > "$TMP_FILE" || echo "[agenix] Something went wrong!"
  )
  chmod 600 "$TMP_FILE"
  chown 0:0 "$TMP_FILE"
  mv -f "$TMP_FILE" "$_truePath"
  '';

  secretType = types.submodule ({ config, ... }: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Name of the file used in ''${cfg.secretsDir}
        '';
      };
      file = mkOption {
        type = types.path;
        description = ''
          Age file the secret is loaded from.
        '';
      };
      path = mkOption {
        type = types.str;
        default = "${cfg.secretsDir}/${config.name}";
        description = ''
          Path where the decrypted secret is installed.
        '';
      };
    };
  });
  
  installSecrets = builtins.concatStringsSep "\n" (map installSecret (builtins.attrValues cfg.secrets));
in {
  options.age = {
    ageBin = mkOption {
      type = types.str;
      default = "${rage}/bin/rage";
      description = ''
        The age executable to use.
      '';
    };
    systemdCredsBin = mkOption {
      type = types.str;
      default = "${pkgs.systemd}/bin/systemd-creds";
      description = ''
        The systemd-creds executable to use.
      '';
    };
    systemd-creds-flags = mkOption {
      type = types.str;
      default = "";
      description = ''
        Extra flags to systemd-creds.
      '';
      example = "-H";
    };
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = { };
      description = ''
        Attrset of secrets.
      '';
    };
    secretsDir = mkOption {
      type = types.path;
      default = "/run/agenix";
      description = ''
        Folder where secrets are symlinked to
      '';
    };
    identityPaths = mkOption {
      type = types.listOf types.path;
      default =
        if config.services.openssh.enable then
          map (e: e.path) (lib.filter (e: e.type == "rsa" || e.type == "ed25519") config.services.openssh.hostKeys)
        else [ ];
      description = ''
        Path to SSH keys to be used as identities in age decryption.
      '';
    };
  };

  config = mkIf (cfg.secrets != { }) {
    assertions = [{
      assertion = cfg.identityPaths != [ ];
      message = "age.identityPaths must be set.";
    }];

    systemd.services.agenix-systemd = {
      enable = true;
      description = "Decrypts age-encrypted secrets and re-encrypts them to systemd";
      script = installSecrets;
      serviceConfig = {
        Type = "oneshot"; # TODO: for some reason, the dependent oneshot service in hte integration test is not waiting on us despite being of type oneshot. Why?
      };
    };
  };
}
