# Action ↔ Reaction — UL ↔ DL

**UL→DL Capture-Offset:** `-1.222 s`

**Anker-Paar:** UL #0 t=11.132 `01 41 7C 8F 01 12` ↔ DL #873 dl_t=12.354 MM→→ D-LOC-UPD-ACCEPT

**Suchfenster:** ±3.0 s für DL-Signaling-Reaktionen, ±0.2 s für AACH-Grants.

**DL-Zeit:** TDMA-Slot 14.167 ms × (MN,FN,TN) Slot-Index (kein Drift gegenüber idx-basierter Schätzung).

---

## UL #0  t=11.132s  CRC=OK  `01 41 7C 8F 01 12`

**AACH-Kontext (±0.2 s):**

- DL #873 dl_t=12.354s (Δ=+0 ms) TN1 FN09 MN30 AACH `DL/UL-Assign` · DL=Unalloc UL=Unalloc CC=9 f1=0 f2=9 (dist=0)
- DL #874 dl_t=12.368s (Δ=+14 ms) TN2 FN09 MN30 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #870 dl_t=12.311s (Δ=-43 ms) TN2 FN08 MN30 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #873 dl_t=12.354s (Δ=+0 ms) TN1 FN09 MN30 · MAC: MAC-RESOURCE (SCH/F) addr=SSI ID=2633617 LI=21 · LLC: BL-ADATA NR=0 NS=0 · MM→→ D-LOC-UPD-ACCEPT

## UL #1  t=11.182s  CRC=OK  `D4 1C 3C 02 40 50`

**AACH-Kontext (±0.2 s):**

- DL #877 dl_t=12.410s (Δ=+7 ms) TN1 FN10 MN30 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #874 dl_t=12.368s (Δ=-36 ms) TN2 FN09 MN30 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #873 dl_t=12.354s (Δ=-50 ms) TN1 FN09 MN30 AACH `DL/UL-Assign` · DL=Unalloc UL=Unalloc CC=9 f1=0 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #873 dl_t=12.354s (Δ=-50 ms) TN1 FN09 MN30 · MAC: MAC-RESOURCE (SCH/F) addr=SSI ID=2633617 LI=21 · LLC: BL-ADATA NR=0 NS=0 · MM→→ D-LOC-UPD-ACCEPT

## UL #2  t=11.239s  CRC=OK  `41 41 7C 8C 63 40`

**AACH-Kontext (±0.2 s):**

- DL #881 dl_t=12.467s (Δ=+6 ms) TN1 FN11 MN30 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #877 dl_t=12.410s (Δ=-50 ms) TN1 FN10 MN30 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #885 dl_t=12.524s (Δ=+63 ms) TN1 FN12 MN30 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #873 dl_t=12.354s (Δ=-107 ms) TN1 FN09 MN30 · MAC: MAC-RESOURCE (SCH/F) addr=SSI ID=2633617 LI=21 · LLC: BL-ADATA NR=0 NS=0 · MM→→ D-LOC-UPD-ACCEPT

## UL #3  t=15.722s  CRC=OK  `41 41 7C 88 68 E0`

**AACH-Kontext (±0.2 s):**

- DL #1197 dl_t=16.944s (Δ=+0 ms) TN1 FN18 MN34 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1198 dl_t=16.958s (Δ=+14 ms) TN2 FN18 MN34 AACH `DL/UL-Assign` · DL=Unalloc UL=Random CC=0 f1=1 f2=0 (dist=0)
- DL #1193 dl_t=16.887s (Δ=-57 ms) TN1 FN17 MN34 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1245 dl_t=17.624s (Δ=+680 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=+737 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1253 dl_t=17.737s (Δ=+793 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #4  t=16.459s  CRC=OK  `41 41 7C 88 68 E0`

**AACH-Kontext (±0.2 s):**

- DL #1249 dl_t=17.680s (Δ=-0 ms) TN1 FN13 MN35 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1253 dl_t=17.737s (Δ=+56 ms) TN1 FN14 MN35 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1245 dl_t=17.624s (Δ=-57 ms) TN1 FN12 MN35 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1249 dl_t=17.680s (Δ=-0 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1253 dl_t=17.737s (Δ=+56 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-57 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #5  t=16.806s  CRC=-  `A9 A8 DA F6 6D BD`

**AACH-Kontext (±0.2 s):**

- DL #1274 dl_t=18.035s (Δ=+7 ms) TN2 FN01 MN36 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1273 dl_t=18.020s (Δ=-7 ms) TN1 FN01 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1277 dl_t=18.077s (Δ=+49 ms) TN1 FN02 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-291 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-347 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-404 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #6  t=16.920s  CRC=-  `FA A3 76 9A 14 3A`

**AACH-Kontext (±0.2 s):**

- DL #1282 dl_t=18.148s (Δ=+6 ms) TN2 FN03 MN36 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1281 dl_t=18.134s (Δ=-8 ms) TN1 FN03 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1285 dl_t=18.190s (Δ=+49 ms) TN1 FN04 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-405 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-461 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-518 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #7  t=16.976s  CRC=-  `7C 20 ED 3D FC 74`

