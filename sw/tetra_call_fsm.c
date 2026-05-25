/*
 * tetra_call_fsm.c — Phase 7 G.5 Group-Call State Machine.
 *
 * Per-SSI call slots (max CALL_FSM_MAX_CALLS in flight). Dispatches UL
 * CMCE PDUs to DL responses via tetra_tx_submit() with the new TX_D_*
 * classes from G.4.
 *
 * MVP simplifications (will revisit):
 * - CallId allocation is a monotonic counter, modulo 14 bits. No
 * reuse / collision check vs MS-side allocations.
 * - D-CALL-PROCEEDING is skipped — BS jumps straight to D-CONNECT.
 * - No timer-based release; explicit U-RELEASE only.
 * - 1 talker at a time per call. Multi-priority queue is post-MVP.
 *
 * License: GPL v2
 */

#include "tetra_call_fsm.h"
#include "tetra_tx_transport.h"
#include "tetra_cmce_body.h"
#include "tetra_voice_filler.h"
#include "tetra_voice_pipe.h"
#include "tetra_db.h"

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static call_slot_t g_slots[CALL_FSM_MAX_CALLS];
static uint16_t g_next_call_id = 1u;
/* Cache: last value written to REG_VOICE_ACTIVE_MASK. Avoid issuing
 * redundant AXI writes from the watchdog tick. */
static uint32_t g_mask_cached = 0xFFFFFFFFu;

static uint32_t mono_ms_lo(void)
{
 struct timespec ts;
 clock_gettime(CLOCK_MONOTONIC, &ts);
 return (uint32_t)((uint64_t)ts.tv_sec * 1000ull + ts.tv_nsec / 1000000ull);
}

static void mask_write_cached(tetra_hal_t *hal, uint32_t v)
{
 if (v == g_mask_cached) return;
 tetra_reg_write(hal, REG_VOICE_ACTIVE_MASK, v);
 g_mask_cached = v;
}

/* Multi-Group 2026-05-25 — Mask aus den belegten voice_ts aller aktiven
 * Calls aggregieren (OR der bit (ts-1) Positionen). 0 = kein aktiver
 * Voice-Slot, sonst per-TS bit gesetzt. */
static uint32_t compute_voice_mask(void)
{
 uint32_t m = 0u;
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi != 0u
 && g_slots[i].voice_ts >= 1u && g_slots[i].voice_ts <= 4u
 && g_slots[i].state != CALL_STATE_IDLE
 && g_slots[i].state != CALL_STATE_RELEASING) {
 m |= (1u << (g_slots[i].voice_ts - 1u));
 }
 }
 return m;
}

static call_slot_t *find_slot(uint32_t ssi)
{
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi == ssi && ssi != 0u) return &g_slots[i];
 }
 return NULL;
}

/* 2026-05-25 — Floor-Lookup für Group-Member B, der PTT drückt während Call
 * läuft (Talker A, MS-B ist Group-Listener). MS-B sendet U-TX-DEMAND mit der
 * call_id die sie aus D-SETUP empfangen hat — nicht mit ihrer eigenen ISSI
 * im find_slot()-Sinn. Per Gold-Standard (DL-Decode UMt=23 konstant über
 * gesamten Group-Call) bleibt der Slot derselbe; nur der Talker wechselt. */
static call_slot_t *find_slot_by_call_id(uint16_t call_id)
{
 if (call_id == 0u) return NULL;
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi != 0u && g_slots[i].call_id == call_id) {
 return &g_slots[i];
 }
 }
 return NULL;
}

/* 2026-05-25 — Multi-MS Group-Call: MS-B drückt PTT während A spricht und
 * sendet U-SETUP (NICHT U-TX-DEMAND wie ETSI-Spec sagt — MTP3550-FW-Verhalten,
 * via attach_daemon-Log beobachtet). BS muss erkennen: es läuft schon ein
 * Group-Call mit dieser GSSI → kein neuer Slot, sondern Floor-Transfer an B. */
static call_slot_t *find_slot_by_gssi(uint32_t gssi)
{
 if (gssi == 0u) return NULL;
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi != 0u && g_slots[i].group_gssi == gssi) {
 return &g_slots[i];
 }
 }
 return NULL;
}

/* 2026-05-24 Klasse 2 — UMt-Pool 4..63 round-robin.
 * ETSI EN 300 392-2 §21.4.7.2: UMt = Traffic Usage Marker im AACH des
 * Voice-Slots, pro Call eindeutig. UMt=0..3 sind reserviert (UMx/UMa/UMc/
 * UMr). Wir nehmen sequenziell 4,5,...,63,4,... — kollisionsfrei solange
 * max 60 simultane Calls. CALL_FSM_MAX_CALLS=8 → garantiert ok. */
