{
nixpkgs ? <nixpkgs>,
pkgs ? import <nixpkgs> { inherit system; config = {}; },
system ? builtins.currentSystem
} @args:

import "${nixpkgs}/nixos/tests/make-test-python.nix" ({ pkgs, ...}: {
  name = "agenix-integration-systemd";

  nodes.system1 = { config, lib, ... }: {

    imports = [
      ../modules/age.nix
      ./install_ssh_host_keys.nix
    ];

    services.openssh.enable = true;

    age.systemd-creds-flags = "-H";
    age.secrets.service_password = {
      file = ../example/service_password.age;
    };
    age.secrets.service_password2 = {
      file = ../example/service_password2.age;
      unitConfig = {
        wantedBy = [ "dumpcred2.service" ];
        before = [ "dumpcred2.service" ];
      };
    };

    # Test that a unit that depends on the password being installed
    # can access the password.
    systemd.services.dumpcred = config.age.secrets.service_password.wrapUnit {
      enable = true;
      description = "Dumps credentials to /tmp";
      script = ''
        systemd-creds cat service_password | tee /tmp/1
        cat ${config.age.secrets.service_password.credentialPath} | tee /tmp/2
     '';
      serviceConfig = {
        Type = "oneshot";
      };
    };

    # This is a repeat of the previous test, but this depends on the
    # credentials through a reverse-dependency in systemd units.
    systemd.services.dumpcred2 = {
      enable = true;
      description = "Dumps credentials to /tmp";
      script = ''
        systemd-creds cat service_password2 | tee /tmp/3
     '';

      serviceConfig = {
        LoadCredentialEncrypted = config.age.secrets.service_password2.credentialConfig;
        Type = "oneshot";
      };
    };

    # Demonstrates and tests that we can make existing services depend
    # on a secret without modifying them. We use Caddy because it
    # allows substituting environment variables in its config. This is
    # not the case e.g. for nginx, unfortunately.
    services.caddy = {
      enable = true;
      configFile = pkgs.writeText "Caddyfile" ''
http://localhost

root * {$CREDENTIALS_DIRECTORY}
file_server
'';
    };
    systemd.services.caddy = config.age.secrets.service_password.unitTemplate;
  };

  testScript =
  let
    secret = "cleartextABCDEF";
  in ''
    system1.wait_for_unit("multi-user.target")  # Uncomment to make the logs easier to read
    system1.succeed("systemctl start dumpcred")
    assert "${secret}" in system1.succeed("cat /tmp/1"), "systemd-creds could not cat the secret"
    assert "${secret}" in system1.succeed("cat /tmp/2"), "cat credentialPath could not access the secret"

    # TODO: Run the test again, ensure that the secret is not decrypted twice

    system1.succeed("systemctl start dumpcred2")
    assert "${secret}" in system1.succeed("cat /tmp/3"), "reverse-dependency dumpcred2 did not succeed"

    system1.wait_for_unit("caddy.service")
    assert "${secret}" in system1.succeed("curl -q http://localhost/service_password"), "nginx cannot serve the secret"
  '';
}) args
