//! Offline reference: serialise + channel-encode the minimal
//! RA-Ack that `tetra-bluestation::bs_sched.rs::dl_make_minimal_resource`
//! would produce on our own HamTETRA cell parameters, so we can diff it
//! against the bursts decoded from our WAV captures via
//! `scripts/decode_dl.py`.
//!
//! Cell parameters (own "gold" cell): MCC=901, MNC=9998, CC=49, target ISSI=523.
//!   scrambling_code = (MCC << 22) | (MNC << 8) | (CC << 2) | 0b11 = 0xE1670EC7.
//!
//! On-air assumptions (matching bs_sched.rs 2026-04-24 behaviour):
//!   - Channel: SCH/F  (268 type-1 info bits, 432 type-5 coded bits)
//!     rationale: `dl_build_block_from_signalling_schedule`
//!     (bs_sched.rs:737/750) always allocates `BitBuffer::new(SCH_F_CAP)`
//!     for signalling.  SCH/HD is only used for the idle pre-set block in
//!     `generate_default_blks` (bs_sched.rs:1181), not for the RA-Ack.
//!   - Content: empty MAC-RESOURCE header (random_access_flag=1,
//!     addr=Ssi(523), no SDU, no LLC/MLE/MM payload) — Slow-Path RA-Ack
//!     per `dl_make_minimal_resource(addr, None, true)` (Z.708).
//!   - Tail: a single trailing Null PDU (16 bit) inserted by
//!     `try_add_null_pdus` when room permits; remaining bits of the
//!     268-bit SCH/F block stay zero (bluestation's current behaviour,
//!     with an explicit TODO comment around fill bits in bs_sched.rs:541).
//!
//! Output: hex of the 432 type-5 bits, plus the intermediate 268-bit
//! type-1 block for reference.  Hex encoding is MSB-first, bit 0 of
//! the printed word is the first bit on-air (matches `decode_dl.py`).

mod chanenc;

use tetra_core::{BitBuffer, SsiType, TetraAddress};
use tetra_pdus::umac::pdus::mac_resource::MacResource;
use tetra_saps::tmv::TmvUnitdataReq;
use tetra_saps::tmv::enums::logical_chans::LogicalChannel;

use chanenc::encode_cp;

/// SCH/F full-slot capacity in type-1 info bits (matches
/// `tetra_entities::umac::subcomp::bs_sched::SCH_F_CAP`).
const SCH_F_CAP: usize = 268;

fn compute_scramble_init(mcc: u32, mnc: u32, cc: u32) -> u32 {
    ((mcc & 0x3FF) << 22) | ((mnc & 0x3FFF) << 8) | ((cc & 0x3F) << 2) | 0b11
}

/// Replica of `bs_sched::dl_make_minimal_resource(addr, None, true)`.
/// Produces an empty MAC-RESOURCE header carrying only random_access_flag=1.
fn dl_make_minimal_resource_ra_ack(addr: TetraAddress) -> MacResource {
    let mut pdu = MacResource {
        fill_bits: false,        // updated later
        pos_of_grant: 0,
        encryption_mode: 0,
        random_access_flag: true,
        length_ind: 0,           // updated later
        addr: Some(addr),
        event_label: None,
        usage_marker: None,
        power_control_element: None,
        slot_granting_element: None,
        chan_alloc_element: None,
    };
    // SDU length = 0 → length_ind covers only the MAC header.
    let _ = pdu.update_len_and_fill_ind(0);
    pdu
}

/// Add a trailing Null PDU if there is room, matching bluestation
/// `bs_sched.rs::try_add_null_pdus`.
fn try_add_null_pdu(buf: &mut BitBuffer) {
    const NULL_PDU_LEN_BITS: usize = 16;
    if buf.get_len_remaining() >= NULL_PDU_LEN_BITS {
        let mut null_pdu = MacResource::null_pdu();
        null_pdu.length_ind = 2;
        let _ = null_pdu.update_len_and_fill_ind(0);
        null_pdu.to_bitbuf(buf);
    }
}

