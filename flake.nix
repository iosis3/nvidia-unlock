{
  description = "NVIDIA driver patches (P2P across generations, NVENC, NvFBC) and the GA10x/AD10x issue-rate unlock, as a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f (pkgsFor system));

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            nvidia.acceptLicense = true;
          };
          overlays = [ self.overlays.default ];
        };

      # the nixpkgs branches with open kernel modules that the checks follow
      checkedBranches = [
        "legacy_580"
        "production"
        "beta"
        "new_feature"
      ];
    in
    {
      nixosModules.default = ./nixos.nix;

      overlays.default = import ./overlay.nix;

      lib.patchNvidiaDriver =
        pkgs: features: nvidiaPackage:
        import ./pkgs/nvidia-patches/package.nix (
          features
          // {
            inherit (pkgs) lib;
            inherit nvidiaPackage;
          }
        );

      packages = forAllSystems (
        pkgs:
        let
          inherit (pkgs.linuxPackages) nvidiaPackages;
          p2pPatches = import ./pkgs/nvidia-p2p;
          p2pReleases = lib.sort lib.versionOlder (lib.attrNames p2pPatches);

          missingDrivers = lib.filter (driver: !(p2pPatches ? ${driver.version})) (
            lib.unique (map (branch: nvidiaPackages.${branch}) checkedBranches)
          );
          portSource =
            version:
            let
              series = lib.versions.major version;
              older = lib.filter (
                release: lib.versions.major release == series && lib.versionOlder release version
              ) p2pReleases;
            in
            lib.last (if older != [ ] then older else p2pReleases);
        in
        {
          inherit (pkgs) gpu-unlock-firmware gpu-unlock-gsp;
          inherit (pkgs.linuxPackages) gpu-unlock;

          nvidia-patched =
            (self.lib.patchNvidiaDriver pkgs {
              p2p = p2pPatches ? ${nvidiaPackages.latest.version};
              mixedGeneration = p2pPatches.${nvidiaPackages.latest.version}.mixedGeneration or false;
              nvenc = true;
              nvfbc = true;
            } nvidiaPackages.latest).overrideAttrs
              (old: {
                passthru = old.passthru // {
                  updateScript = pkgs.writeShellApplication {
                    name = "nvidia-p2p-update";
                    runtimeInputs = [
                      pkgs.coreutils
                      pkgs.gnugrep
                      pkgs.gnused
                      pkgs.jq
                      pkgs.nix
                      pkgs.nixfmt
                    ];
                    text = builtins.readFile ./pkgs/nvidia-p2p/update.sh;
                  };
                  checkedReleases = map (branch: nvidiaPackages.${branch}.version) checkedBranches;
                  portSources = lib.listToAttrs (
                    map (driver: lib.nameValuePair driver.version (portSource driver.version)) missingDrivers
                  );
                  portedPatches = lib.listToAttrs (
                    map (
                      driver:
                      lib.nameValuePair driver.version (
                        pkgs.callPackage ./pkgs/nvidia-p2p/refresh-patches.nix {
                          inherit driver;
                          inherit (p2pPatches.${portSource driver.version}) patches;
                        }
                      )
                    ) missingDrivers
                  );
                };
              });
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
          inherit (pkgs.linuxPackages) nvidiaPackages;
          p2pPatches = import ./pkgs/nvidia-p2p;

          drivers = lib.unique (map (branch: nvidiaPackages.${branch}) checkedBranches);

          # NVENC and NvFBC must match every release of checkedBranches;
          # releases whose P2P kernel patches do mixed-generation P2P also need
          # the libcuda signatures.
          userspaceChecks = map (
            driver:
            lib.nameValuePair "userspace-${driver.version}" (
              pkgs.callPackage ./pkgs/nvidia-patches/userspace-check.nix {
                nvidiaPackage = driver;
                features = [
                  "nvenc"
                  "nvfbc"
                ]
                ++ lib.optional (p2pPatches.${driver.version}.mixedGeneration or false) "mixed-generation";
              }
            )
          ) drivers;

          # For every patched release a checked branch ships: the patches apply
          # without fuzz (`git am`; the check does not compare the re-created
          # patches with the committed ones) and the patched open kernel
          # modules build.
          p2pChecks = lib.concatMap (
            driver:
            lib.optionals (p2pPatches ? ${driver.version}) [
              (lib.nameValuePair "p2p-patches-${driver.version}" (
                pkgs.callPackage ./pkgs/nvidia-p2p/refresh-patches.nix {
                  inherit driver;
                  inherit (p2pPatches.${driver.version}) patches;
                }
              ))
              (lib.nameValuePair "p2p-open-${driver.version}"
                (self.lib.patchNvidiaDriver pkgs { p2p = true; } driver).open
              )
            ]
          ) drivers;
        in
        lib.listToAttrs (userspaceChecks ++ p2pChecks)
        // {
          inherit (packages) gpu-unlock gpu-unlock-firmware nvidia-patched;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
