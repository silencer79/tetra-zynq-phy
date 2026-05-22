#!/bin/sh
# config.cgi — return current /root/tetra_cell.conf values as JSON
# so the WebUI can pre-fill form fields + duplex table on page load.

echo "Content-Type: application/json"
echo ""

CONF=/root/tetra_cell.conf

# Source the conf if present — graceful fallback to defaults otherwise.
if [ -r "$CONF" ]; then
    . "$CONF"
fi

# Defaults if conf is missing or partial.
: ${TX_FREQ_HZ:=438250000}
: ${RX_FREQ_HZ:=428250000}
: ${MCC:=901}
: ${MNC:=9998}
: ${LA:=1}
: ${CC:=49}
: ${TX_ATT_OP_DB:=-10}
: ${SYSTEM_CODE:=2}
: ${DUPLEX_SPACING:=0}
: ${MS_TXPWR:=6}
: ${RXLEVEL_MIN:=0}
: ${ACCESS_PARAM:=10}
: ${RADIO_DL_TIMEOUT:=5}
: ${OPT_FIELD:=1011456}
: ${PRIORITY_CELL:=0}
: ${MIGRATION:=0}
: ${NCB:=3}
: ${CSL:=0}
: ${GAIN_MODE:=fast_attack}
: ${RX_GAIN_DB:=40}
: ${RX_CIC_GAIN_SHF:=4}
: ${UL_RA_SYNC_THRESH:=15}
: ${DUPLEX_OFFSET_HZ_0:=-10000000}
: ${DUPLEX_OFFSET_HZ_1:=-45000000}
: ${DUPLEX_OFFSET_HZ_2:=0}
: ${DUPLEX_OFFSET_HZ_3:=-10000000}
: ${DUPLEX_OFFSET_HZ_4:=-10000000}
: ${DUPLEX_OFFSET_HZ_5:=-10000000}
: ${DUPLEX_OFFSET_HZ_6:=-10000000}
: ${DUPLEX_OFFSET_HZ_7:=-7600000}

cat <<EOF
{
  "freq": $TX_FREQ_HZ,
  "rx_freq": $RX_FREQ_HZ,
  "mcc": $MCC,
  "mnc": $MNC,
  "la": $LA,
  "cc": $CC,
  "tx_atten": $TX_ATT_OP_DB,
  "system_code": $SYSTEM_CODE,
  "duplex_spacing": $DUPLEX_SPACING,
  "ms_txpwr": $MS_TXPWR,
  "rxlevel_min": $RXLEVEL_MIN,
  "access_param": $ACCESS_PARAM,
  "radio_dl_timeout": $RADIO_DL_TIMEOUT,
  "opt_field": $OPT_FIELD,
  "priority_cell": $PRIORITY_CELL,
  "migration": $MIGRATION,
  "ncb": $NCB,
  "csl": $CSL,
  "gain_mode": "$GAIN_MODE",
  "rx_gain": $RX_GAIN_DB,
  "rx_cic_gain_shf": $RX_CIC_GAIN_SHF,
  "ul_ra_sync_thresh": $UL_RA_SYNC_THRESH,
  "duplex_offsets": [
    $DUPLEX_OFFSET_HZ_0,
    $DUPLEX_OFFSET_HZ_1,
    $DUPLEX_OFFSET_HZ_2,
    $DUPLEX_OFFSET_HZ_3,
    $DUPLEX_OFFSET_HZ_4,
    $DUPLEX_OFFSET_HZ_5,
    $DUPLEX_OFFSET_HZ_6,
    $DUPLEX_OFFSET_HZ_7
  ]
}
EOF