fn bits_to_hex_msb_first(bits: &[u8]) -> String {
    // bits[0] is first on-air.  Pack into bytes MSB-first (bit 0 → bit 7 of byte 0).
    let mut out = String::with_capacity((bits.len() + 3) / 4);
    let mut acc: u8 = 0;
    let mut count: u8 = 0;
    for &b in bits {
        acc = (acc << 1) | (b & 1);
        count += 1;
        if count == 4 {
            out.push(std::char::from_digit(acc as u32, 16).unwrap());
            acc = 0;
            count = 0;
        }
    }
    if count > 0 {
        // Left-align remainder bits
        acc <<= 4 - count;
        out.push(std::char::from_digit(acc as u32, 16).unwrap());
    }
    out
}

fn main() {
    // --- Cell parameters ---
    const MCC: u32 = 901;
    const MNC: u32 = 9998;
    const CC: u32 = 49;
    const TARGET_SSI: u32 = 523;

    let scramble = compute_scramble_init(MCC, MNC, CC);
    println!(
        "bs_ra_ack_dump: MCC={} MNC={} CC={} SSI={} scramble=0x{:08X}",
        MCC, MNC, CC, TARGET_SSI, scramble
    );
    assert_eq!(scramble, 0xE1670EC7, "scramble init sanity");

    // --- Build MAC-RESOURCE (Slow-Path, empty body + RA-flag) ---
    let addr = TetraAddress {
        ssi: TARGET_SSI,
        ssi_type: SsiType::Ssi,    // bs_sched stores the addr carried on the UL.
                                   // Compare with SsiType::Issi variant below.
    };
    let mut buf = BitBuffer::new(SCH_F_CAP);
    let pdu = dl_make_minimal_resource_ra_ack(addr);
    println!("  MacResource: {}", pdu);
    pdu.to_bitbuf(&mut buf);
    let header_len = buf.get_len_written();
    println!("  header serialised: {} bits", header_len);

    // --- Trail with a single Null PDU if room ---
    try_add_null_pdu(&mut buf);
    let body_len = buf.get_len_written();
    println!("  after null-pdu trail: {} bits written into {}-bit SCH/F block",
             body_len, SCH_F_CAP);

    // Emit the type-1 block
    buf.seek(0);
    let mut type1_arr = vec![0u8; SCH_F_CAP];
    buf.to_bitarr(&mut type1_arr[..]);
    println!("\ntype1 ({} bits), first bit on-air first:", SCH_F_CAP);
    println!("  hex : {}", bits_to_hex_msb_first(&type1_arr));

    // --- Channel-encode SCH/F ---
    let prim = TmvUnitdataReq {
        logical_channel: LogicalChannel::SchF,
        mac_block: buf,
        scrambling_code: scramble,
    };
    let mut type5 = encode_cp(prim);
    type5.seek(0);

    // Dump type-5 bits
    let mut type5_arr = vec![0u8; 432];
    type5.to_bitarr(&mut type5_arr[..]);
    println!("\ntype5 (432 bits, scrambled+interleaved+RCPC+CRC16), first bit on-air first:");
    println!("  hex : {}", bits_to_hex_msb_first(&type5_arr));

    // --- BKN1 / BKN2 split (NDB layout) ---
    // Downlink NDB burst splits the 432 type-5 bits into BKN1[431:216]
    // (first half-slot) and BKN2[215:0] (second half-slot).  Our RTL
    // mirrors this at `tetra_slot_content_mux.v`.  Emit both halves so
    // the diff tool can pick them separately.
    println!("\nBKN1 (216 bits, bits 0..215 of type5, first on-air first):");
    println!("  hex : {}", bits_to_hex_msb_first(&type5_arr[0..216]));
    println!("\nBKN2 (216 bits, bits 216..431 of type5):");
    println!("  hex : {}", bits_to_hex_msb_first(&type5_arr[216..432]));
}
