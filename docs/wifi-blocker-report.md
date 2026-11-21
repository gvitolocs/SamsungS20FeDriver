# Report blocker Wi-Fi — Samsung Galaxy S20 FE (r8s, SM-G780F), Debian + mainline 6.12

Data analisi: 2026-04-13, 20:11–20:23 UTC (finestra monitor 13 min, orologio del telefono — su nezopt è 2026-11-21) — analisi kernel su nezopt contemporanea.
Kernel sul telefono: `6.12.0-rc5-next-20241104-r8s+` (build 2026-11-20). Host: `r8s`, IP 192.168.1.24.

---

## 1. Stato stabilità attuale: STABILE

Il conflitto tra i due wpa_supplicant (istanza dbus di NetworkManager + istanza manuale di
`r8s-wifi.service`) è risolto e la connessione è stabile.

Verifiche fatte nella finestra 20:11–20:23 UTC:

| Verifica | Risultato |
|---|---|
| Monitor loop 1 (49 campioni, 15s) | 49/49 sempre associati, stesso BSSID `14:14:59:fa:b2:9c`, nessun evento |
| Monitor loop 2 (38 campioni, 15s) | 38/38 `GW_OK` (TCP handshake verso 192.168.1.1:53), 0 fallimenti, sempre 1 station |
| Ping dal Mac (10s, 80 tentativi) | 0 timeout / 0 unreachable |
| `journalctl -b \| grep -ci deauth` | **0** deauth nel boot corrente |
| dmesg --follow dall'associazione | solo auth/assoc/Limiting TX power, nessun warning |
| Station stats (`iw dev wlp1s0 station dump`) | beacon loss 0, tx failed 0, tx retries 41, beacon signal avg **-31 dBm** (segnale eccellente) |
| Crash firmware / SSR | nessuno mai nel journal |
| Sessione attiva | associato dal 20:07:51 (uptime 1786s), >15 min continui in monitor + resto del boot |

### Il pattern vecchio (boot precedenti): deauth ogni ~413 s

I boot PRECEDENTI mostrano il pattern documentato, esempi:

```
Apr 13 19:46:00 r8s kernel: wlp1s0: deauthenticating from 14:14:59:fa:b2:9c by local choice (Reason: 3=DEAUTH_LEAVING)
Apr 13 19:52:53 r8s kernel: wlp1s0: deauthenticating from 92:2d:13:92:ad:8c by local choice (Reason: 3=DEAUTH_LEAVING)
Apr 13 19:59:46 r8s kernel: wlp1s0: deauthenticating from 14:14:59:fa:b2:9c by local choice (Reason: 3=DEAUTH_LEAVING)
Apr 13 20:06:39 r8s kernel: wlp1s0: deauthenticating from 92:2d:13:92:ad:8c by local choice (Reason: 3=DEAUTH_LEAVING)
```

