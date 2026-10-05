# Baselines

The thesis compares CMU Sphinx acoustic-model training on the 6-node
Raspberry Pi CM4 cluster (Debian 13 arm64, modern gcc/perl/python, Slurm)
with the legacy reference: RHEL 6.x on UNH's Dell x86_64 servers (Torque
era). A single comparison between those two mixes two causes: the operating
system and toolchain changed, and the hardware changed. The baseline
environments on these pages exist to separate them.

## The 2x2 design

|                               | Legacy hardware (Dell x86_64)   | New hardware                                      |
| ----------------------------- | ------------------------------- | ------------------------------------------------- |
| **Legacy OS** (RHEL 6.x era)  | The UNH Dells, as they run now  | CentOS 6.10 VM ([details](rhel6-centos6.md))      |
| **Modern OS** (Debian 13 era) | Debian 13 on a Dell, if available | The Pi CM4 cluster                              |

Reading the table:

- **Row effect (OS and toolchain).** Same hardware, different OS: gcc 4.4.7,
  glibc 2.12 and perl 5.10 against a current gcc, glibc and perl. This
  is where differences in features, models and WER would come from if
  compilers or libraries changed numerical results.
- **Column effect (hardware).** Same OS, different hardware: core count,
  memory, storage, interconnect and instruction set.
- **Interaction.** Whether the toolchain matters more on one platform than
  on the other.

## What each cell can measure

Accuracy results (identical features, model parameters, WER/SER) are valid
from every cell. Timing results are valid only where the code runs on real
hardware or under hardware-assisted virtualization:

| Cell | Accuracy | Timing |
| --- | --- | --- |
| Legacy OS, legacy hardware (Dells) | yes | yes |
| Legacy OS, new hardware (CentOS 6.10 VM, QEMU TCG on Apple Silicon) | yes | **no** |
| Legacy OS, new hardware (same VM under KVM on an x86_64 host) | yes | yes |
| Modern OS, new hardware (Pi cluster) | yes | yes |

The CentOS 6.10 VM cannot use hardware acceleration on the M4 Max because
RHEL and CentOS 6 have no aarch64 build: every x86_64 instruction is
emulated. Its scripts take `ACCEL=kvm` so the same VM can produce valid
timings on an x86_64 Linux host.

## Pages

- [CentOS 6.10 legacy baseline VM](rhel6-centos6.md): why CentOS 6.10, how
  to build and run it, the security posture, and the measured toolchain.