**AACH-Kontext (±0.2 s):**

- DL #1285 dl_t=18.190s (Δ=-7 ms) TN1 FN04 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1289 dl_t=18.247s (Δ=+49 ms) TN1 FN05 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1282 dl_t=18.148s (Δ=-50 ms) TN2 FN03 MN36 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-461 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-517 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-574 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #8  t=17.033s  CRC=-  `33 4F 67 68 4D D0`

**AACH-Kontext (±0.2 s):**

- DL #1289 dl_t=18.247s (Δ=-8 ms) TN1 FN05 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1293 dl_t=18.304s (Δ=+49 ms) TN1 FN06 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1285 dl_t=18.190s (Δ=-64 ms) TN1 FN04 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-518 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-574 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-631 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #9  t=17.089s  CRC=-  `32 6C 3F 80 A5 25`

**AACH-Kontext (±0.2 s):**

- DL #1293 dl_t=18.304s (Δ=-7 ms) TN1 FN06 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1297 dl_t=18.360s (Δ=+50 ms) TN1 FN07 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1289 dl_t=18.247s (Δ=-64 ms) TN1 FN05 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-574 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-630 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-687 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #10  t=17.146s  CRC=-  `BD C0 3E 0F FC F3`

**AACH-Kontext (±0.2 s):**

- DL #1297 dl_t=18.360s (Δ=-7 ms) TN1 FN07 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1301 dl_t=18.417s (Δ=+49 ms) TN1 FN08 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1293 dl_t=18.304s (Δ=-64 ms) TN1 FN06 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-631 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-687 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-744 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #11  t=17.203s  CRC=-  `73 74 A7 AA 41 CF`

**AACH-Kontext (±0.2 s):**

- DL #1301 dl_t=18.417s (Δ=-8 ms) TN1 FN08 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1305 dl_t=18.474s (Δ=+49 ms) TN1 FN09 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1297 dl_t=18.360s (Δ=-64 ms) TN1 FN07 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-688 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-744 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-801 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #12  t=17.259s  CRC=-  `BD C0 3F 80 A5 25`

**AACH-Kontext (±0.2 s):**

- DL #1305 dl_t=18.474s (Δ=-7 ms) TN1 FN09 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1309 dl_t=18.530s (Δ=+50 ms) TN1 FN10 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1301 dl_t=18.417s (Δ=-64 ms) TN1 FN08 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-744 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-800 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-857 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #13  t=17.316s  CRC=-  `32 6C CA 0F C6 F3`

**AACH-Kontext (±0.2 s):**

- DL #1309 dl_t=18.530s (Δ=-7 ms) TN1 FN10 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1313 dl_t=18.587s (Δ=+49 ms) TN1 FN11 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1305 dl_t=18.474s (Δ=-64 ms) TN1 FN09 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-801 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-857 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-914 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #14  t=17.373s  CRC=-  `E8 61 26 47 02 FB`

**AACH-Kontext (±0.2 s):**

- DL #1313 dl_t=18.587s (Δ=-8 ms) TN1 FN11 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1317 dl_t=18.644s (Δ=+49 ms) TN1 FN12 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1309 dl_t=18.530s (Δ=-64 ms) TN1 FN10 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-858 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-914 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-971 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #15  t=17.429s  CRC=-  `76 C0 3E 0F FC F3`

**AACH-Kontext (±0.2 s):**

- DL #1317 dl_t=18.644s (Δ=-7 ms) TN1 FN12 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1321 dl_t=18.700s (Δ=+50 ms) TN1 FN13 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1313 dl_t=18.587s (Δ=-64 ms) TN1 FN11 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-914 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-970 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1027 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #16  t=17.543s  CRC=-  `32 4F 67 68 4D D0`

**AACH-Kontext (±0.2 s):**

- DL #1325 dl_t=18.757s (Δ=-8 ms) TN1 FN14 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1329 dl_t=18.814s (Δ=+49 ms) TN1 FN15 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1321 dl_t=18.700s (Δ=-64 ms) TN1 FN13 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1028 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1084 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1141 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #17  t=17.656s  CRC=-  `95 9C DF 99 98 BC`

**AACH-Kontext (±0.2 s):**

- DL #1333 dl_t=18.870s (Δ=-7 ms) TN1 FN16 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1337 dl_t=18.927s (Δ=+49 ms) TN1 FN17 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1329 dl_t=18.814s (Δ=-64 ms) TN1 FN15 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1141 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1197 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1254 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #18  t=17.769s  CRC=-  `4D 09 9B 73 98 BD`

**AACH-Kontext (±0.2 s):**

- DL #1341 dl_t=18.984s (Δ=-7 ms) TN1 FN18 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1345 dl_t=19.040s (Δ=+50 ms) TN1 FN01 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1337 dl_t=18.927s (Δ=-64 ms) TN1 FN17 MN36 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1254 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1310 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1367 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #19  t=17.939s  CRC=-  `4E FC 03 6E 09 DB`

**AACH-Kontext (±0.2 s):**

