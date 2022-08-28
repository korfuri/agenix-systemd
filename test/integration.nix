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

    systemd.services.dumpcred = {
      enable = true;
      description = "Dumps credentials to /tmp";
      requires = [ "agenix-systemd.service" ];
      after = [ "agenix-systemd.service" ];
      script = ''
        systemd-creds cat service_password | tee /tmp/1
     '';

      serviceConfig = {
        Type = "oneshot";
        LoadCredentialEncrypted = "service_password:${config.age.secrets.service_password.path}";
      };
    };
  };

  testScript =
  let
    secret = "cleartextABCDEF";
  in ''
    system1.succeed("systemctl start dumpcred")
    assert "${secret}" in system1.succeed("cat /tmp/1")
  '';
}) args