Intervallo costante ~413–415 s, "by local choice" (decisione LOCALE, non dell'AP), alternanza tra
i due BSSID dell'AP Vodafone (`14:14:59:fa:b2:9c` e `92:2d|a0:2d:13:92:ad:8c`). Firma tipica del
doppio supplicant: le due istanze si contendono l'associazione e ognuna deautentica quella dell'altra.
Nel boot corrente (con `r8s-wifi.service` disabled e una sola istanza wpa_supplicant, PID 366) il
pattern è **sparito**: zero deauth.

NOTA cronologia: il telefono non ha RTC affidabile — `journalctl --list-boots` mostra orari di start
sovrapposti tra i boot (tutti "19:38:05"). Per filtrare gli eventi usare SEMPRE `journalctl -b`
(boot corrente), non i timestamp assoluti tra boot diversi.

Nota falsi allarmi: `ping` NON è installato sul telefono (`iputils-ping` assente). Il monitor 1
riportava `GW_FAIL` solo perché il binario manca (rc=127). Il check reale (TCP) è 38/38 OK.
→ Raccomandazione 3.

Stato config attuale (verificato, non toccato):
- `r8s-wifi.service`: `disabled` + `inactive (dead)`.
- Un solo wpa_supplicant: `/usr/sbin/wpa_supplicant -u -s -O DIR=/run/wpa_supplicant GROUP=netdev` (dbus, v2.10).
- NM profilo `r8s-home`: SSID Vodafone-68451232, infrastructure, powersave=default, IPv4 manual 192.168.1.24/24, autoconnect=yes, attivo.
- `10-r8s-unmanaged-usb.conf`: usb0 (canale di recovery gadget) correttamente unmanaged.

---

## 2. Confronto stack Wi-Fi: kernel stock Samsung vs mainline

### Stock (samsung-stock-kernel, 4.19.325, branch lineage-24.0)

Driver: **qcacld-3.0 completo** (non ath11k), in
`drivers/net/wireless/qualcomm/qca6390/{fw-api, qca-wifi-host-cmn, qcacld-3.0}`.
Config r8s.config:

```
CONFIG_QCA_CLD_WLAN=y
CONFIG_CNSS2=y
CONFIG_CNSS2_QMI=y
CONFIG_CNSS_QCA6390=y
CONFIG_CNSS_GENL=y
CONFIG_WCNSS_MEM_PRE_ALLOC=y
```

Config driver (`configs/qca6390_defconfig`): `CONFIG_BUS_AUTO_SUSPEND=y` (runtime PM del bus
PCIe gestito), `CONFIG_WLAN_FEATURE_DFS_OFFLOAD=y`, `CONFIG_WLAN_FEATURE_11AX=y`.

Punti chiave della gestione stock:

1. **Glue CNSS2** (`drivers/net/wireless/cnss2/`): piattaforma dedicata QCA6390, con:
   - programmazione dei registri PARF L1SS specifici QCA6390 (`QCA6390_PCIE_PCIE_PARF_L1SS_*` in pci.c:242-251);
   - coordinazione esplicita con il controller PCIe Exynos: `exynos_pcie_l1ss_ctrl(0/1, PCIE_L1SS_CTRL_WIFI)` attorno a suspend/resume (pci.c:2777, 2846) — l'L1SS del link è abilitato/disabilitato in funzione dello stato di alimentazione WLAN;
   - gestione MHI M2 attiva: `MHI_M2_TIMEOUT_MS` con default **25 ms** (`CNSS_MHI_M2_TIMEOUT_DEFAULT`, main.c:49, 2452; assegnato a `mhi_ctrl->m2_timeout_ms`, pci.c:1345);
   - recovery firmware SSR robusta (qcacld + cnss devcoredump).
2. DFS in offload al firmware.
3. Power save STA (BMPS) abilitato di default come su Android (batteria).

### Mainline (linux 6.12.0-rc5-next-20241104, ath11k vanilla)

Driver: **ath11k + ath11k_pci** vanilla wireless-next — `git log -- drivers/net/wireless/ath/ath11k/`
non mostra patch del port (solo merge upstream); il port r8s interviene altrove (DTS, SoC, BT).
Config telefono: `CONFIG_ATH11K=m`, `CONFIG_ATH11K_PCI=m`, `# ATH11K_AHB is not set`,
`# ATH11K_DEBUG is not set`, debugfs ath11k non abilitato.
Firmware: **embedded nel kernel** via
`CONFIG_EXTRA_FIRMWARE="ath11k/QCA6390/hw2.0/amss.bin ath11k/QCA6390/hw2.0/m3.bin ath11k/QCA6390/hw2.0/board-2.bin"`
(sorgenti in `~/projects/samsung-mainline/linux/firmware/ath11k/QCA6390/hw2.0/`, set linux-firmware:
fw_version 0x10121492, build 2021-11-04).

Punti chiave mainline e differenze rilevanti per la stabilità:

| Aspetto | Stock qcacld-3.0 | Mainline ath11k 6.12 | Impatto stabilità |
|---|---|---|---|
| ASPM / L1SS | coordinato attivamente (PARF L1SS + exynos_pcie_l1ss_ctrl, M2 con timeout 25 ms) | **disabilitato**: 1 solo vettore MSI → `ATH11K_FLAG_MULTI_MSI_VECTORS` non settato → ASPM mai restaurato dopo il download fw (`pci.c:685-691`: "leaving PCI ASPM disabled to avoid MHI M2 problems"; commento in pci.c: "MHI register reading in M2 causes system hang") | mainline = scelta conservativa SICURA: elimina la classe di hang M2; costo: consumo marginale |
| Host PCIe Exynos | driver samsung con hook L1SS dedicati | `drivers/pci/controller/dwc/pci-exynos.c` mainline: nessuna gestione L1SS/ASPM (grep vuoto) | nessun conflitto: il driver device azzera i bit L0s/L1, policy kernel `default` resta neutrale |
| Runtime PM | BUS_AUTO_SUSPEND (M2/M3 ciclici) | nessun auto-suspend: `/sys/.../device/power/runtime_status=active`, `runtime_suspended_time=0` | vantaggio per server 24/7: i path sospensione/ripresa (i più fragili su QCA6390) non vengono mai percorsi |
| Power save STA | BMPS on | dynamic PS on via WMI (`ath11k_mac_vif_setup_ps`), guidato da wpa_supplicant (`iw get power_save = on`) | con DTIM 1 sul router l'impatto è minimo; per server conviene PS off (raccomandazione 2) |
| Recovery fw | SSR + devcoredump cnss | `ath11k_core_reset` (mai esercitata: 0 crash registrati) | ok, ma non testata su questa scheda |
| Firmware | fw vendor Samsung via vendor partition | linux-firmware 2021-11-04 embedded | funziona; iterazione fw più lenta (richiede rebuild kernel) |
| DFS | offload fw | software/fw senza offload; il telefono è su **canale 52 (DFS)** | rischio stabilità residuo (sezione 3) |

Conclusione confronto: per uso **server 24/7** la configurazione mainline attuale è nella
configurazione più robusta possibile: ASPM/L1SS completamente disattivato sul link WLAN, runtime PM
mai esercitato, un solo supplicant. I problemi noti QCA6390 su mainline (hang M2, crash fw in
transizioni di stato) sono evitati per costruzione, non mitigati.

---

## 3. Rischi residui

1. **Canale DFS 52 (5260 MHz)**: l'AP Vodafone è su un canale DFS ETSI. Ogni (ri)associazione dopo
   evento radar / cambio canale dell'AP richiede CAC; il dmesg mostra anche
   `wlp1s0: regulatory prevented using AP config, downgraded` al momento dell'associazione.
2. **Regolamentazione incoerente**: `iw reg get` → global = `country 00` (DFS-UNSET) mentre la phy
   è self-managed con `country CH` (DFS-ETSI) riportata dal firmware. Non bloccante (la connessione
   funziona), ma ogni assoc si prende il "downgraded".
3. **Ping assente**: rende il monitoraggio manuale sul telefono scomodo.
4. **Debug osservabilità limitata**: `CONFIG_ATH11K_DEBUGFS` non abilitato → nessuna statistica
   per-peer, nessun fw crash dump leggibile via debugfs se mai servisse.

---

## 4. Raccomandazioni concrete (comandi esatti)

Ordine di priorità per rendere il Wi-Fi "server 24/7".

### R1 — Fissare l'AP su canale non-DFS (lato router, la più importante)

Nel pannello Vodafone Station, Wi-Fi 5 GHz: fissare canale **36 / 40 / 44 / 48** (80 MHz), mai
"auto". Elimina CAC, eventi radar e il downgrade regulatory; rende il riassociazione dopo riavvio
del telefono istantanea. Non richiede modifiche sul telefono.

### R2 — Disattivare il power save Wi-Fi (uso server)

Attuale: `iw dev wlp1s0 get power_save` = **on** (profilo NM `802-11-wireless.powersave=default`).

```bash
nmcli connection modify r8s-home 802-11-wireless.powersave 2   # 2 = disable
nmcli device reapply wlp1s0
iw dev wlp1s0 get power_save        # atteso: "Power save: off"
```

Motivazione: con PS on il firmware entra in doze tra i beacon; su alcuni AP/firmware QCA produce
micro-lag e, in casi rari, skip beacon. Con DTIM=1 su questo AP il risparmio è comunque minimo.
Il telefono è alimentato come server → nessun costo reale. Non l'ho applicata: modifica config NM,
da confermare.

### R3 — Installare iputils-ping

```bash
apt install -y iputils-ping
```

### R4 — Guardia anti-regressione doppio supplicant

```bash
systemctl is-enabled r8s-wifi.service   # atteso: disabled
ps aux | grep -c "[w]pa_supplicant"     # atteso: 1
journalctl -b -k | grep -i deauth       # atteso: vuoto
```

Non riattivare mai `r8s-wifi.service`; se serve un giorno un provisioning senza NM, usare
`wpa_supplicant` via `wpa_cli` su una unit a profilo singolo, non in parallelo a NM.

### R5 — Evitare che il sistema sospenda (il telefono resta attivo)

I path suspend/resume sono i più fragili di ath11k+QCA6390 (MHI M3). Verificare che non ci sia
sleep configurato:

```bash
systemctl status sleep.target suspend.target   # atteso: masked o inactive
systemctl mask sleep.target suspend.target     # solo se non già mascherati
```

### R6 — Monitoraggio continuo (senza modifiche)

```bash
# watch rapido live
journalctl -b -k -f | grep -iE "wlp1s0|ath11k|mhi" &

# report giornaliero (cron/timer):
journalctl -b -k | grep -icE "deauth|disconnect|firmware.*crash|beacon loss"
iw dev wlp1s0 station dump | grep -E "tx failed|beacon loss|signal"
iw dev wlp1s0 link | grep -E "Connected|freq"
```

Riferimento di confronto di oggi: 0 deauth, beacon loss 0, tx failed 0.

### R7 — Prossimo rebuild kernel (opzionale, osservabilità)

```bash
CONFIG_ATH11K_DEBUGFS=y
CONFIG_ATH11K_DEBUG=y          # se serve trace
CONFIG_CFG80211_DEBUGFS=y
```

e magari firmware in `/lib/firmware/ath11k/QCA6390/hw2.0/` (invece di EXTRA_FIRMWARE embedded) per
poter provare fw più recenti senza rebuild. Non necessario per la stabilità attuale.

### R8 — Non abilitare ASPM sul link WLAN

Non usare `pcie_aspm.policy=performance/powersave` mirato al re-enable L1 del device WLAN: il
driver mainline lo disabilita perché la lettura dei registri MHI in M2 con vettore MSI singolo
manda in hang il sistema (pci.c). Per il risparmio energetico non c'è nulla da guadagnare qui (device
sempre attivo).

---

## 5. Verdetto

- Il blocker originale (deauth ogni ~413 s) era **interamente causato dal doppio wpa_supplicant**;
  risolto e confermato: 13 min di monitor pulito, 0 deauth nel boot corrente, 0 perdite di
  connettività verso gateway e WAN, segnale eccellente (-31 dBm).
- La configurazione mainline attuale (ath11k vanilla, ASPM disabilitato dal driver, runtime PM non
  esercitato, fw embedded, NM a supplicant singolo) è la più robusta possibile per un server 24/7.
- Restano due rischi ambientali, non software: canale DFS 52 dell'AP (R1) e power save STA on (R2).
