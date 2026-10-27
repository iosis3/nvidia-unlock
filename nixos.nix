{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.nvidia;
  unlockCfg = cfg.issueRateUnlock;

  p2pCfg = cfg.patches.p2p;

  # a PCI address as `lspci -D` prints it
  pciAddress = "[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-7]";
  badPowerLimitKeys = lib.filter (card: builtins.match pciAddress card == null) (
    lib.attrNames cfg.powerLimits
  );

  # the open kernel module P2P patches, per driver release
  p2pPatches = import ./pkgs/nvidia-p2p;

  # hardware.nvidia.branch values whose driver has a P2P release matching
  # `pred`; not the datacenter (dc*) branches, which share some versions
  p2pBranches =
    pred:
    lib.attrNames (
      lib.filterAttrs (
        name: pkg:
        !lib.hasPrefix "dc" name && lib.isDerivation pkg && pred (p2pPatches.${pkg.version or ""} or null)
      ) config.boot.kernelPackages.nvidiaPackages
    );
  listOr = none: list: if list == [ ] then none else lib.concatStringsSep ", " list;

  # P2P only reaches a driver it has kernel patches for, mixed-generation P2P
  # only one whose patches do it; for any other the assertions below fail with
  # the branches that would work (package.nix would throw terser errors first).
  patchDriver =
    driver:
    let
      release = p2pPatches.${driver.version} or null;
      features = {
        p2p = p2pCfg.enable && release != null;
        mixedGeneration =
          p2pCfg.enable && p2pCfg.mixedGeneration && release != null && release.mixedGeneration;
        nvenc = cfg.patches.nvenc.enable;
        nvfbc = cfg.patches.nvfbc.enable;
      };
    in
    if lib.any lib.id (lib.attrValues features) then
      import ./pkgs/nvidia-patches/package.nix (
        features
        // {
          inherit lib;
          nvidiaPackage = driver;
        }
      )
    else
      driver;
