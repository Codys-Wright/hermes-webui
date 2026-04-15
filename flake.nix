{
  description = "Hermes WebUI — browser interface for Hermes Agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hermesAgentPkg = hermes-agent.packages.${system}.default;
          # The hermes-agent package wraps a Python env that has run_agent,
          # hermes_cli, pyyaml, and all agent dependencies — reuse it
          hermesAgentEnv = hermesAgentPkg.passthru.env or hermesAgentPkg;
        in
        {
          default = self.packages.${system}.hermes-webui;

          hermes-webui = pkgs.stdenv.mkDerivation {
            pname = "hermes-webui";
            version = "0.50.45";

            src = pkgs.lib.cleanSource ./.;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/hermes-webui
              cp -r server.py api/ static/ $out/lib/hermes-webui/
              # Copy tests for reference but don't include in PATH
              cp -r tests/ $out/lib/hermes-webui/ 2>/dev/null || true

              # Wrapper uses the hermes-agent's Python env so all imports
              # (run_agent, hermes_cli, hermes_state, pyyaml) are available
              mkdir -p $out/bin
              makeWrapper ${hermesAgentPkg}/bin/hermes $out/bin/hermes-webui-agent \
                --argv0 hermes

              # Extract the inner Python env from hermes-agent's wrapper chain:
              # hermes (bash wrapper) -> exec "...hermes-agent-env/bin/hermes" (python script)
              # The Python script's shebang points to the env's python3
              INNER_BIN=$(grep 'exec ' ${hermesAgentPkg}/bin/hermes | tail -1 | sed 's/.*exec "\([^"]*\)".*/\1/')
              HERMES_PYTHON=$(head -1 "$INNER_BIN" | sed 's/^#!//')

              makeWrapper "$HERMES_PYTHON" $out/bin/hermes-webui \
                --add-flags "$out/lib/hermes-webui/server.py" \
                --chdir "$out/lib/hermes-webui" \
                --prefix PATH : "${pkgs.lib.makeBinPath [ hermesAgentPkg ]}"

              runHook postInstall
            '';

            meta = {
              description = "Web interface for Hermes Agent";
              homepage = "https://github.com/nesquena/hermes-webui";
              license = pkgs.lib.licenses.mit;
              mainProgram = "hermes-webui";
            };
          };
        }
      );

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.hermes-webui;
        in
        {
          options.services.hermes-webui = {
            enable = lib.mkEnableOption "Hermes WebUI";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.hermes-webui;
              description = "Hermes WebUI package";
            };

            port = lib.mkOption {
              type = lib.types.int;
              default = 8787;
              description = "Port to listen on";
            };

            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Address to bind to";
            };

            stateDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/hermes-webui";
              description = "State directory for sessions and settings";
            };

            hermesHome = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/hermes/.hermes";
              description = "HERMES_HOME directory (shared with hermes-agent)";
            };

            defaultWorkspace = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/hermes/workspace";
              description = "Default workspace directory";
            };

            defaultModel = lib.mkOption {
              type = lib.types.str;
              default = "ollama/gemma3:4b";
              description = "Default model to use";
            };

            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Extra environment variables";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "hermes";
              description = "User to run as (should match hermes-agent)";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "hermes";
              description = "Group to run as";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.tmpfiles.rules = [
              "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
            ];

            systemd.services.hermes-webui = {
              description = "Hermes WebUI";
              after = [
                "network.target"
                "hermes-agent.service"
              ];
              wants = [ "hermes-agent.service" ];
              wantedBy = [ "multi-user.target" ];

              environment =
                {
                  HERMES_WEBUI_HOST = cfg.host;
                  HERMES_WEBUI_PORT = toString cfg.port;
                  HERMES_WEBUI_STATE_DIR = cfg.stateDir;
                  HERMES_WEBUI_DEFAULT_WORKSPACE = cfg.defaultWorkspace;
                  HERMES_WEBUI_DEFAULT_MODEL = cfg.defaultModel;
                  HERMES_HOME = cfg.hermesHome;
                }
                // cfg.environment;

              serviceConfig = {
                ExecStart = "${cfg.package}/bin/hermes-webui";
                User = cfg.user;
                Group = cfg.group;
                Restart = "always";
                RestartSec = 5;
              };
            };
          };
        };
    };
}