static uint8_t g_next_umt = 4u;

static uint8_t alloc_umt(void)
{
 uint8_t v = g_next_umt;
 g_next_umt++;
 if (g_next_umt > 63u) g_next_umt = 4u;
 return v;
}

/* Per-TS AACH-Wert ans RTL schreiben. ts=1..4 = ETSI Timeslot-Index
 * (ETSI EN 300 392-2 §9.3, kein TS0). Intern auf REG_SLOT_AACH_(ts-1)
 * gemappt — RTL bleibt 0-based weil ETSI SYNC-PDU dort 2-bit-Feld
 * 0..3 vorgibt (§21.5.1). SLOT_AACH_(ts-1) wird vom aach_encoder
 * ausgelesen wenn voice_active_mask[ts-1]=1. */
static void aach_write(tetra_hal_t *hal, unsigned ts, uint16_t info)
{
 static const uint32_t REGS[4] = {REG_SLOT_AACH_TS1, REG_SLOT_AACH_TS2,
                                  REG_SLOT_AACH_TS3, REG_SLOT_AACH_TS4};
 if (hal == NULL || ts == 0u || ts > 4u) return;
 tetra_reg_write(hal, REGS[ts - 1u], (uint32_t)(info & 0x3FFFu));
}

/* Voice-TS Bereich: TS1 ist mcch (Control), TS2/TS3/TS4 sind Voice.
 * Multi-Group 2026-05-25 — round-robin Allocation über {2,3,4} mit
 * Kollisions-Check. Mask-Bit-Position = (ts-1): TS2→0x02, TS3→0x04,
 * TS4→0x08. ChanAlloc-Bitmap MSB-first [TS1,TS2,TS3,TS4]: TS2→0b0100. */
#define VOICE_TS_MIN     2u
#define VOICE_TS_MAX     4u

static uint8_t g_next_voice_ts = VOICE_TS_MIN;

static uint8_t alloc_voice_ts(void)
{
 for (unsigned tries = 0; tries < (VOICE_TS_MAX - VOICE_TS_MIN + 1u); tries++) {
 uint8_t cand = g_next_voice_ts;
 g_next_voice_ts++;
 if (g_next_voice_ts > VOICE_TS_MAX) g_next_voice_ts = VOICE_TS_MIN;
 int collision = 0;
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi != 0u && g_slots[i].voice_ts == cand) {
 collision = 1; break;
 }
 }
 if (!collision) return cand;
 }
 return 0u;
}

/* ETSI ChanAlloc ts_assigned bitmap MSB-first [TS1,TS2,TS3,TS4]. */
static uint8_t voice_ts_to_bitmap(uint8_t voice_ts)
{
 if (voice_ts < 1u || voice_ts > 4u) return 0u;
 return (uint8_t)(1u << (4u - voice_ts));
}

static call_slot_t *alloc_slot(tetra_hal_t *hal, uint32_t ssi)
{
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi == 0u) {
 memset(&g_slots[i], 0, sizeof(g_slots[i]));
 g_slots[i].ssi = ssi;
 g_slots[i].call_id = g_next_call_id++;
 if ((g_next_call_id & 0x3FFFu) == 0u) g_next_call_id = 1u;
 g_slots[i].state = CALL_STATE_IDLE;
 /* BS-side LLC stop-and-wait init nach MS NS=0:
 * BS NS = 0 (eigenes erstes Daten-Frame)
 * BS NR = 1 (next expected MS NS) */
 g_slots[i].ns = 0u;
 g_slots[i].nr = 1u;
 g_slots[i].umt = alloc_umt();
 g_slots[i].voice_ts = alloc_voice_ts();
 if (g_slots[i].voice_ts == 0u) {
 /* Alle Voice-TS belegt — Slot freigeben, Caller bekommt -1. */
 fprintf(stderr,
 "tetra_call_fsm: alloc_slot ssi=0x%06X — keine freie voice_ts "
 "(alle TS2..TS4 belegt)\n", ssi);
 memset(&g_slots[i], 0, sizeof(g_slots[i]));
 return NULL;
 }
 /* AACH für Voice-Slot direkt scharfstellen — MS sieht
  * {Header=11, UMt, UMt} = "Traffic, UMt=N für DL+UL". */
 aach_write(hal, g_slots[i].voice_ts,
            (uint16_t)AACH_VOICE_UMT(g_slots[i].umt));
 fprintf(stderr,
 "tetra_call_fsm: alloc_slot ssi=0x%06X → call_id=%u UMt=%u "
 "voice_ts=TS%u AACH=0x%04X\n",
 ssi, g_slots[i].call_id, g_slots[i].umt, g_slots[i].voice_ts,
 (unsigned)AACH_VOICE_UMT(g_slots[i].umt));
 return &g_slots[i];
 }
 }
 return NULL;
}

