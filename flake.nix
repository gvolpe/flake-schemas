{
  description = "Schemas for well-known Nix flake output types";

  outputs = { self }:

    let
      mapAttrsToList = f: attrs: map (name: f name attrs.${name}) (builtins.attrNames attrs);

      checkDerivation = drv:
        drv.type or null == "derivation"
        && drv ? drvPath;

      schemasSchema = {
        version = 1;
        doc = ''
          The `schemas` flake output is used to define and document flake outputs.
          For the expected format, consult the Nix manual.
        '';
        inventory = output: self.lib.mkChildren (builtins.mapAttrs
          (schemaName: schemaDef:
            {
              shortDescription = "A schema checker for the `${schemaName}` flake output";
              evalChecks.isValidSchema =
                schemaDef.version or 0 == 1
                && schemaDef ? doc
                && builtins.isString (schemaDef.doc)
                && schemaDef ? inventory
                && builtins.isFunction (schemaDef.inventory);
              what = "flake schema";
            })
          output);
      };

      packagesSchema = {
        version = 1;
        doc = ''
          The `packages` flake output contains packages that can be added to a shell using `nix shell`.
        '';
        inventory = self.lib.derivationsInventory "package" false;
      };

      legacyPackagesSchema = {
        version = 1;
        doc = ''
          The `legacyPackages` flake output is similar to `packages`, but it can be nested (i.e. contain attribute sets that contain more packages).
          Since enumerating the packages in nested attribute sets is inefficient, `legacyPackages` should be avoided in favor of `packages`.
        '';
        inventory = output:
          self.lib.mkChildren (builtins.mapAttrs
            (systemType: packagesForSystem:
              {
                forSystems = [ systemType ];
                children =
                  let
                    recurse = prefix: attrs: builtins.listToAttrs (builtins.concatLists (mapAttrsToList
                      (attrName: attrs:
                        # Necessary to deal with `AAAAAASomeThingsFailToEvaluate` etc. in Nixpkgs.
                        self.lib.try
                          (
                            if attrs.type or null == "derivation" then
                              [{
                                name = attrName;
                                value = {
                                  forSystems = [ attrs.system ];
                                  shortDescription = attrs.meta.description or "";
                                  derivation = attrs;
                                  evalChecks.isDerivation = checkDerivation attrs;
                                  what = "package";
                                };
                              }]
                            else
                            # Recurse at the first and second levels, or if the
                            # recurseForDerivations attribute if set.
                              if attrs.recurseForDerivations or false
                              then
                                [{
                                  name = attrName;
                                  value.children = recurse (prefix + attrName + ".") attrs;
                                }]
                              else
                                [ ]
                          )
                          [ ])
                      attrs));
                  in
                  # The top-level cannot be a derivation.
                  assert packagesForSystem.type or null != "derivation";
                  recurse (systemType + ".") packagesForSystem;
              })
            output);
      };

      checksSchema = {
        version = 1;
        doc = ''
          The `checks` flake output contains derivations that will be built by `nix flake check`.
        '';
        inventory = self.lib.derivationsInventory "CI test" true;
      };

      devShellsSchema = {
        version = 1;
        doc = ''
          The `devShells` flake output contains derivations that provide a development environment for `nix develop`.
        '';
        inventory = self.lib.derivationsInventory "development environment" false;
      };

      hydraJobsSchema = {
        version = 1;
        doc = ''
          The `hydraJobs` flake output defines derivations to be built
          by the Hydra continuous integration system.
        '';
        allowIFD = false;
        inventory = output:
          let
            recurse = prefix: attrs: self.lib.mkChildren (builtins.mapAttrs
              (attrName: attrs:
                if attrs.type or null == "derivation" then
                  {
                    forSystems = [ attrs.system ];
                    shortDescription = attrs.meta.description or "";
                    derivation = attrs;
                    evalChecks.isDerivation = checkDerivation attrs;
                    what = "Hydra CI test";
                  }
                else
                  recurse (prefix + attrName + ".") attrs
              )
              attrs);
          in
          # The top-level cannot be a derivation.
          assert output.type or null != "derivation";
          recurse "" output;
      };

      appsSchema = {
        version = 1;
        doc = ''
          The `apps` output provides commands available via `nix run`.
        '';
        inventory = output:
          self.lib.mkChildren (builtins.mapAttrs
            (system: apps:
              let
                forSystems = [ system ];
              in
              {
                inherit forSystems;
                children =
                  builtins.mapAttrs
                    (appName: app: {
                      inherit forSystems;
                      evalChecks.isValidApp =
                        app ? type
                        && app.type == "app"
                        && app ? program
                        && builtins.isString app.program;
                      what = "app";
                    })
                    apps;
              })
            output);
      };

      libSchema = {
        version = 1;
        doc = ''
          The `lib` flake output exposes arbitrary Nix terms.
        '';
        inventory =
          let
            processValue = value:
              let
                what = builtins.typeOf value;
              in
              if what == "set" then
                self.lib.mkChildren
                  (builtins.mapAttrs (name: processValue) value)
              else { inherit what; };
          in
          processValue;
      };

      overlaysSchema = {
        version = 1;
        doc = ''
          The `overlays` flake output defines ["overlays"](https://nixos.org/manual/nixpkgs/stable/#chap-overlays) that can be plugged into Nixpkgs.
          Overlays add additional packages or modify or replace existing packages.
        '';
        inventory = output: self.lib.mkChildren (builtins.mapAttrs
          (overlayName: overlay:
            {
              what = "Nixpkgs overlay";
              evalChecks.isOverlay =
                # FIXME: should try to apply the overlay to an actual
                # Nixpkgs.  But we don't have access to a nixpkgs
                # flake here. Maybe this schema should be moved to the
                # nixpkgs flake, where it does have access.
                builtins.isAttrs (overlay { } { });
            })
          output);
      };

      nixosConfigurationsSchema = {
        version = 1;
        doc = ''
          The `nixosConfigurations` flake output defines [NixOS system configurations](https://nixos.org/manual/nixos/stable/#ch-configuration).
        '';
        inventory = output: self.lib.mkChildren (builtins.mapAttrs
          (configName: machine:
            {
              what = "NixOS configuration";
              derivation = machine.config.system.build.toplevel;
            })
          output);
      };

      nixosModulesSchema = {
        version = 1;
        doc = ''
          The `nixosModules` flake output defines importable [NixOS modules](https://nixos.org/manual/nixos/stable/#sec-writing-modules).
        '';
        inventory = output: self.lib.mkChildren (builtins.mapAttrs
          (moduleName: module:
            {
              what = "NixOS module";
            })
          output);
      };

      homeManagerModulesSchema = {
        version = 1;
        doc = ''
          The `homeManagerModules` flake output defines [Home Manager configurations](https://github.com/nix-community/home-manager).
        '';
        inventory = output: self.lib.mkChildren (builtins.mapAttrs
          (moduleName: module:
            {
              what = "Home Manager module";
            })
          output);
      };

      homeConfigurationsSchema = {
        version = 1;
        doc = ''
          The `homeConfigurations` flake output defines [Home Manager configurations](https://github.com/nix-community/home-manager).
        '';
        inventory = output: mkChildren (builtins.mapAttrs
          (configName: host:
            {
              what = "home-manager configuration";
              derivation = host.activationPackage;
            })
          output);
      };

      darwinConfigurationsSchema = {
        version = 1;
        doc = ''
          The `darwinConfigurations` flake output defines [nix-darwin system configurations](https://github.com/LnL7/nix-darwin).
        '';
        inventory = output: mkChildren (builtins.mapAttrs
          (configName: machine:
            {
              what = "nix-darwin configuration";
              derivation = machine.config.system.build.toplevel;
            })
          output);
      };

      mkChildren = children: { inherit children; };
    in

    {
      # Helper functions
      lib = {
        try = e: default:
          let res = builtins.tryEval e;
          in if res.success then res.value else default;

        mkChildren = children: { inherit children; };

        derivationsInventory = what: isFlakeCheck: output: self.lib.mkChildren (
          builtins.mapAttrs
            (systemType: packagesForSystem:
              {
                forSystems = [ systemType ];
                children = builtins.mapAttrs
                  (packageName: package:
                    {
                      forSystems = [ systemType ];
                      shortDescription = package.meta.description or "";
                      derivation = package;
                      evalChecks.isDerivation = checkDerivation package;
                      inherit what;
                      isFlakeCheck = isFlakeCheck;
                    })
                  packagesForSystem;
              })
            output);
      };

      # FIXME: distinguish between available and active schemas?
      schemas.apps = appsSchema;
      schemas.schemas = schemasSchema;
      schemas.packages = packagesSchema;
      schemas.legacyPackages = legacyPackagesSchema;
      schemas.checks = checksSchema;
      schemas.devShells = devShellsSchema;
      schemas.hydraJobs = hydraJobsSchema;
      schemas.lib = libSchema;
      schemas.overlays = overlaysSchema;
      schemas.nixosConfigurations = nixosConfigurationsSchema;
      schemas.nixosModules = nixosModulesSchema;
      schemas.homeConfigurations = homeConfigurationsSchema;
      schemas.homeManagerModules = homeManagerModulesSchema;
      schemas.darwinConfigurations = darwinConfigurationsSchema;
    };
}