- DL #1353 dl_t=19.154s (Δ=-7 ms) TN1 FN03 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1350 dl_t=19.111s (Δ=-49 ms) TN2 FN02 MN37 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1357 dl_t=19.210s (Δ=+50 ms) TN1 FN04 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1424 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1480 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1537 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #20  t=17.996s  CRC=-  `32 68 CA 0F F8 43`

**AACH-Kontext (±0.2 s):**

- DL #1357 dl_t=19.210s (Δ=-7 ms) TN1 FN04 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1361 dl_t=19.267s (Δ=+49 ms) TN1 FN05 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1353 dl_t=19.154s (Δ=-64 ms) TN1 FN03 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1481 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1537 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1594 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #21  t=18.053s  CRC=-  `32 BB A8 C5 3B E5`

**AACH-Kontext (±0.2 s):**

- DL #1361 dl_t=19.267s (Δ=-8 ms) TN1 FN05 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1365 dl_t=19.324s (Δ=+49 ms) TN1 FN06 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1357 dl_t=19.210s (Δ=-64 ms) TN1 FN04 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1538 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1594 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1651 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #22  t=18.110s  CRC=-  `D2 C3 00 1C 36 10`

**AACH-Kontext (±0.2 s):**

- DL #1365 dl_t=19.324s (Δ=-8 ms) TN1 FN06 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1369 dl_t=19.380s (Δ=+49 ms) TN1 FN07 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1361 dl_t=19.267s (Δ=-65 ms) TN1 FN05 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1595 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1651 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1708 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #23  t=18.166s  CRC=-  `EE 20 9A F3 72 08`

**AACH-Kontext (±0.2 s):**

- DL #1369 dl_t=19.380s (Δ=-7 ms) TN1 FN07 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1373 dl_t=19.437s (Δ=+49 ms) TN1 FN08 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1365 dl_t=19.324s (Δ=-64 ms) TN1 FN06 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1651 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-1707 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-1764 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #24  t=18.492s  CRC=OK  `41 41 7C 8C 71 91`

**AACH-Kontext (±0.2 s):**

- DL #1393 dl_t=19.720s (Δ=+7 ms) TN1 FN13 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1389 dl_t=19.664s (Δ=-50 ms) TN1 FN12 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1397 dl_t=19.777s (Δ=+64 ms) TN1 FN14 MN37 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-1977 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-2033 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-2090 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #25  t=18.839s  CRC=OK  `41 41 7C 8C 71 91`

**AACH-Kontext (±0.2 s):**

- DL #1417 dl_t=20.060s (Δ=-0 ms) TN1 FN01 MN38 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1418 dl_t=20.075s (Δ=+14 ms) TN2 FN01 MN38 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1421 dl_t=20.117s (Δ=+57 ms) TN1 FN02 MN38 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-2324 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-2380 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-2437 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #26  t=19.236s  CRC=OK  `41 41 7C 8C 71 91`

**AACH-Kontext (±0.2 s):**

- DL #1445 dl_t=20.457s (Δ=-0 ms) TN1 FN08 MN38 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1446 dl_t=20.471s (Δ=+14 ms) TN2 FN08 MN38 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1442 dl_t=20.415s (Δ=-43 ms) TN2 FN07 MN38 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)

**DL-Signaling-Reaktion(en):**

- DL #1253 dl_t=17.737s (Δ=-2721 ms) TN1 FN14 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1249 dl_t=17.680s (Δ=-2777 ms) TN1 FN13 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT
- DL #1245 dl_t=17.624s (Δ=-2834 ms) TN1 FN12 MN35 · MAC: MAC-RESOURCE (SCH/F) addr=SSI+Usage ID=2633617 LI=15 · LLC: BL-UDATA · CMCE→→ D-CONNECT

## UL #27  t=20.086s  CRC=OK  `41 41 7C 8C 71 91`

**AACH-Kontext (±0.2 s):**

- DL #1505 dl_t=21.307s (Δ=-0 ms) TN1 FN05 MN39 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1506 dl_t=21.321s (Δ=+14 ms) TN2 FN05 MN39 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)
- DL #1502 dl_t=21.265s (Δ=-43 ms) TN2 FN04 MN39 AACH `CapAlloc` · f1=11 f2=11 raw=0x32CB (dist=0)

_Keine DL-Signaling-Reaktion im Fenster._

## UL #28  t=20.419s  CRC=OK  `41 41 7C 8C 71 91`

**AACH-Kontext (±0.2 s):**

- DL #1529 dl_t=21.647s (Δ=+7 ms) TN1 FN11 MN39 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1525 dl_t=21.591s (Δ=-50 ms) TN1 FN10 MN39 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)
- DL #1533 dl_t=21.704s (Δ=+63 ms) TN1 FN12 MN39 AACH `DL/UL-Assign` · DL=Common UL=Random CC=9 f1=9 f2=9 (dist=0)

_Keine DL-Signaling-Reaktion im Fenster._

---

_Gesamt: 27/29 dekodierte UL-Bursts mit ≥1 DL-Signaling-Reaktion im Fenster._