static void free_slot(tetra_hal_t *hal, call_slot_t *s)
{
 /* AACH zurück auf Idle bevor Slot-Daten verloren gehen. */
 if (s->voice_ts >= 1u && s->voice_ts <= 4u)
 aach_write(hal, s->voice_ts, AACH_IDLE);
 fprintf(stderr,
 "tetra_call_fsm: free_slot ssi=0x%06X call_id=%u UMt=%u → AACH=0x3000 idle\n",
 s->ssi, s->call_id, s->umt);
 memset(s, 0, sizeof(*s));
}

/* BS-side NS alterniert pro emittiertem BL-ADATA-Frame. NR bleibt
 * unverändert solange MS keine neue NS-Sequenz signalisiert (MS sendet
 * BL-DATA = nur NS, kein NR; ein Wechsel von MS-NS würde NR togglen). */
static void nsnr_step_bs(call_slot_t *s)
{
 s->ns ^= 1u;
}

/* D-CALL-PROCEEDING — erste BS→MS-Antwort nach U-SETUP. Per bluestation
 * `cc_bs.rs::rx_u_setup` Z. 478: bestätigt U-SETUP, hält MS-Setup-Timer am
 * Leben, MUSS vor D-CONNECT kommen. */
static int stage_d_call_proceeding(tetra_hal_t *hal, call_slot_t *s)
{
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->ssi;
 m.ns = s->ns;
 m.nr = s->nr;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 return tetra_tx_submit(hal, TX_D_CALL_PROCEEDING, &m);
}

/* D-SETUP wird an das Call-Target adressiert:
 *   - Group-Call: Group-GSSI (broadcast an alle Group-Member,
 *     "someone has the floor")
 *   - Individual-Call: Callee-ISSI (incoming-call-Alert an einzelne MS)
 * transmission_grant = GrantedToOtherUser (=3, NICHT Granted=0),
 * BSI echoed aus U-SETUP. */
static int stage_d_setup(tetra_hal_t *hal, call_slot_t *s)
{
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->group_gssi ? s->group_gssi
              : s->target_issi ? s->target_issi
              : s->ssi;
 m.ns = s->ns;
 m.nr = s->nr;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 m.cmce.call_time_out = 7; /* T5m per bluestation */
 m.cmce.transmission_grant = 3; /* GrantedToOtherUser */
 m.cmce.transmission_request_permission = 0; /* allowed to request */
 m.cmce.call_priority = 4;
 m.cmce.calling_party_ssi = s->ssi;
 /* BSI echoed from U-SETUP: TchS speech.
  *   communication_type: 0=Point-to-Point (Individual), 1=P2MP (Group),
  *   2=Ack-Group, 3=Broadcast. Hier zwischen Group und Individual
  *   schalten, sonst zeigt SDR# (und MS) jeden Call als Group an. */
 m.cmce.bsi_circuit_mode_type = 0;
 m.cmce.bsi_encryption_flag = 0;
 m.cmce.bsi_communication_type = s->group_gssi ? 1 : 0;
 m.cmce.bsi_speech_service = 0;
 return tetra_tx_submit(hal, TX_D_SETUP, &m);
}

static int stage_d_connect(tetra_hal_t *hal, call_slot_t *s)
{
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->ssi;
 m.ns = s->ns;
 m.nr = s->nr;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 /* verifizierte Werte (#5887 bit-exact, 2026-05-14): */
 m.cmce.call_time_out = 0; /*: Infinite (war 7 T5m) */
 m.cmce.hook_method_selection = s->hook_method;
 m.cmce.simplex_duplex_selection = s->simplex_duplex;
 m.cmce.transmission_grant = CMCE_TG_GRANTED; /* 0 = Granted ✓ */
 m.cmce.transmission_request_permission = 0; /* ✓ */
 m.cmce.call_ownership = 0; /*: 0 (war 1) */
 m.cmce.call_priority = 1; /*: p_call_priority=1 IE */
 return tetra_tx_submit(hal, TX_D_CONNECT, &m);
}

static int stage_d_tx_granted(tetra_hal_t *hal, call_slot_t *s)
{
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->ssi;
 m.ns = s->ns;
 m.nr = s->nr;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 m.cmce.transmission_grant = CMCE_TG_GRANTED; /* 0 = Granted */
 m.cmce.encryption_control = 0;
 return tetra_tx_submit(hal, TX_D_TX_GRANTED, &m);
}

