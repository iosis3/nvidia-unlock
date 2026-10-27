# nvidia-unlock

A NixOS flake and module that adds optional features to `hardware.nvidia`:

| option | purpose |
|---|---|
| `patches.p2p.enable` | BAR1/NVLink P2P for supported open-driver releases |
| `patches.p2p.mixedGeneration` | P2P between different GPU generations |
| `patches.nvenc.enable` | Remove the consumer NVENC session limit |
| `patches.nvfbc.enable` | Enable NvFBC capture on consumer GPUs |
| `issueRateUnlock.enable` | Unlock the full instruction issue rate on supported GPUs |
| `powerLimits` | Set a board power limit per GPU |

All features are opt-in. The patches are vendored in this repository; builds
do not download or execute patching code from an unpinned upstream source.

## Usage

Add the flake as an input, then import its module:

```nix
inputs.nvidia-unlock = {
  url = "github:iosis3/nvidia-unlock";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
{
  imports = [ inputs.nvidia-unlock.nixosModules.default ];

  hardware.nvidia = {
    open = true;

    patches = {
      p2p.enable = true;
      # Enables P2P between different GPU generations on supported releases.
      p2p.mixedGeneration = true;
      nvenc.enable = true;
      nvfbc.enable = true;
    };

    issueRateUnlock.enable = true;

    # PCI addresses are the values printed by `lspci -D`.
    powerLimits = {
      "0000:01:00.0" = 350;
    };
  };
}
```

The module applies patches to the driver selected by
`hardware.nvidia.branch` or `hardware.nvidia.package`; it never silently
selects a different driver. A P2P feature whose kernel or userspace patches do
not support the selected release fails evaluation or the build.

The module is self-contained, so no overlay is needed. For configurations that
do not use the module, the same driver patching is available through the flake
library:

```nix
hardware.nvidia.package = inputs.nvidia-unlock.lib.patchNvidiaDriver pkgs {
  p2p = true;
  nvenc = true;
} config.boot.kernelPackages.nvidiaPackages.latest;
```

## P2P and driver releases

Same-generation P2P needs the open kernel module patches and a driver release
listed in `pkgs/nvidia-p2p/default.nix`. It also needs suitable firmware
settings, including Resizable BAR and an aperture covering the VRAM. IOMMU
passthrough is normally needed for full P2P bandwidth.

Mixed-generation P2P additionally needs the `libcuda` userspace patch, enabled
with `patches.p2p.mixedGeneration`, and a release whose kernel patches include
the mixed-generation path. The selected driver must still be the one provided
by nixpkgs; this flake does not replace it with a nearby release.

The NVENC, NvFBC, and mixed-generation userspace patches use byte signatures.
Each signature must match exactly once, and a mismatch stops the build rather
than producing a partially patched driver.

## Issue-rate unlock

The issue-rate unlock is a separate kernel module and firmware package. It
runs from the initrd before the NVIDIA driver probes supported GA10x/AD10x
cards. The module can be limited to particular cards and can be run again
after suspend:

```nix
hardware.nvidia.issueRateUnlock = {
  enable = true;
  targets = [ "<PCI address>" ]; # null (the default) means every supported card
  resume = true;
};
```

Unlocking resets each targeted card. A display can therefore remain blank
during boot until the NVIDIA display driver loads. The module is intended for
the systemd initrd on x86_64 systems; unsupported platforms are rejected at
evaluation time.

An unlocked card does more work per clock and may consequently clock down
under a power limit. `powerLimits` is applied at boot and enables NVIDIA
persistence so the limit survives driver teardown.

## Upstream projects

- [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules/)
  provides the per-release open kernel module P2P patches.
- [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) provides the
  issue-rate unlock module and firmware work.
- [keylase/nvidia-patch](https://github.com/keylase/nvidia-patch) provides the
  basis for the NVENC and NvFBC patches.