in
{
  options.hardware.nvidia = {
    package = lib.mkOption {
      apply = patchDriver;
    };

    patches = {
      p2p.enable = lib.mkEnableOption ''
        peer-to-peer over PCIe BAR1 (and NVLink where present) on consumer GPUs:
        the open kernel module patches for the driver's release, which is all
        that P2P between GPUs of the same generation needs.  Needs
        {option}`hardware.nvidia.open`, Resizable BAR with a BAR1 covering the
        VRAM, and IOMMU passthrough for full bandwidth.

        The kernel patches exist per driver release: the driver that
        {option}`hardware.nvidia.branch` or {option}`hardware.nvidia.package`
        selects has to be one of them, otherwise evaluation fails and names the
        branches that would work
      '';
      p2p.mixedGeneration = lib.mkEnableOption ''
        P2P between GPUs of different generations, such as an RTX 3090 and an
        RTX 4090: the libcuda patch that lifts its peer-access policy, on top of
        {option}`hardware.nvidia.patches.p2p.enable`.  Only the kernel patches of
        some releases have the mixed-generation path; for any other release
        evaluation fails and names the branches that would work
      '';
      nvenc.enable = lib.mkEnableOption "removal of the NVENC concurrent session limit";
      nvfbc.enable = lib.mkEnableOption "NvFBC capture on consumer GPUs";
    };

    powerLimits = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      example = {
        "0000:01:00.0" = 350;
        "0000:03:00.0" = 230;
      };
      description = ''
        Board power limit in watts per card, by PCI address as `lspci -D` prints
        it, set with `nvidia-smi` once the driver is up.  The driver forgets a
        limit whenever it tears a card down, so this enables
        {option}`hardware.nvidia.nvidiaPersistenced`, which keeps the cards
        initialized.  The limits are set at boot, not again after suspend to RAM.
        With {option}`hardware.nvidia.issueRateUnlock` a card does about twice
        the work per clock, so under a limit it clocks down instead: the limit
        decides how much of the unlock turns into throughput.
      '';
    };

    issueRateUnlock = {
      enable = lib.mkEnableOption ''
        the full instruction issue rate on GA10x/AD10x consumer cards
        (Zagitta/gpu-unlock): a doctored SEC2 boot writes the SM speed selectors
        (`FEAT_OVR_SM_SPD`, `_1`) to full rate before the NVIDIA driver binds the
        card, roughly doubling FP16/BF16/TF32 tensor throughput per clock.  The
        module is loaded from the initrd and resets every targeted card once
      '';

      targets = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf (lib.types.strMatching pciAddress));
        default = null;
        example = [ "0000:01:00.0" ];
        description = ''
          PCI addresses of the cards to unlock, as `lspci -D` prints them, or
          `null` for every supported card.
        '';
      };

      resume = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to unlock the cards again after suspend to RAM, which powers them
          off.  Relies on the driver's kernel suspend notifiers
          (`NVreg_UseKernelSuspendNotifiers=1`, the default in current drivers).
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = config.boot.kernelPackages.callPackage ./pkgs/gpu-unlock/module.nix {
          gpu-unlock-firmware = unlockCfg.firmwarePackage;
        };
        defaultText = lib.literalMD "`gpu-unlock` built for {option}`boot.kernelPackages`";
        description = "The gpu-unlock kernel module.";
      };

      firmwarePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./pkgs/gpu-unlock/firmware.nix {
          gpu-unlock-gsp = pkgs.callPackage ./pkgs/gpu-unlock/gsp.nix { };
        };
        defaultText = lib.literalMD "`gpu-unlock-firmware` from nvidia-unlock";
        description = "The firmware the gpu-unlock module boots the SEC2 and GSP with.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf p2pCfg.enable {
      assertions = [
        {
          assertion = cfg.open == true;
          message = "hardware.nvidia.patches.p2p patches the open kernel modules; set hardware.nvidia.open = true.";
        }
        {
          assertion = p2pPatches ? ${cfg.package.version};
          message = ''
            hardware.nvidia.patches.p2p: no P2P kernel patches for NVIDIA ${cfg.package.version} (hardware.nvidia.branch = "${cfg.branch}").
            Patched releases: ${lib.concatStringsSep ", " (lib.attrNames p2pPatches)}; hardware.nvidia.branch values that select one: ${
              listOr "none in this nixpkgs" (p2pBranches (release: release != null))
            }.
          '';
        }
        {
          assertion =
            p2pCfg.mixedGeneration
            -> (p2pPatches.${cfg.package.version} or { mixedGeneration = true; }).mixedGeneration;
          message = ''
            hardware.nvidia.patches.p2p.mixedGeneration: the P2P kernel patches for NVIDIA ${cfg.package.version} (hardware.nvidia.branch = "${cfg.branch}") only do same-generation P2P.
            Releases with mixed-generation P2P: ${
              listOr "none" (lib.attrNames (lib.filterAttrs (_: release: release.mixedGeneration) p2pPatches))
            }; hardware.nvidia.branch values that select one: ${
              listOr "none in this nixpkgs" (p2pBranches (release: release != null && release.mixedGeneration))
            }.
          '';
        }
      ];
    })

    (lib.mkIf p2pCfg.mixedGeneration {
      assertions = [
        {
          assertion = p2pCfg.enable;
          message = "hardware.nvidia.patches.p2p.mixedGeneration needs hardware.nvidia.patches.p2p.enable.";
        }
      ];
    })

    # The unlock has to run before the NVIDIA driver probes the card, and once
    # nvidia has bound it the module skips the card (it refuses to reset a GPU
    # that is in use).  The initrd is the only place that is guaranteed: stage 2
    # loads both from the same systemd-modules-load run, so `gpu_unlock` would
    # race `nvidia` and lose.  The firmware follows the module: it is declared
    # with MODULE_FIRMWARE(), so makeModulesClosure copies it into the initrd
    # from hardware.firmware, and modprobe reads the options below from
    # /etc/modprobe.d/nixos.conf, which stage 1 carries as well.
    #
    # gpu_unlock's init returns only once every card is unlocked.  In the initrd
    # it is loaded from its own modules-load.d file, 00-gpu-unlock.conf, which
    # systemd-modules-load handles before nixos.conf (files in name order, one
    # module after another), so NVIDIA modules in boot.initrd.kernelModules
    # (early KMS) load once the cards are done.  boot.initrd.kernelModules
    # itself is a set and has no order.  A `softdep nvidia pre:` is no way out:
    # kmod honours only the first `softdep nvidia` line, and nixpkgs' nvidia
    # module has one.  Only udev's coldplug, which runs alongside and loads
    # modules by PCI alias, could bind a card first: a blacklist in the
    # initrd's own modprobe.d stops that, without touching stage 2 or explicit
    # loads by name.
    (lib.mkIf unlockCfg.enable {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.isx86_64;
          message = "hardware.nvidia.issueRateUnlock is only built for x86_64-linux.";
        }
        {
          # nixpkgs 26.11 removed the scripted initrd, and the option with it
          assertion = lib.versionAtLeast lib.trivial.release "26.11" || config.boot.initrd.systemd.enable;
          message = "hardware.nvidia.issueRateUnlock needs the systemd initrd (boot.initrd.systemd.enable).";
        }
      ];

      hardware.firmware = [ unlockCfg.firmwarePackage ];
      boot.extraModulePackages = [ unlockCfg.package ];
      boot.initrd.availableKernelModules = [ "gpu_unlock" ];
      boot.initrd.systemd.contents."/etc/modules-load.d/00-gpu-unlock.conf".text = ''
        gpu_unlock
      '';
      boot.initrd.systemd.contents."/etc/modprobe.d/gpu-unlock.conf".text = ''
        blacklist nvidia
        blacklist nvidia_modeset
        blacklist nvidia_drm
        blacklist nvidia_uvm
        blacklist nvidia_peermem
      '';
      boot.extraModprobeConfig = ''
        options gpu_unlock targets=${
          if unlockCfg.targets == null then "all" else lib.concatStringsSep "," unlockCfg.targets
        } resume=${if unlockCfg.resume then "1" else "0"}
      '';
    })

    (lib.mkIf (cfg.powerLimits != { }) {
      hardware.nvidia.nvidiaPersistenced = lib.mkDefault true;

      assertions = [
        {
          assertion = badPowerLimitKeys == [ ];
          message = "hardware.nvidia.powerLimits: keys are PCI addresses as `lspci -D` prints them (0000:01:00.0), not: ${lib.concatStringsSep ", " badPowerLimitKeys}";
        }
        {
          assertion = cfg.nvidiaPersistenced;
          message = "hardware.nvidia.powerLimits needs hardware.nvidia.nvidiaPersistenced: without it the driver resets a limit whenever a card goes idle.";
        }
      ];

      systemd.services.nvidia-power-limits = {
        description = "NVIDIA GPU power limits";
        wantedBy = [ "multi-user.target" ];
        wants = [ "nvidia-persistenced.service" ];
        after = [ "nvidia-persistenced.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.mapAttrsToList (
            card: watts: "${lib.getExe' cfg.package.bin "nvidia-smi"} -i ${card} -pl ${toString watts}"
          ) cfg.powerLimits;
        };
      };
    })
  ];
}