static int stage_d_release(tetra_hal_t *hal, call_slot_t *s, uint8_t cause)
{
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->ssi;
 m.ns = s->ns;
 m.nr = s->nr;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 m.cmce.disconnect_cause = cause;
 return tetra_tx_submit(hal, TX_D_RELEASE, &m);
}

int tetra_call_fsm_handle(tetra_hal_t *hal, uint32_t ssi,
 const cmce_pdu_t *p)
{
 if (p == NULL || ssi == 0u) return -2;

 call_slot_t *s = find_slot(ssi);

 switch (p->pdu_type) {
 case CMCE_U_SETUP: {
 /* Called-party-SSI aus U-SETUP übernehmen. Group vs Individual
  * steht im BSI.communication_type (ETSI §14.8.41):
  *   00 = Point-to-Point (= Individual call, target = ISSI)
  *   01 = Point-to-Multipoint (Group call, target = GSSI)
  *   10 = Acknowledged Group call (target = GSSI)
  *   11 = Broadcast call (target = Broadcast-GSSI)
  * DB-Lookup-Validierung (cp_ssi muss als GSSI registriert sein für
  * group-calls) als Belt-and-Suspenders, falls die MS einen falschen
  * communication_type signalisiert. */
 uint32_t cp_ssi = (p->called_party_type_identifier == 1u
 || p->called_party_type_identifier == 2u)
 ? (p->called_party_ssi & 0x00FFFFFFu): 0u;
 uint8_t ct = p->bsi.communication_type;
 int cp_is_group = (cp_ssi != 0u) && (ct == 1u || ct == 2u || ct == 3u);
 if (cp_is_group && tetra_db_lookup(cp_ssi, 1u, NULL) != 1) {
 fprintf(stderr,
 "tetra_call_fsm: U-SETUP ssi=0x%06X cp=0x%06X ct=%u "
 "advertised group but not in GSSI table → individual\n",
 ssi, cp_ssi, ct);
 cp_is_group = 0;
 }
 /* 2026-05-25 — Multi-MS Floor-Transfer via U-SETUP (MTP3550-FW
  * sendet U-SETUP statt U-TX-DEMAND wenn anderes Group-Member PTT
  * drückt). Wenn schon ein Group-Call für dieselbe GSSI läuft:
  * KEIN neuer Slot, Floor an B transferieren, gleiche UMt/voice_ts
  * behalten. Sonst kollidiert SLOT_AACH_N zwischen A's und B's Call. */
 if (s == NULL && cp_is_group) {
 call_slot_t *group_slot = find_slot_by_gssi(cp_ssi);
 if (group_slot != NULL) {
 fprintf(stderr,
 "tetra_call_fsm: U-SETUP floor-transfer ssi=0x%06X "
 "gssi=0x%06X → call_id=%u (alter Talker=0x%06X, "
 "UMt=%u/voice_ts=TS%u behalten)\n",
 ssi, cp_ssi, group_slot->call_id, group_slot->ssi,
 group_slot->umt, group_slot->voice_ts);
 group_slot->ssi = ssi;
 group_slot->ns = 0u;
 group_slot->nr = 0u;
 s = group_slot;
 }
 }
 if (s == NULL) {
 s = alloc_slot(hal, ssi);
 if (s == NULL) {
 fprintf(stderr,
 "tetra_call_fsm: U-SETUP ssi=0x%06X — no free slot\n",
 ssi);
 return -1;
 }
 }
 s->group_gssi = cp_is_group ? cp_ssi: 0u;
 s->target_issi = cp_is_group ? 0u : cp_ssi;
 /* Echo MS-side hook_method + simplex_duplex (Phase 7 G.7+) — MS
 * needs to see its own selections reflected in D-CONNECT to enter
 * TX state. */
 s->hook_method = p->hook_method_selection & 0x1u;
 s->simplex_duplex = p->simplex_duplex_selection & 0x1u;
 s->state = CALL_STATE_CONNECTING;

 /* Gold-konforme Group-Call-Setup-Sequenz (2026-05-16, verifiziert
  * via reference dl_events.jsonl #5887/95/03 + #6943):
  *   1. D-CONNECT × 3 an Caller-MS-ISSI (= individual call-leg-ACK),
  *      113 ms apart (Gold-Spacing, FN02→04→06 = 2 frames)
  *   2. D-SETUP × 1 an Group-GSSI (= broadcast für Group-Member)
  * 2026-05-17 non-blocking refactor: D-CONNECT[1] sofort, [2]+[3]+D-SETUP
  * via setup_stage in tetra_call_fsm_tick (statt blockierendem
  * usleep(113ms), das daemon-Mainloop für 226 ms blockierte und
  * MS-Retransmits verzögerte). */
 /* TIMING-DIAGNOSE: t0 = U-SETUP arrived */
 uint32_t t0_ms = mono_ms_lo();
 s->t_setup_arrived_ms = t0_ms;
 s->t_first_nub_ms = 0u;
 s->t_ceased_ms = 0u;
 s->t_first_nub_logged = 0u;

 int rc = stage_d_connect(hal, s);
 uint32_t t_conn1_ms = mono_ms_lo();
 fprintf(stderr,
 "tetra_call_fsm: U-SETUP ssi=0x%06X gssi=0x%06X → D-CONNECT[1/2] "
 "call_id=%u rc=%d  [TIMING t0+%ums]\n",
 ssi, s->group_gssi, s->call_id, rc, t_conn1_ms - t0_ms);
 s->setup_stage = 1u; /* tick triggert D-CONNECT[2] dann [3]+D-SETUP */
 s->setup_next_ms = mono_ms_lo() + 113u;
 /* MER-Fix (2026-05-16 rev2): mask MUSS ab U-SETUP scharf sein —
  * unsere D-CONNECT-Antwort trägt transmission_grant=Granted, die
  * MS überspringt damit U-TX-DEMAND und sendet sofort UL-Voice.
  * Erwartet voice-busy AACH (0x32CB) auf voice-slot. Ohne Bit
  * voice_ts-1 in der Mask sieht MS idle-AACH → "PTT abgewiesen". */
 s->last_activity_poll_cnt = mono_ms_lo();
 s->state = CALL_STATE_CONNECTED;
 mask_write_cached(hal, compute_voice_mask());
 /* G.8-Filler entfernt (2026-05-16): die statische MAC-RESOURCE-NULL-
  *   PDU produzierte auf TS2 NDB1-Bursts mit SCH/F-CRC-FAIL und blockierte
  *   die MS am Voice-TX. Voice-Slot bleibt jetzt leer (filler-Mailbox
  *   cleared) bis tetra_voice_pipe_tick einen echten UL-NUB-Burst
  *   relayt. */
 tetra_voice_filler_clear(hal);
 fprintf(stderr,
 "tetra_call_fsm: VOICE_ACTIVE_MASK=0x%02X (U-SETUP → call_id=%u "
 "voice_ts=TS%u, filler cleared — voice-slot wartet auf UL-NUB)\n",
 g_mask_cached, s->call_id, s->voice_ts);
 return rc;
 }

 case CMCE_U_TX_DEMAND: {
 /* 2026-05-25 — Floor-Wechsel im Group-Call: MS-B (≠ Caller) drückt
  * PTT während A spricht. B hat keinen eigenen Call-Slot — wir finden
  * den existing Group-Slot via call_id, übernehmen Floor an B.
  * Gold-Standard verifiziert (Decode 04-20): UMt+voice_ts+SLOT_AACH
  * bleiben konstant über Floor-Wechsel, nur s->ssi (= aktueller Talker)
  * wechselt. */
 if (s == NULL) {
 s = find_slot_by_call_id(p->call_identifier);
 if (s != NULL) {
 fprintf(stderr,
 "tetra_call_fsm: U-TX-DEMAND floor-transfer ssi=0x%06X "
 "→ call_id=%u (alter Talker=0x%06X, UMt=%u behalten)\n",
 ssi, s->call_id, s->ssi, s->umt);
 s->ssi = ssi;
 s->ns = 0u; /* LLC stop-and-wait für neuen Talker reset */
 s->nr = 0u;
 }
 }
 if (s == NULL) {
 /* Kein Group-Call mit dieser call_id und kein eigener Slot —
  * MS hat veraltete call_id oder Race. Silently drop wie bisher. */
 return -1;
 }
 nsnr_step_bs(s);
 int rc = stage_d_tx_granted(hal, s);
 s->state = CALL_STATE_TALKER;
 s->last_activity_poll_cnt = mono_ms_lo();
 /* Re-Key während Call: mask wieder scharf für ALLE aktiven Calls
  * (Multi-Group: bit voice_ts-1 pro Slot). */
 uint32_t newmask = compute_voice_mask();
 mask_write_cached(hal, newmask);
 fprintf(stderr,
 "tetra_call_fsm: U-TX-DEMAND ssi=0x%06X → D-TX-GRANTED "
 "call_id=%u ns=%u nr=%u rc=%d VOICE_ACTIVE_MASK=0x%02X\n",
 ssi, s->call_id, s->ns, s->nr, rc, newmask);
 return rc;
 }

 case CMCE_U_TX_CEASED: {
 if (s == NULL) return -1;
 s->state = CALL_STATE_CONNECTED;
 uint32_t t_ceased_now = mono_ms_lo();
 if (s->t_ceased_ms == 0u) {
 s->t_ceased_ms = t_ceased_now;
 /* Einmalig: Latenz U-SETUP → U-TX-CEASED (= komplette PTT-Dauer
  * vom BS-Sicht). Repeats zählen nicht (siehe MS-Retransmissions). */
 fprintf(stderr,
 "tetra_call_fsm: [TIMING] PTT-Dauer t0→ceased = %u ms "
 "(t_first_nub=%u ms %s)\n",
 t_ceased_now - s->t_setup_arrived_ms,
 s->t_first_nub_ms ? s->t_first_nub_ms - s->t_setup_arrived_ms : 0u,
 s->t_first_nub_ms ? "after t0" : "NEVER (no NUB)");
 }
 s->last_activity_poll_cnt = t_ceased_now;
 /* Talker beendet, Watchdog wird mask=0 setzen sobald relay_cnt
  * stillsteht (1.5 s). Hier mask NICHT direkt 0 setzen — Call-Slot
  * bleibt aktiv, evtl. Re-Key kommt sofort.
  * Phase 7 G.7+ — D-TX-CEASED-Bestätigung an Gruppe (broadcast auf GSSI).
 * Ohne diesen ACK retried MS U-TX-CEASED bis zu 10× (Stop-and-Wait pro
 * ETSI/bluestation). Adressiert an Group-GSSI weil alle Group-Member
 * informiert werden müssen dass Talker aufgehört hat. */
 tx_pdu_meta_t m;
 memset(&m, 0, sizeof(m));
 m.target_ssi = s->group_gssi ? s->group_gssi: s->ssi;
 m.umt = s->umt;
 m.chan_alloc_ts_bitmap = voice_ts_to_bitmap(s->voice_ts);
 m.cmce.call_identifier = s->call_id & 0x3FFFu;
 m.cmce.transmission_request_permission = 0; /* 0 = "allowed to request" per bluestation */
 /* 2026-05-24 — beim ERSTEN U-TX-CEASED 3× D-TX-CEASED stagen (gleiche
  * Robust-Strategie wie D-CONNECT). MS sieht damit mind. 1 auch bei
  * Air-Burst-Verlust → keine U-TX-CEASED-Retries mehr. Bei späteren
  * U-TX-CEASED-Retries (= MS hatte unsere ersten 3 verloren) nur 1×
  * antworten — Pattern wie ETSI Stop-and-Wait. */
 unsigned reps = (s->t_ceased_ms == t_ceased_now) ? 3u : 1u;
 int rc = 0;
 for (unsigned i = 0; i < reps; i++) {
 rc = tetra_tx_submit(hal, TX_D_TX_CEASED, &m);
 }
 fprintf(stderr,
 "tetra_call_fsm: U-TX-CEASED ssi=0x%06X → D-TX-CEASED gssi=0x%06X "
 "call_id=%u reps=%u rc=%d\n",
 ssi, m.target_ssi, s->call_id, reps, rc);
 return rc;
 }

 case CMCE_U_RELEASE: {
 if (s == NULL) return -1;
 nsnr_step_bs(s);
 int rc = stage_d_release(hal, s, p->disconnect_cause);
 fprintf(stderr,
 "tetra_call_fsm: U-RELEASE ssi=0x%06X cause=%u → D-RELEASE "
 "call_id=%u rc=%d\n",
 ssi, p->disconnect_cause, s->call_id, rc);
 /* Phase Y.4.1 — Call beendet, voice-slot zurück zu idle. */
 free_slot(hal, s);
 mask_write_cached(hal, compute_voice_mask());
 if (compute_voice_mask() == 0u) tetra_voice_filler_clear(hal);
 return rc;
 }

 case CMCE_U_DISCONNECT: {
 /* User-Initiated Hangup: MS sendet U-DISCONNECT, BS muss D-RELEASE
  * an die Group senden um den Call zu beenden. Ohne Antwort retried
  * MS U-DISCONNECT bis zu 7× (ETSI/MTP3550-FW). Bisher fehlte der
  * Handler komplett — gemessen an Local-WAV vom 2026-05-23 16:51:
  * 7× U-DISCONNECT von ssi=1316858 cause=UserRequested, 0× D-RELEASE
  * von uns als Antwort. */
 if (s == NULL) return -1;
 nsnr_step_bs(s);
 int rc = stage_d_release(hal, s, p->disconnect_cause);
 fprintf(stderr,
 "tetra_call_fsm: U-DISCONNECT ssi=0x%06X cause=%u → D-RELEASE "
 "call_id=%u rc=%d\n",
 ssi, p->disconnect_cause, s->call_id, rc);
 free_slot(hal, s);
 mask_write_cached(hal, compute_voice_mask());
 if (compute_voice_mask() == 0u) tetra_voice_filler_clear(hal);
 return rc;
 }

 default:
 return -2;
 }
}

