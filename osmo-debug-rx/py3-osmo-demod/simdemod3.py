#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# SPDX-License-Identifier: GPL-3.0
#
# GNU Radio Python Flow Graph
# Title: DQPSK demodulator for Telive, with the AFC packet sending option disabled
# Author: Jacek Lipkowski SQ5BPF
# Description: cqpsk demodulator for tetra. based on  pi4dqpsk_rx.grc (by 'Luca Bortolotti' @optiluca) from https://gitlab.com/larryth/tetra-kit/ . It is meant as a replacement for simdemod2.py, taked the data from stdin, and dumpd demodulated data to STDOUT. Also sends via UDP the information how much the signal is mistuned (this option is disabled for the version committed to osmo-tetra)
# GNU Radio version: 3.10.5.1

from gnuradio import analog
from gnuradio import blocks
from gnuradio import digital
from gnuradio import gr
from gnuradio import filter as gr_filter
from gnuradio.filter import firdes
from gnuradio.fft import window
import sys
import signal
from argparse import ArgumentParser
from gnuradio.eng_arg import eng_float, intx
from gnuradio import eng_notation
import cmath
import os




class simdemod3(gr.top_block):

    def __init__(self, input_file=None, output_file=None,
                 sample_rate=2000000, tune_offset=0):
        gr.top_block.__init__(self, "DQPSK demodulator for Telive, with the AFC packet sending option disabled", catch_exceptions=True)

        ##################################################
        # Variables
        ##################################################
        self.sps = sps = 2
        self.nfilts = nfilts = 32
        self.constel = constel = digital.constellation_dqpsk().base()
        self.constel.gen_soft_dec_lut(8)
        self.variable_adaptive_algorithm_0 = variable_adaptive_algorithm_0 = digital.adaptive_algorithm_cma( constel, 10e-3, 1).base()
        self.samp_rate = samp_rate = sample_rate
        self.rrc_taps = rrc_taps = firdes.root_raised_cosine(nfilts, nfilts, 1.0/float(sps), 0.35, 11*sps*nfilts)
        self.decim = decim = 32
        self.channel_rate = channel_rate = 36000
        self.arity = arity = 4

        ##################################################
        # Blocks
        ##################################################

        if output_file is None or output_file in ('-', '/dev/stdout'):
            self.stdout_sink = blocks.file_descriptor_sink(gr.sizeof_char*1, 1)
        else:
            self.stdout_sink = blocks.file_sink(gr.sizeof_char*1, output_file, False)
            self.stdout_sink.set_unbuffered(False)
        self.digital_pfb_clock_sync_xxx_0 = digital.pfb_clock_sync_ccf(sps, (2*cmath.pi/100.0), rrc_taps, nfilts, (nfilts/2), 1.5, sps)
        self.digital_map_bb_0 = digital.map_bb(constel.pre_diff_code())
        self.digital_linear_equalizer_0 = digital.linear_equalizer(15, sps, variable_adaptive_algorithm_0, True, [ ], 'corr_est')
        self.digital_fll_band_edge_cc_0 = digital.fll_band_edge_cc(sps, 0.35, 45, (cmath.pi/100.0))
        self.digital_diff_phasor_cc_0 = digital.diff_phasor_cc()
        self.digital_constellation_decoder_cb_0 = digital.constellation_decoder_cb(constel)
        self.blocks_unpack_k_bits_bb_0 = blocks.unpack_k_bits_bb(constel.bits_per_symbol())
        self.blocks_null_sink_0 = blocks.null_sink(gr.sizeof_float*1)

        if input_file is None or input_file in ('-', '/dev/stdin'):
            # legacy: read gr_complex from stdin, no resampling/tuning
            self.input_chain = [
                blocks.file_descriptor_source(gr.sizeof_gr_complex*1, 0, False),
            ]
        else:
            channel_bw = 25e3
            chan_taps = firdes.low_pass(1.0, sample_rate, channel_bw,
                                        channel_bw * 0.2, window.WIN_HANN)
            new_rate = 2 * channel_rate
            resample_ratio = float(sample_rate) / float(new_rate)
            src = blocks.file_source(gr.sizeof_char*1, input_file, False)
            u2f = blocks.uchar_to_float()
            offset = blocks.add_const_ff(-127.5)
            scale = blocks.multiply_const_ff(1.0/128.0)
            f2c = blocks.float_to_complex(1)
            f2c.set_block_alias('iq_pair_to_complex')
            deinterleave = blocks.deinterleave(gr.sizeof_float, 1)
            tuner = gr_filter.freq_xlating_fir_filter_ccf(
                1, chan_taps, float(tune_offset), float(sample_rate))
            interp = gr_filter.mmse_resampler_cc(0.0, resample_ratio)
            self.input_chain = [src, u2f, offset, scale, deinterleave,
                                f2c, tuner, interp]
            self.connect(src, u2f, offset, scale, deinterleave)
            self.connect((deinterleave, 0), (f2c, 0))
            self.connect((deinterleave, 1), (f2c, 1))
            self.connect(f2c, tuner, interp)

        self.analog_feedforward_agc_cc_0 = analog.feedforward_agc_cc(8, 1)


        ##################################################
        # Connections
        ##################################################
        self.connect((self.analog_feedforward_agc_cc_0, 0), (self.digital_fll_band_edge_cc_0, 0))
        self.connect((self.input_chain[-1], 0), (self.analog_feedforward_agc_cc_0, 0))
        self.connect((self.blocks_unpack_k_bits_bb_0, 0), (self.stdout_sink, 0))
        self.connect((self.digital_constellation_decoder_cb_0, 0), (self.digital_map_bb_0, 0))
        self.connect((self.digital_diff_phasor_cc_0, 0), (self.digital_constellation_decoder_cb_0, 0))
        self.connect((self.digital_fll_band_edge_cc_0, 2), (self.blocks_null_sink_0, 1))
        self.connect((self.digital_fll_band_edge_cc_0, 3), (self.blocks_null_sink_0, 2))
        self.connect((self.digital_fll_band_edge_cc_0, 1), (self.blocks_null_sink_0, 0))
        self.connect((self.digital_fll_band_edge_cc_0, 0), (self.digital_pfb_clock_sync_xxx_0, 0))
        self.connect((self.digital_linear_equalizer_0, 0), (self.digital_diff_phasor_cc_0, 0))
        self.connect((self.digital_map_bb_0, 0), (self.blocks_unpack_k_bits_bb_0, 0))
        self.connect((self.digital_pfb_clock_sync_xxx_0, 0), (self.digital_linear_equalizer_0, 0))


    def get_sps(self):
        return self.sps

    def set_sps(self, sps):
        self.sps = sps
        self.set_rrc_taps(firdes.root_raised_cosine(self.nfilts, self.nfilts, 1.0/float(self.sps), 0.35, 11*self.sps*self.nfilts))

    def get_nfilts(self):
        return self.nfilts

    def set_nfilts(self, nfilts):
        self.nfilts = nfilts
        self.set_rrc_taps(firdes.root_raised_cosine(self.nfilts, self.nfilts, 1.0/float(self.sps), 0.35, 11*self.sps*self.nfilts))

    def get_constel(self):
        return self.constel

    def set_constel(self, constel):
        self.constel = constel

    def get_variable_adaptive_algorithm_0(self):
        return self.variable_adaptive_algorithm_0

    def set_variable_adaptive_algorithm_0(self, variable_adaptive_algorithm_0):
        self.variable_adaptive_algorithm_0 = variable_adaptive_algorithm_0

    def get_samp_rate(self):
        return self.samp_rate

    def set_samp_rate(self, samp_rate):
        self.samp_rate = samp_rate

    def get_rrc_taps(self):
        return self.rrc_taps

    def set_rrc_taps(self, rrc_taps):
        self.rrc_taps = rrc_taps
        self.digital_pfb_clock_sync_xxx_0.update_taps(self.rrc_taps)

    def get_decim(self):
        return self.decim

    def set_decim(self, decim):
        self.decim = decim

    def get_channel_rate(self):
        return self.channel_rate

    def set_channel_rate(self, channel_rate):
        self.channel_rate = channel_rate

    def get_arity(self):
        return self.arity

    def set_arity(self, arity):
        self.arity = arity




def main(top_block_cls=simdemod3, options=None):
    parser = ArgumentParser()
    parser.add_argument("-i", "--input-file", default=None,
                        help="rtl_sdr u8 IQ capture file (default: stdin gr_complex)")
    parser.add_argument("-o", "--output-file", default=None,
                        help="output bit file, 1 bit/byte (default: stdout)")
    parser.add_argument("-s", "--sample-rate", type=eng_float, default=eng_notation.num_to_str(1e6),
                        help="input sample rate (Hz, default 1e6)")
    parser.add_argument("-t", "--tune-offset", type=eng_float, default=eng_notation.num_to_str(0),
                        help="freq offset of TETRA channel inside capture (Hz, default 0)")
    args = parser.parse_args()

    tb = top_block_cls(input_file=args.input_file,
                       output_file=args.output_file,
                       sample_rate=int(args.sample_rate),
                       tune_offset=int(args.tune_offset))

    def sig_handler(sig=None, frame=None):
        tb.stop()
        tb.wait()

        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    tb.start()

    tb.wait()


if __name__ == '__main__':
    main()
