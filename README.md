# SamsungS20FeDriver — S20 FE (r8s) Debian native + formal verification

Galaxy S20 FE **SM-G780F (r8s, Exynos 990)** converted to **native Debian 13** with a
formally modelled charging policy.

## What lives here

| Path | Content |
|---|---|
| `charge.tla` + `charge.cfg` | TLA+ model of the charging state machine (MAX77705 CNFG_00 MODE, deployed charge-watch v2 policy, the OTG hardware flaw) |
| `.github/workflows/tlc.yml` | TLC model checker in CI — 14 GB heap, runs on every branch push |
| `patches/r8s-kernel-series.patch` | The kernel series deployed on the phone (charge_behaviour via CNFG_00 MODE + Exynos ADC v3 driver + DTS) |
| `docs/` | Wi-Fi stability report (0 deauth after the single-supplicant fix), flash/recovery runbook |

## Branches = system variants, TLC in CI per branch

| Branch | Modelled variant | Expected TLC verdict |
|---|---|---|
| `main` | **Deployed system** — OTG detach writes mode 0x5 unconditionally (review finding) | **Safety violation found** (counterexample: OTG detach during inhibit at hot temp) |
| `fix/otg-inhibit-respect` | OTG detach respects the watchdog inhibit | All safety properties PASS |
| `stock-policy-full` | + swelling & JEITA modelling (stock parity) | All safety properties PASS |

## Deployed on the phone

- Debian 13 native, mainline 6.12 + patches (see `patches/`)
- Charge policy: `charge_behaviour` (CNFG_00 MODE 0x5/0x4) + thermal watchdog (stop ≥50 °C, resume ≤48 °C) with **live battery NTC** via the ported Exynos ADC v3 driver
- Wi-Fi: single supplicant (NetworkManager), static IP, 0 deauths since fix (see `docs/`)
- USB management link: RNDIS @37 MB/s with persistent auto-restore (both sides)

## Verified numbers (nov 2026)

- Battery NTC live: raw 1711 → **32,7 °C** (stock table interpolation)
- Inhibit electrically verified: charging current 328 → **3 mA**
- Benchmark (Qwen3-1.7B Q4_K_M, 4T): **11,74 t/s gen / 42,35 t/s prompt**