void tetra_call_fsm_tick(tetra_hal_t *hal)
{
 if (hal == NULL) return;
 uint32_t now = mono_ms_lo();
 unsigned active = 0;

 /* Aktivitäts-Heartbeat = REG_VOICE_NUB_RX_CNT bei thresh=10. Zählt
  * dann nur echte UL-TCH/S-Bursts (FP=0 im Idle, ~36 /s bei aktiver
  * MS-TX). Voice-Bursts brauchen kein CMCE-PDU → nub_rx ist der
  * einzig zuverlässige Echtzeit-Indikator. */
 static uint16_t s_last_nub_cnt = 0;
 static uint32_t s_nub_last_bump_ms = 0;
 static int s_nub_seen = 0;
 uint16_t nub_cnt = (uint16_t)(tetra_reg_read(hal, REG_VOICE_NUB_RX_CNT)
 & 0xFFFFu);
 if (nub_cnt != s_last_nub_cnt) {
 s_nub_last_bump_ms = now;
 s_nub_seen = 1;
 s_last_nub_cnt = nub_cnt;
 }
 uint32_t nub_quiet_ms = s_nub_seen ? (now - s_nub_last_bump_ms): 0;

 /* Heartbeat alle 1s: aktueller Watchdog-State (nur wenn ein Slot aktiv) */
 static uint32_t s_last_hb_ms = 0;
 if ((now - s_last_hb_ms) >= 1000u) {
 s_last_hb_ms = now;
 for (unsigned j = 0; j < CALL_FSM_MAX_CALLS; j++) {
 if (g_slots[j].ssi == 0u) continue;
 fprintf(stderr,
 "HB: slot=%u ssi=0x%06X state=%d mask=0x%02X "
 "nub_cnt=%u nub_quiet_ms=%u age_ms=%u\n",
 j, g_slots[j].ssi, (int)g_slots[j].state,
 (unsigned)g_mask_cached,
 (unsigned)s_last_nub_cnt, nub_quiet_ms,
 now - g_slots[j].last_activity_poll_cnt);
 break;
 }
 }

 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 call_slot_t *s = &g_slots[i];
 if (s->ssi == 0u) continue;

 /* Non-blocking U-SETUP-Antwort-Sequenzer. D-CONNECT[1] wurde
  *   im CMCE_U_SETUP-Handler bereits gestaged. Diese Stages sind
  *   die Folge-Submits 113 ms apart, ohne den Daemon-Mainloop
  *   zu blockieren. */
 if (s->setup_stage > 0u &&
 (int32_t)(now - s->setup_next_ms) >= 0) {
 if (s->setup_stage == 1u) {
 /* 2026-05-24 — D-CONNECT 3× → 2× reduziert. Gold-WAV (call_id=18)
  * zeigt nur 2 D-CONNECT-Wiederholungen, nicht 3. Memory
  * project_d_connect_retransmit_rate: "1 Hard-Reject Case bei
  * 3 D-CONNECTs zu schnell" → Reduktion eliminiert das Risiko. */
 int rc = stage_d_connect(hal, s);
 fprintf(stderr,
 "tetra_call_fsm: U-SETUP ssi=0x%06X gssi=0x%06X → D-CONNECT[2/2] "
 "call_id=%u rc=%d  [TIMING t0+%ums]\n",
 s->ssi, s->group_gssi, s->call_id, rc,
 now - s->t_setup_arrived_ms);
 s->setup_stage = 2u;
 s->setup_next_ms = now + 113u;
 } else if (s->setup_stage == 2u) {
 /* D-CONNECT[3] entfernt — direkt D-SETUP nach 113 ms.
  * Gold-Pattern: 2 D-CONNECT + (optional) D-SETUP für Group-Notify. */
 if (s->group_gssi != 0u || s->target_issi != 0u) {
 int src = stage_d_setup(hal, s);
 fprintf(stderr,
 "tetra_call_fsm: D-SETUP → %s=0x%06X "
 "call_id=%u rc=%d  [TIMING t0+%ums]\n",
 s->group_gssi ? "gssi": "issi",
 s->group_gssi ? s->group_gssi : s->target_issi,
 s->call_id, src, mono_ms_lo() - s->t_setup_arrived_ms);
 }
 s->setup_stage = 0u;
 }
 }

 /* NUB-Burst gesehen → Slot-last_activity refresh (verhindert
  * Stale-Free während aktiver PTT). */
 if (nub_quiet_ms == 0) s->last_activity_poll_cnt = now;

 uint32_t age = now - s->last_activity_poll_cnt;
 if (s->state != CALL_STATE_IDLE &&
 age > CALL_FSM_CALL_STALE_MS) {
 fprintf(stderr,
 "tetra_call_fsm: WATCHDOG ssi=0x%06X call_id=%u idle for "
 "%ums → freeing slot\n",
 s->ssi, s->call_id, age);
 tetra_voice_filler_clear(hal);
 free_slot(hal, s);
 continue;
 }
 active++;
 /* Phase B — UL→DL Voice-Pipeline. Wenn ein Burst in der UL-NUB-
  *   Read-Mailbox steht: dekodieren, SSI auf Call-Target patchen,
  *   re-encodieren und in DL-Filler-Mailbox schieben. Bei CRC-Fail
  *   (TCH/S Voice-ACELP ohne MAC-Header) → 1:1 weitergegeben. */
 uint32_t voice_tgt = s->group_gssi ? s->group_gssi : s->target_issi;
 if (voice_tgt != 0u)
 (void)tetra_voice_pipe_tick(hal, voice_tgt);
 }

 /* Mask-Lifecycle:
  * - Kein aktiver Slot → mask=0.
  * - Aktiver Slot + NUB seit > VOICE_QUIET_MS still → mask=0
  *   (AACH wird wieder idle, MER bleibt 0 %). Re-Key über neuen
  *   U-SETUP / U-TX-DEMAND setzt mask=0x02 wieder. */
 if (active == 0) {
 if (g_mask_cached != 0u) {
 fprintf(stderr,
 "WATCHDOG: mask→0 reason=active==0 nub_cnt=%u "
 "nub_quiet_ms=%u nub_seen=%d\n",
 (unsigned)s_last_nub_cnt, nub_quiet_ms, s_nub_seen);
 }
 mask_write_cached(hal, 0x00u);
 } else if (s_nub_seen && nub_quiet_ms > CALL_FSM_VOICE_QUIET_MS) {
 if (g_mask_cached != 0u) {
 fprintf(stderr,
 "WATCHDOG: mask→0 reason=nub_quiet>%ums active=%u "
 "nub_cnt=%u nub_quiet_ms=%u\n",
 (unsigned)CALL_FSM_VOICE_QUIET_MS, active,
 (unsigned)s_last_nub_cnt, nub_quiet_ms);
 }
 mask_write_cached(hal, 0x00u);
 }
}

