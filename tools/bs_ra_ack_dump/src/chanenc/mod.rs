//! Vendored copies of the soapysdr-free channel-encoder components from
//! `tetra-bluestation/crates/tetra-entities/src/lmac/components/`.  This
//! mirror lets us use `encode_cp` without pulling the whole `tetra-entities`
//! crate (which has a hard `soapysdr` dep for its PHY layer).
//!
//! Upstream refs as of audit 2026-04-24 (commit TBD — pin after rebase).

pub mod convenc;
pub mod crc16;
pub mod errorcontrol_params;
pub mod interleaver;
pub mod scrambler;

use tetra_core::BitBuffer;
use tetra_saps::tmv::TmvUnitdataReq;
use tetra_saps::tmv::enums::logical_chans::LogicalChannel;

use convenc::{ConvEncState, RcpcPunctMode};

const MAX_TYPE1_BITS: usize = 274;
const MAX_TYPE2_BITS: usize = 288;
const MAX_TYPE345_BITS: usize = 432;

/// Encode a control-plane message from type-1 to type-5 bits.
/// Handles CP channels except AACH.  Verbatim port of
/// `tetra_entities::lmac::components::errorcontrol::encode_cp` (2026-04-24),
/// stripped of the AACH / TCH / speech-related branches that we don't use.
pub fn encode_cp(mut prim: TmvUnitdataReq) -> BitBuffer {
    let lchan = prim.logical_channel;
    assert!(lchan.is_control_channel() && lchan != LogicalChannel::Aach);

    let params = errorcontrol_params::get_params(lchan);
    assert_eq!(
        prim.mac_block.get_len(),
        params.type1_bits,
        "encode_cp: type1_bits mismatch for {:?}",
        lchan
    );

    // type1 → byte-per-bit array
    prim.mac_block.seek(0);
    let mut type2_arr = [0u8; MAX_TYPE2_BITS];
    prim.mac_block.to_bitarr(&mut type2_arr[0..params.type1_bits]);

    // CRC-16 addition (type1 → type2)
    assert!(params.have_crc16, "encode_cp: only CP channels with CRC16 are handled");
    let crc = !crc16::crc16_ccitt_bits(&type2_arr[0..params.type1_bits], params.type1_bits);
    for i in 0..16 {
        type2_arr[params.type1_bits + i] = ((crc >> (15 - i)) & 1) as u8;
    }

    // Convolutional encode rate-1/4 mother (type2 → type3-depunct)
    let mut type3dp_arr = [0u8; MAX_TYPE345_BITS * 4];
    let mut ces = ConvEncState::new();
    ces.encode(&type2_arr[0..params.type2_bits], &mut type3dp_arr);

    // Puncturing (depunct → type3)  — SCH/F uses Rate2_3 per ETSI §8.2.3.2
    let mut type3_arr = [0u8; MAX_TYPE345_BITS];
    convenc::get_punctured_rate(RcpcPunctMode::Rate2_3, &type3dp_arr, &mut type3_arr);

    // Block interleaver (type3 → type4)
    let mut type4_arr = [0u8; MAX_TYPE345_BITS];
    interleaver::block_interleave(
        params.type345_bits,
        params.interleave_a,
        &type3_arr,
        &mut type4_arr,
    );
    let mut type4 = BitBuffer::from_bitarr(&type4_arr[0..params.type345_bits]);

    // Scrambling (type4 → type5)
    scrambler::tetra_scramb_bits(prim.scrambling_code, &mut type4);
    type4
}
