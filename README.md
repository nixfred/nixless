<p align="center">
  <img src="assets/nixless-banner.svg" alt="Nixless" width="720">
</p>

<p align="center">
  <img alt="visibility: public" src="https://img.shields.io/badge/visibility-public-0c9793?style=flat-square&labelColor=070707">
  <img alt="license: TBD" src="https://img.shields.io/badge/license-TBD-52ca9a?style=flat-square&labelColor=070707">
  <img alt="status: exploration" src="https://img.shields.io/badge/status-exploration-89e0b7?style=flat-square&labelColor=070707">
</p>

## What this is

Nixless is Fred's operating-system exploration: **model-as-appliance VMs** on hex (his Proxmox box).
A VM whose whole job is to be the model, with nothing else on it.

No OS, kernel or inference code exists yet. Ideas come later.

## Design

- [DESIGN.md](DESIGN.md): the PRD and design.

Nixless is written from scratch in Zig and assembly, from the firmware up.

Always bootable: every commit on main must produce an ISO that boots on hex in Proxmox (SeaBIOS and OVMF) and reaches its serial boot log; see [DESIGN.md](DESIGN.md) section 0.

Good neighbor: idle cores halt and wake on interrupts, so an idle Nixless VM uses near-zero host CPU on hex; see [DESIGN.md](DESIGN.md) section 0b.

## Ideas

Headings only for now. Nothing here is implemented.

### Appliance shape

### Boot and kernel

### Inference

### Running on hex

### Open questions

## License

TBD.
