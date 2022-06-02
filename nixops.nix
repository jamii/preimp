let

pkgs = import <nixpkgs> {};

secret = import ./secret.nix;

in

{
    network.storage.legacy = {
        databasefile = "~/.nixops/deployments.nixops";
    };
    
    preimp = { lib, config, options, modulesPath, specialArgs }: rec {
        deployment.targetHost = secret.targetHost;
        
        imports = [
            ./hardware-configuration.nix
        ];
        
        boot.loader.grub.enable = true;
        boot.loader.grub.version = 2;
        boot.loader.grub.device = "/dev/vda";
        
        networking = {
            hostName = secret.hostName;
            domain = secret.domain;
            useDHCP = false;
            interfaces.enp1s0.useDHCP = true;
            firewall = {
                enable = true;
                allowedTCPPorts = [80 443];
            };
        };
        
        services.openssh = {
            enable = true;
            passwordAuthentication = false;
        };
        
        users.extraUsers.jamie = {
            uid = 1000;
            extraGroups = ["wheel"];
            useDefaultShell = true;
            createHome = true;
            openssh.authorizedKeys.keyFiles = [
                ~/.ssh/id_rsa.pub
            ];
            isNormalUser = true;
        };
        security.sudo.extraConfig = "jamie ALL=(ALL) NOPASSWD:ALL";
        
        services.nginx = {
            enable = true;
            recommendedTlsSettings = true;
            recommendedOptimisation = true;
            recommendedGzipSettings = true;
            recommendedProxySettings = true;
            virtualHosts = {
                "preimp.scattered-thoughts.net" = {
                    enableACME = true;
                    forceSSL = true;
                    locations."/" = {
                        proxyPass = "http://0.0.0.0:3000"; # without a trailing /
                        extraConfig = ''
                            proxy_set_header Upgrade $http_upgrade;
                            proxy_set_header Connection "Upgrade";
                        '';
                    };
                    basicAuth = secret.basicAuth;
                };
            };
        };
        
        security.acme.acceptTerms = true;
        security.acme.email = "jamie@scattered-thoughts.net";
        
        systemd.services.preimp = {
            description = "preimp";
            path = with pkgs; [ jre ];
            serviceConfig = {
                User = "jamie";
                WorkingDirectory = "/home/jamie";
                ExecStart = "/usr/bin/env java -jar ${./target/preimp-1.0.0-standalone.jar}";
            };
        };
        
        environment.systemPackages = [
            pkgs.htop
        ];
        
        system.stateVersion = "21.11";
        
        nix.gc.automatic = true;
        nix.optimise.automatic = true;
        nix.autoOptimiseStore = true;
        
        # system.autoUpgrade.enable = true;
        # system.autoUpgrade.allowReboot = true;
        
    };
}