void tetra_call_fsm_dump(void)
{
 fprintf(stderr, "tetra_call_fsm slots:\n");
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 if (g_slots[i].ssi == 0u) continue;
 fprintf(stderr,
 " [%u] ssi=0x%06X call_id=%u state=%d ns=%u nr=%u\n",
 i, g_slots[i].ssi, g_slots[i].call_id,
 (int)g_slots[i].state, g_slots[i].ns, g_slots[i].nr);
 }
}

/* TIMING-DIAGNOSE (2026-05-20): wird vom voice_pipe_tick beim ERSTEN
 * dekodierten NUB-Burst innerhalb eines aktiven Setup-Cycles aufgerufen.
 * Loggt einmalig die Latenz U-SETUP → erster Voice-Burst.
 * Falls kein Slot mit pending Setup gefunden wird, no-op. */
void tetra_call_fsm_notify_first_nub(uint32_t now_ms)
{
 for (unsigned i = 0; i < CALL_FSM_MAX_CALLS; i++) {
 call_slot_t *s = &g_slots[i];
 if (s->ssi == 0u) continue;
 if (s->t_first_nub_logged) continue;
 if (s->t_setup_arrived_ms == 0u) continue;
 /* Heuristik: NUB innerhalb 10s nach Setup-Start zählt zum Setup */
 uint32_t age = now_ms - s->t_setup_arrived_ms;
 if (age > 10000u) continue;
 s->t_first_nub_ms = now_ms;
 s->t_first_nub_logged = 1u;
 fprintf(stderr,
 "tetra_call_fsm: [TIMING] first NUB-burst — t0→voice = %u ms "
 "(call_id=%u ssi=0x%06X)\n",
 age, s->call_id, s->ssi);
 break;
 }
}
